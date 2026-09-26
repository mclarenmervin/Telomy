def save_prediction(supabase, prediction: dict) -> None:
    """Idempotent: a webhook retry for the same event and kind updates, never duplicates."""
    supabase.table("predictions").upsert(prediction, on_conflict="event_id,kind").execute()
