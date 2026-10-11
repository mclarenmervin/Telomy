-- What 017_genetic_risk_route.sql has to guarantee.
--
-- One property, and it is here rather than in Python because Python could not
-- have caught it: the fakes have no check constraints, so every test on both
-- sides passed while the database was rejecting the row.
--
-- The defect: `genetic_risk` was added to `turn.py` and not to the constraint.
-- The insert failed with 23514, `save_turn` logged and swallowed it, and the
-- endpoint returned 200 with a perfectly good answer the person read and
-- nothing recorded. `turns_since` counts rows in this table, so the turn also
-- did not count towards the daily cap -- a route missing from this constraint
-- is an uncapped turn, silently.
--
-- Runs inside a transaction that always rolls back.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/genetic_risk_route_test.sql

\set alice '\'c8c8c8c8-0000-4000-8000-000000000001\''

begin;

create or replace function pg_temp.asserts(ok boolean, label text)
returns void language plpgsql as $$
begin
  if ok then
    raise notice 'PASS: %', label;
  else
    raise exception 'FAIL: %', label;
  end if;
end $$;

create or replace function pg_temp.refuses(statement text, label text)
returns void language plpgsql as $$
begin
  begin
    execute statement;
  exception when others then
    raise notice 'PASS: %', label;
    return;
  end;
  raise exception 'FAIL: % (the statement was accepted)', label;
end $$;

insert into auth.users (id, instance_id, aud, role, email,
                        encrypted_password, created_at, updated_at)
values (:alice, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'genetic-route-alice@example.com', '', now(), now());


-- ── The route the code produces is one the table accepts ─────────────────────

insert into chat_turns (user_id, asked, answered, route, guardrail_flags)
values (:alice, 'do I have the Alzheimer gene?',
        'I have no way to answer that, and that is deliberate.',
        'genetic_risk', array['genetic_risk', 'alzheimers']);

select pg_temp.asserts(
  (select count(*) from chat_turns
   where user_id = :alice and route = 'genetic_risk') = 1,
  'a deterministic genetic-risk answer is recorded'
);


-- ── And the four that came before it still are ───────────────────────────────
--
-- 017 drops and recreates the constraint rather than extending it, which is
-- the operation most likely to lose one of the existing values in a typo.

insert into chat_turns (user_id, asked, answered, route)
values (:alice, 'a', 'b', 'answered'),
       (:alice, 'a', 'b', 'guardrail_replaced'),
       (:alice, 'a', 'b', 'emergency'),
       (:alice, 'a', 'b', 'unavailable');

select pg_temp.asserts(
  (select count(distinct route) from chat_turns where user_id = :alice) = 5,
  'every route the concierge can produce is still accepted'
);


-- ── And nothing else is ──────────────────────────────────────────────────────

select pg_temp.refuses(
  format(
    'insert into chat_turns (user_id, asked, answered, route) values (%L, %L, %L, %L)',
    'c8c8c8c8-0000-4000-8000-000000000001', 'hello', 'hi', 'genetic'
  ),
  'a near-miss spelling of the new route is still refused'
);

rollback;
