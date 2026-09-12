import hmac


def verify_webhook_signature(received: str | None, expected: str) -> bool:
    if not received:
        return False
    return hmac.compare_digest(received, expected)
