-- predictions.kind gains 'activity_summary' (design §D3). No new table or column:
-- event_id holds the id of whichever row triggered the prediction.
alter table predictions drop constraint if exists predictions_kind_check;
alter table predictions add constraint predictions_kind_check
  check (kind in ('ack', 'analysis', 'activity_summary'));
