import os
from unittest.mock import patch
from app.common import supabase_client

os.environ.setdefault("SUPABASE_URL", "https://x.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_KEY", "service-key")
os.environ.setdefault("WEBHOOK_SECRET", "shh")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379/0")
os.environ.setdefault("QUEUE_NAME", "events:realtime")


def test_get_supabase_client_uses_settings():
    supabase_client.get_supabase_client.cache_clear()
    with patch.object(supabase_client, "create_client") as mock_create:
        supabase_client.get_supabase_client()
        mock_create.assert_called_once_with("https://x.supabase.co", "service-key")
    supabase_client.get_supabase_client.cache_clear()
