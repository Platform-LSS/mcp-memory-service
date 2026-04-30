"""Tests for MemoryService.store_memory() — Task 2: conversation_id threading."""
import os
import tempfile
import pytest

# Ensure sqlite_vec backend and a fresh test DB for this module
os.environ['MCP_MEMORY_STORAGE_BACKEND'] = 'sqlite_vec'
_test_db_dir = tempfile.mkdtemp(prefix='mcp-service-test-')
os.environ['MCP_MEMORY_SQLITE_PATH'] = os.path.join(_test_db_dir, 'test.db')
os.environ['MCP_SEMANTIC_DEDUP_ENABLED'] = 'false'  # off by default; tests override

from mcp_memory_service.services.memory_service import MemoryService
from mcp_memory_service.storage.sqlite_vec import SqliteVecMemoryStorage


@pytest.fixture
async def memory_service(tmp_path):
    """Create a fresh MemoryService backed by a temp SQLite-Vec database."""
    db_path = str(tmp_path / "test_service.db")
    storage = SqliteVecMemoryStorage(db_path)
    await storage.initialize()
    service = MemoryService(storage=storage)
    yield service
    await storage.close()


class TestStoreMemory:
    """Tests for MemoryService.store_memory()."""

    @pytest.mark.asyncio
    async def test_conversation_id_bypasses_semantic_dedup(self, memory_service):
        """Storing with conversation_id skips semantic dedup."""
        # Enable semantic dedup on the storage backend
        memory_service.storage.semantic_dedup_enabled = True

        result1 = await memory_service.store_memory(
            content="Claude Code is a powerful CLI tool for software engineering.",
            tags=["test"],
            conversation_id="conv-abc"
        )
        assert result1["success"]

        # Similar content, same conversation — should succeed (dedup skipped)
        result2 = await memory_service.store_memory(
            content="The Claude Code CLI is an excellent software development tool.",
            tags=["test"],
            conversation_id="conv-abc"
        )
        assert result2["success"], f"Expected success with conversation_id, got: {result2.get('error')}"

        # Similar content, NO conversation_id — should be rejected by semantic dedup
        result3 = await memory_service.store_memory(
            content="Claude Code CLI is a top-tier software engineering tool.",
            tags=["test"]
        )
        assert not result3["success"]
        assert "semantically similar" in result3.get("error", "").lower()

    @pytest.mark.asyncio
    async def test_conversation_id_persisted_in_metadata(self, memory_service):
        """conversation_id is stored in memory metadata for future grouping/retrieval."""
        result = await memory_service.store_memory(
            content="A memory tagged with a conversation ID for retrieval.",
            tags=["test"],
            conversation_id="conv-persist-check"
        )
        assert result["success"]
        content_hash = result["memory"]["content_hash"]

        # Retrieve the stored memory and verify conversation_id is in metadata
        memory = await memory_service.storage.get_by_hash(content_hash)
        assert memory is not None
        assert memory.metadata.get("conversation_id") == "conv-persist-check"


class TestSearchByTagPagination:
    """Tests for MemoryService.search_by_tag() pagination — issue: unbounded result set."""

    async def _seed(self, service, n: int, tag: str = "page-test"):
        for i in range(n):
            r = await service.store_memory(
                content=f"page-test memory {i:04d}",
                tags=[tag],
            )
            assert r["success"]

    @pytest.mark.asyncio
    async def test_default_page_size_caps_results(self, memory_service):
        """Without explicit pagination, default page_size=50 caps the response."""
        await self._seed(memory_service, 75)

        result = await memory_service.search_by_tag(tags=["page-test"])

        assert "error" not in result
        assert result["total_found"] == 75
        assert result["count"] == 50           # default page_size
        assert len(result["memories"]) == 50
        assert result["page"] == 1
        assert result["page_size"] == 50
        assert result["has_more"] is True

    @pytest.mark.asyncio
    async def test_explicit_page_size_and_paging(self, memory_service):
        """Explicit page/page_size walks through the full set deterministically."""
        await self._seed(memory_service, 25)

        page1 = await memory_service.search_by_tag(tags=["page-test"], page=1, page_size=10)
        page2 = await memory_service.search_by_tag(tags=["page-test"], page=2, page_size=10)
        page3 = await memory_service.search_by_tag(tags=["page-test"], page=3, page_size=10)

        for p in (page1, page2, page3):
            assert p["total_found"] == 25
            assert p["page_size"] == 10

        assert page1["count"] == 10 and page1["has_more"]
        assert page2["count"] == 10 and page2["has_more"]
        assert page3["count"] == 5 and not page3["has_more"]

        # Pages must not overlap
        hashes = lambda r: {m["content_hash"] for m in r["memories"]}
        assert hashes(page1).isdisjoint(hashes(page2))
        assert hashes(page2).isdisjoint(hashes(page3))
        # Union covers everything
        assert len(hashes(page1) | hashes(page2) | hashes(page3)) == 25

    @pytest.mark.asyncio
    async def test_page_size_clamped_to_500(self, memory_service):
        """Caller cannot bypass the hard cap by passing page_size=10000."""
        await self._seed(memory_service, 5)

        result = await memory_service.search_by_tag(tags=["page-test"], page_size=10_000)

        assert result["page_size"] == 500
        assert result["total_found"] == 5
        assert result["count"] == 5  # only 5 exist; cap doesn't manufacture rows

    @pytest.mark.asyncio
    async def test_page_beyond_end_returns_empty(self, memory_service):
        """Asking for a page past the end returns empty memories with correct totals."""
        await self._seed(memory_service, 5)

        result = await memory_service.search_by_tag(tags=["page-test"], page=99, page_size=10)

        assert result["total_found"] == 5
        assert result["count"] == 0
        assert result["memories"] == []
        assert result["has_more"] is False

    @pytest.mark.asyncio
    async def test_match_all_filters_before_pagination(self, memory_service):
        """match_all narrows the set, then pagination is applied to the narrowed set."""
        # 3 memories tagged a+b, 5 tagged a only
        for i in range(3):
            await memory_service.store_memory(content=f"both {i}", tags=["a", "b"])
        for i in range(5):
            await memory_service.store_memory(content=f"only-a {i}", tags=["a"])

        # OR (default): all 8 match
        any_match = await memory_service.search_by_tag(tags=["a", "b"])
        assert any_match["total_found"] == 8

        # AND: only the 3 with both tags
        all_match = await memory_service.search_by_tag(
            tags=["a", "b"], match_all=True, page_size=2
        )
        assert all_match["total_found"] == 3
        assert all_match["count"] == 2
        assert all_match["has_more"] is True
