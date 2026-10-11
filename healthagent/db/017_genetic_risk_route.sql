-- A fifth route for a chat turn: a question about inherited disease risk,
-- answered deterministically before any model ran.
--
-- WHY THIS IS A MIGRATION AND NOT A ONE-LINE EDIT TO 016
--
-- The runner refuses an edit to an applied file, which is the point. But the
-- reason this file exists at all is worth recording, because the defect it
-- fixes was invisible to every test on both sides of the boundary and was
-- found by typing a question into the app.
--
-- `genetic_risk` was added to `app/concierge/turn.py` and not here. The insert
-- failed with 23514. `save_turn` logged it and carried on -- deliberately, and
-- correctly: the reply was already guarded, somebody was holding a phone
-- waiting for it, and losing an audit row must not swallow an answer. The
-- endpoint returned 200 and the person read a perfectly good reply that was
-- never recorded.
--
-- The quiet half is the worse half. `turns_since` counts rows in this table,
-- so a route this constraint rejects does not count towards the daily cap:
-- add a route, forget the migration, and the budget silently stops applying
-- to it. `test_every_route_the_turn_can_produce_is_one_the_database_accepts`
-- now parses this constraint and compares it with the route constants, so the
-- next one fails a test instead of a person.
--
-- WHY THE ROUTE EXISTS
--
-- "Do I have the Alzheimer's gene" is answered by fixed text that no model
-- produced. The plan names APOE as the live hazard, and a model's behaviour
-- varies between two identical runs, so the one sentence about inherited risk
-- in this product is a deterministic one. The route is recorded separately
-- from `answered` because it is not the model answering, and separately from
-- `guardrail_replaced` because nothing was replaced -- there was never a
-- generated reply to replace.

alter table public.chat_turns
  drop constraint if exists chat_turns_route_check;

alter table public.chat_turns
  add constraint chat_turns_route_check check (route in
    ('answered', 'guardrail_replaced', 'emergency', 'unavailable',
     'genetic_risk'));
