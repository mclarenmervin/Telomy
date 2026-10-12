-- What 023_catalog_signoffs.sql has to guarantee.
--
-- Five reviewed-content files carry zero signatures between them, and the
-- reason is not that nobody has read them: it is that there has never been
-- anywhere for a signature to be made. F6 built the mechanism and left it
-- unused because a signature needs a real name, a registration and a date,
-- and a hand-edit to a YAML file is none of those things.
--
-- This table is the act of signing. git stays the source of truth for the
-- content that was signed, so the loaders keep reading YAML and no catalog
-- load becomes a database call. What the table adds is the half a file cannot
-- hold: a verified identity, a licence that was unexpired at the time, and a
-- trail that cannot be rewritten afterwards.
--
-- The properties, in the order they would be a problem:
--
--   * a signature is over a CONTENT HASH, so signing text somebody has not
--     seen is refused rather than discouraged;
--   * `clinician_may_sign()` is checked in a trigger, at signing time, so the
--     service role is bound by the licence too -- 013's lesson, and the whole
--     reason that function exists;
--   * the reviewer's name and registration are stamped from `clinicians` and
--     never accepted from the caller;
--   * append-only. A withdrawal is a new row.
--
-- Runs inside a transaction that always rolls back.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/catalog_signoffs_test.sql

\set clinician '\'b0b0b0b0-0000-4000-8000-000000000001\''
\set lapsed    '\'b0b0b0b0-0000-4000-8000-000000000002\''
\set member    '\'b0b0b0b0-0000-4000-8000-000000000003\''
\set admin     '\'b0b0b0b0-0000-4000-8000-000000000004\''
\set clinic    '\'b0b0b0b0-0000-4000-8000-0000000000c1\''

\set clinician_jwt '{"sub":"b0b0b0b0-0000-4000-8000-000000000001","role":"authenticated"}'
\set lapsed_jwt    '{"sub":"b0b0b0b0-0000-4000-8000-000000000002","role":"authenticated"}'
\set member_jwt    '{"sub":"b0b0b0b0-0000-4000-8000-000000000003","role":"authenticated"}'
\set admin_jwt     '{"sub":"b0b0b0b0-0000-4000-8000-000000000004","role":"authenticated"}'

-- Stand-ins for what `content_fingerprint` computes over a YAML entry.
\set hash_a '\'1111111111111111111111111111111111111111111111111111111111111111\''
\set hash_b '\'2222222222222222222222222222222222222222222222222222222222222222\''

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
values (:clinician, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'signoff-clinician@example.com', '', now(), now()),
       (:lapsed, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'signoff-lapsed@example.com', '', now(), now()),
       (:member, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'signoff-member@example.com', '', now(), now()),
       (:admin, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'signoff-admin@example.com', '', now(), now());

select set_config('telomy.granting_role', 'yes', true);
update profiles set app_role = 'doctor' where id in (:clinician, :lapsed);
update profiles set app_role = 'admin'  where id = :admin;
select set_config('telomy.granting_role', '', true);

insert into clinics (id, name) values (:clinic, 'Signoff Test Clinic');
insert into clinic_members (clinic_id, user_id, role)
values (:clinic, :clinician, 'clinician'),
       (:clinic, :lapsed, 'clinician');

insert into clinicians (user_id, full_name, registration_number,
                        registration_body, licence_expires_at)
values (:clinician, 'Dr A. Rao', 'KMC/12345', 'Karnataka Medical Council',
        now() + interval '1 year'),
       (:lapsed, 'Dr B. Who', 'KMC/99999', 'Karnataka Medical Council',
        now() - interval '1 day');


-- ── A signature is over what was read ───────────────────────────────────────

set local role authenticated;
set local request.jwt.claims = :'clinician_jwt';

insert into catalog_signoffs
  (catalog, catalog_version, entry_id, content_sha256, clinician_id)
values ('biomarkers', 'global.v1', 'albumin', :hash_a, :clinician);

select pg_temp.asserts(
  (select count(*) from catalog_signoffs
    where entry_id = 'albumin' and action = 'signed') = 1,
  'a clinician in good standing signs a catalog entry'
);

-- Stamped from `clinicians`, not accepted from the caller. 013's discipline:
-- the trail has to say what was true when it was signed, and a clinician who
-- later changes their name must not silently rewrite the record.
select pg_temp.asserts(
  (select reviewer_name || ' / ' || reviewer_registration
     from catalog_signoffs where entry_id = 'albumin')
    = 'Dr A. Rao / KMC/12345',
  'the name and registration are stamped from the registration, not supplied'
);

select pg_temp.refuses(
  format(
    'insert into catalog_signoffs (catalog, catalog_version, entry_id, '
    'content_sha256, clinician_id, reviewer_name) values (%L, %L, %L, %L, %L, %L)',
    'biomarkers', 'global.v1', 'creatinine', :hash_a,
    'b0b0b0b0-0000-4000-8000-000000000001', 'Professor Somebody Else'),
  'a caller cannot put a name of their choosing against a signature'
);

select pg_temp.refuses(
  format(
    'insert into catalog_signoffs (catalog, catalog_version, entry_id, '
    'content_sha256, clinician_id) values (%L, %L, %L, %L, %L)',
    'biomarkers', 'global.v1', 'creatinine', 'not-a-hash',
    'b0b0b0b0-0000-4000-8000-000000000001'),
  'a signature that is not over a sha256 is refused'
);

select pg_temp.refuses(
  format(
    'insert into catalog_signoffs (catalog, catalog_version, entry_id, '
    'content_sha256, clinician_id) values (%L, %L, %L, %L, %L)',
    'horoscopes', 'global.v1', 'creatinine', :hash_a,
    'b0b0b0b0-0000-4000-8000-000000000001'),
  'a file nobody reviews is not a catalog that can be signed'
);

-- Identity: a clinician signs as themselves. A signature somebody else can
-- file in your name is not a signature.
select pg_temp.refuses(
  format(
    'insert into catalog_signoffs (catalog, catalog_version, entry_id, '
    'content_sha256, clinician_id) values (%L, %L, %L, %L, %L)',
    'biomarkers', 'global.v1', 'creatinine', :hash_a,
    'b0b0b0b0-0000-4000-8000-000000000002'),
  'a clinician cannot sign in a colleague''s name'
);

reset role;


-- ── The licence is checked at signing time ──────────────────────────────────
--
-- The reason `clinician_may_sign` exists, and the reason this is a trigger
-- and not only a policy: the agent and the scheduler hold the service role,
-- and a licence check that only binds the console has a service-role-shaped
-- hole in it.

set local role authenticated;
set local request.jwt.claims = :'lapsed_jwt';

select pg_temp.refuses(
  format(
    'insert into catalog_signoffs (catalog, catalog_version, entry_id, '
    'content_sha256, clinician_id) values (%L, %L, %L, %L, %L)',
    'supplements', 'supplements.v1', 'vitamin_d_repletion', :hash_a,
    'b0b0b0b0-0000-4000-8000-000000000002'),
  'a clinician whose licence has expired cannot sign reviewed content'
);

reset role;

-- And the same statement as the service role, which RLS does not bind at all.
select pg_temp.refuses(
  format(
    'insert into catalog_signoffs (catalog, catalog_version, entry_id, '
    'content_sha256, clinician_id) values (%L, %L, %L, %L, %L)',
    'supplements', 'supplements.v1', 'vitamin_d_repletion', :hash_a,
    'b0b0b0b0-0000-4000-8000-000000000002'),
  'nor can we sign on their behalf, because the trigger binds us too'
);

-- A person with no registration at all, which is the state every account in
-- this database is in today.
select pg_temp.refuses(
  format(
    'insert into catalog_signoffs (catalog, catalog_version, entry_id, '
    'content_sha256, clinician_id) values (%L, %L, %L, %L, %L)',
    'variants', 'variants.v1', 'rs1801133', :hash_a,
    'b0b0b0b0-0000-4000-8000-000000000003'),
  'somebody with no registration cannot sign, whatever their app_role says'
);


-- ── Append-only ─────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims = :'clinician_jwt';

select pg_temp.refuses(
  'update catalog_signoffs set content_sha256 = ' || :'hash_b',
  'a signature cannot be moved onto content it was not over'
);

select pg_temp.refuses(
  'delete from catalog_signoffs',
  'and cannot be deleted by the person who made it'
);

reset role;

-- The same two statements as the owner, which is what the revoke above does
-- NOT bind. Found by mutation: dropping the append-only trigger left the two
-- assertions above green, because the column grant was refusing them before
-- the trigger ever ran. The trigger is the half that binds the service role,
-- and our own code holds it.
select pg_temp.refuses(
  'update catalog_signoffs set content_sha256 = ' || :'hash_b',
  'nor can we move a signature, holding every privilege there is'
);

select pg_temp.refuses(
  'delete from catalog_signoffs',
  'nor delete one'
);

set local role authenticated;
set local request.jwt.claims = :'clinician_jwt';

-- A withdrawal is a new row, so "this was signed in October and withdrawn in
-- November" survives as a fact rather than becoming an absence.
insert into catalog_signoffs
  (catalog, catalog_version, entry_id, content_sha256, clinician_id, action,
   notes)
values ('biomarkers', 'global.v1', 'albumin', :hash_a, :clinician, 'withdrawn',
        'the lower bound is wrong for South Asian cohorts');

select pg_temp.asserts(
  (select count(*) from catalog_signoffs where entry_id = 'albumin') = 2,
  'a withdrawal is a second row and the signature it withdraws is still there'
);

select pg_temp.asserts(
  (select action from catalog_signoff_state('biomarkers')
    where entry_id = 'albumin') = 'withdrawn',
  'and the current state of that entry is withdrawn'
);

reset role;

-- A withdrawal has to say why. A signature being removed with no reason is
-- the one event here that most needs an explanation.
select pg_temp.refuses(
  format(
    'insert into catalog_signoffs (catalog, catalog_version, entry_id, '
    'content_sha256, clinician_id, action) values (%L, %L, %L, %L, %L, %L)',
    'biomarkers', 'global.v1', 'creatinine', :hash_a,
    'b0b0b0b0-0000-4000-8000-000000000001', 'withdrawn'),
  'a withdrawal with no reason is refused'
);


-- ── Who can see it ──────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims = :'member_jwt';

select pg_temp.asserts(
  (select count(*) from catalog_signoffs) = 0,
  'a member reads no signatures -- this is operational, not their record'
);

reset role;

set local role authenticated;
set local request.jwt.claims = :'clinician_jwt';

select pg_temp.asserts(
  (select count(*) from catalog_signoffs) = 2,
  'a clinician reads their own signatures, which is how they see what they '
  'have already taken a view on'
);

reset role;

set local role authenticated;
set local request.jwt.claims = :'admin_jwt';

select pg_temp.asserts(
  (select count(*) from catalog_signoffs) = 2,
  'an admin reads every signature, because collecting them is the job'
);

select pg_temp.refuses(
  format(
    'insert into catalog_signoffs (catalog, catalog_version, entry_id, '
    'content_sha256, clinician_id) values (%L, %L, %L, %L, %L)',
    'therapies', 'therapies.v1', 'sauna__hrv', :hash_a,
    'b0b0b0b0-0000-4000-8000-000000000001'),
  'an admin cannot sign clinical content on a clinician''s behalf, which is '
  'the entire reason the signature is worth collecting'
);

reset role;


-- ── The state function ──────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims = :'clinician_jwt';

insert into catalog_signoffs
  (catalog, catalog_version, entry_id, content_sha256, clinician_id)
values ('variants', 'variants.v1', 'rs1801133', :hash_a, :clinician);

select pg_temp.asserts(
  (select count(*) from catalog_signoff_state('variants')) = 1,
  'the state function answers per catalog'
);

-- Editing the entry moves the hash, and a signature over the old hash is not
-- a signature over the new content. The loader already refuses to honour it;
-- this is the same fact from the database side.
select pg_temp.asserts(
  (select content_sha256 from catalog_signoff_state('variants')
    where entry_id = 'rs1801133') = :hash_a,
  'the state carries the hash that was signed, so a reader can tell whether '
  'it still matches the file'
);

insert into catalog_signoffs
  (catalog, catalog_version, entry_id, content_sha256, clinician_id)
values ('variants', 'variants.v1', 'rs1801133', :hash_b, :clinician);

select pg_temp.asserts(
  (select count(*) from catalog_signoff_state('variants')
    where entry_id = 'rs1801133') = 2,
  'and re-signing after an edit is a separate state, not a replacement -- '
  'two hashes signed is two facts'
);

reset role;

rollback;
