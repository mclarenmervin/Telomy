-- What 021_environment_snapshots.sql has to guarantee.
--
-- The coarse-location rule is the one that matters, and it is a CHECK rather
-- than a convention because a convention is a thing our own code can forget.
-- A row at six decimal places is a person's street, and no caller -- not the
-- phone, not the scheduler, not a future one -- may write one.
--
-- Runs inside a transaction that always rolls back.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/environment_snapshots_test.sql

\set alice '\'cacacaca-0000-4000-8000-000000000001\''
\set bob   '\'cacacaca-0000-4000-8000-000000000002\''

\set alice_jwt '{"sub":"cacacaca-0000-4000-8000-000000000001","role":"authenticated"}'

begin;

create or replace function pg_temp.asserts(ok boolean, label text)
returns void language plpgsql as $$
begin
  if ok then raise notice 'PASS: %', label;
  else raise exception 'FAIL: %', label; end if;
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
        'authenticated', 'env-alice@example.com', '', now(), now()),
       (:bob, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'env-bob@example.com', '', now(), now());

insert into environment_snapshots
  (user_id, observed_on, latitude, longitude, us_aqi_max, uv_index_max,
   hours_observed, provider)
values (:alice, current_date - 1, 13.0, 77.6, 181, 9.40, 24, 'open-meteo'),
       (:bob,   current_date - 1, 13.0, 77.6, 181, 9.40, 24, 'open-meteo');


-- ── A street is not storable ────────────────────────────────────────────────

insert into environment_snapshots
  (user_id, observed_on, latitude, longitude, hours_observed, provider)
values (:alice, current_date - 2, 12.971599, 77.594566, 24, 'open-meteo');

select pg_temp.asserts(
  (select latitude from environment_snapshots
    where user_id = :alice and observed_on = current_date - 2) = 13.0,
  'a coordinate at six decimals is rounded to the cell by the column itself'
);

select pg_temp.refuses(
  format(
    'insert into environment_snapshots (user_id, observed_on, latitude, '
    'longitude, hours_observed, provider) values (%L, %L, %L, %L, %L, %L)',
    'cacacaca-0000-4000-8000-000000000001', current_date - 3, 412.0, 77.6, 24,
    'open-meteo'
  ),
  'a coordinate off the planet is refused'
);

select pg_temp.refuses(
  format(
    'insert into environment_snapshots (user_id, observed_on, latitude, '
    'longitude, hours_observed, provider) values (%L, %L, %L, %L, %L, %L)',
    'cacacaca-0000-4000-8000-000000000001', current_date - 4, 13.0, 77.6, 48,
    'open-meteo'
  ),
  'a day with more than twenty-four hours in it is refused'
);

select pg_temp.refuses(
  format(
    'insert into environment_snapshots (user_id, observed_on, latitude, '
    'longitude, hours_observed, provider) values (%L, %L, %L, %L, %L, %L)',
    'cacacaca-0000-4000-8000-000000000001', current_date - 1, 13.0, 77.6, 24,
    'open-meteo'
  ),
  'a second opinion about the same day is refused'
);


-- ── As the user ─────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims = :'alice_jwt';

select pg_temp.asserts(
  (select count(*) from environment_snapshots) = 2,
  'a user sees their own days and nobody else''s'
);

select pg_temp.refuses(
  format(
    'insert into environment_snapshots (user_id, observed_on, latitude, '
    'longitude, hours_observed, provider) values (%L, %L, %L, %L, %L, %L)',
    'cacacaca-0000-4000-8000-000000000001', current_date - 9, 51.5, -0.1, 24,
    'claimed'
  ),
  'a user cannot put themselves somewhere they were not'
);

-- No update policy, so RLS shows an UPDATE no rows and it reports success
-- having changed nothing. Asserted on the row, not with `refuses`.
update environment_snapshots set us_aqi_max = 10;

select pg_temp.asserts(
  (select us_aqi_max from environment_snapshots
    where observed_on = current_date - 1) = 181,
  'a user cannot rewrite what the air was doing'
);

delete from environment_snapshots;

select pg_temp.asserts(
  (select count(*) from environment_snapshots) = 0,
  'withdrawing consent can take the history and not only the next fetch'
);

reset role;

select pg_temp.asserts(
  (select count(*) from environment_snapshots where user_id = :bob) = 1,
  'and that left everybody else''s alone'
);

delete from auth.users where id = :bob;

select pg_temp.asserts(
  (select count(*) from environment_snapshots where user_id = :bob) = 0,
  'deleting the account takes the days with it'
);

rollback;
