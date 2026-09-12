import logging
from app.common.logging_config import get_logger, log_context


def test_get_logger_returns_named_logger():
    logger = get_logger("app.test")
    assert isinstance(logger, logging.Logger)
    assert logger.name == "app.test"


def test_log_context_formats_fields():
    result = log_context(user_id="u1", event_id="e1")
    assert result == "user_id=u1 event_id=e1"


def test_log_context_skips_none_values():
    result = log_context(user_id="u1", event_id=None)
    assert result == "user_id=u1"
