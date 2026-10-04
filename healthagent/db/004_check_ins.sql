-- Mid-event check-ins are predictions with kind 'check_in:<reason>'. The reason
-- is part of the kind so the existing unique (event_id, kind) constraint makes a
-- duplicate alert for the same reason structurally impossible, while a different
-- reason can still fire later in the same event.
alter table predictions drop constraint if exists predictions_kind_check;

alter table predictions add constraint predictions_kind_check check (
  kind in ('ack', 'analysis')
  or kind ~ '^check_in:[a-z0-9_]+$'
);
