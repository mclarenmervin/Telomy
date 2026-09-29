from contextlib import ExitStack

from langgraph.checkpoint.memory import InMemorySaver

from app.common.logging_config import get_logger

logger = get_logger(__name__)

# Held open for the process lifetime: the saver's connection must outlive this call.
_stack = ExitStack()


def build_checkpointer(settings):
    """Postgres-backed when a DB url is configured, else in-memory.

    Checkpoints are retained after a job finishes so a later chat turn can resume the
    same thread with the loaded context and computed analysis already present.
    """
    if not settings.supabase_db_url:
        logger.warning("no SUPABASE_DB_URL; using in-memory checkpointer")
        return InMemorySaver()

    from langgraph.checkpoint.postgres import PostgresSaver

    saver = _stack.enter_context(PostgresSaver.from_conn_string(settings.supabase_db_url))
    saver.setup()
    return saver
