from langgraph.checkpoint.memory import InMemorySaver
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from app.common.logging_config import get_logger

logger = get_logger(__name__)

# Keep idle connections alive, and notice a dead one quickly rather than after a stall.
KEEPALIVE_KWARGS = {
    "keepalives": 1,
    "keepalives_idle": 30,
    "keepalives_interval": 10,
    "keepalives_count": 3,
}


def connection_kwargs() -> dict:
    """What PostgresSaver.from_conn_string sets, replicated for a pooled connection.

    `autocommit` and `dict_row` are required by the saver's queries; `prepare_threshold=0`
    keeps it compatible with connection poolers that reject prepared statements.
    """
    return {
        "autocommit": True,
        "prepare_threshold": 0,
        "row_factory": dict_row,
        **KEEPALIVE_KWARGS,
    }


def _postgres_saver(pool):
    from langgraph.checkpoint.postgres import PostgresSaver

    return PostgresSaver(pool)


def build_checkpointer(settings):
    """Postgres-backed when a DB url is configured, else in-memory.

    Uses a health-checked pool rather than one long-lived connection. Supabase's pooler
    closes idle connections, and a single connection then fails every subsequent job with
    "SSL error: unexpected eof while reading" until the worker is restarted — observed in
    live testing after roughly thirty minutes of idleness. `check_connection` validates a
    connection on checkout and transparently replaces a dead one.

    Checkpoints are retained after a job so a later chat turn can resume the thread.
    """
    if not settings.supabase_db_url:
        logger.warning("no SUPABASE_DB_URL; using in-memory checkpointer")
        return InMemorySaver()

    pool = ConnectionPool(
        settings.supabase_db_url,
        min_size=1,
        max_size=4,
        kwargs=connection_kwargs(),
        check=ConnectionPool.check_connection,
        open=True,
    )
    saver = _postgres_saver(pool)
    saver.setup()
    logger.info("checkpointer ready (pooled, health-checked)")
    return saver
