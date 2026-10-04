-- Mid-event check-ins are predictions with kind 'check_in:<reason>'. The reason
-- is part of the kind so the existing unique (event_id, kind) constraint makes a
-- duplicate alert for the same reason structurally impossible, while a different
-- reason can still fire later in the same event.
--
-- The IN list must keep every kind already in use: this statement drops the
-- constraint 003 created, and ADD CONSTRAINT validates existing rows, so
-- omitting 'activity_summary' would abort the migration on a populated table
-- and break the activity agent's writes on an empty one.
begin;

alter table predictions drop constraint if exists predictions_kind_check;

alter table predictions add constraint predictions_kind_check check (
  kind in ('ack', 'analysis', 'activity_summary')
  or kind ~ '^check_in:[a-z0-9_]+$'
);

commit;
