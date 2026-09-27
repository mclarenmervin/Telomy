from app.gateway.security import verify_webhook_signature


def test_matching_secret_returns_true():
    assert verify_webhook_signature("shh", "shh") is True


def test_wrong_secret_returns_false():
    assert verify_webhook_signature("wrong", "shh") is False


def test_missing_secret_returns_false():
    assert verify_webhook_signature(None, "shh") is False


def test_empty_secret_returns_false():
    assert verify_webhook_signature("", "shh") is False
