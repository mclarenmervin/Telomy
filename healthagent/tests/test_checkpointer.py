from types import SimpleNamespace

from langgraph.checkpoint.memory import InMemorySaver

from app.common.checkpointer import build_checkpointer


def test_falls_back_to_memory_without_db_url():
    settings = SimpleNamespace(supabase_db_url=None)
    assert isinstance(build_checkpointer(settings), InMemorySaver)
