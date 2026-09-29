from types import SimpleNamespace

from langgraph.checkpoint.memory import InMemorySaver

from app.common.checkpointer import build_checkpointer


def test_falls_back_to_memory_without_db_url():
    settings = SimpleNamespace(supabase_db_url=None)
    assert isinstance(build_checkpointer(settings), InMemorySaver)


def test_connection_kwargs_match_what_postgressaver_requires():
    """A pooled saver must replicate what from_conn_string sets, or reads break."""
    from app.common.checkpointer import connection_kwargs

    kwargs = connection_kwargs()
    assert kwargs["autocommit"] is True
    assert kwargs["prepare_threshold"] == 0
    assert kwargs["row_factory"] is not None


def test_a_pool_is_used_so_a_dropped_connection_recovers(monkeypatch):
    """Live failure: Supabase's pooler closes idle connections, and a single long-lived
    connection then fails every job with 'SSL error: unexpected eof while reading'."""
    import app.common.checkpointer as mod

    captured = {}

    class FakePool:
        @staticmethod
        def check_connection(conn):  # mirrors psycopg_pool's classmethod
            return None

        def __init__(self, conninfo, **kw):
            captured["conninfo"] = conninfo
            captured.update(kw)

    class FakeSaver:
        def __init__(self, pool):
            captured["pool"] = pool

        def setup(self):
            captured["setup_called"] = True

    monkeypatch.setattr(mod, "ConnectionPool", FakePool)
    monkeypatch.setattr(mod, "_postgres_saver", lambda pool: FakeSaver(pool))

    mod.build_checkpointer(SimpleNamespace(supabase_db_url="postgresql://u:p@h:5432/db"))

    assert isinstance(captured["pool"], FakePool), "saver must be backed by a pool"
    assert captured["check"] is not None, "pool must health-check connections"
    assert captured["setup_called"] is True
    assert captured["min_size"] >= 1
