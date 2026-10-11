-- What 018_genetic_variants.sql has to guarantee.
--
-- None of this is testable from Python: every Python test path uses a fake or
-- the service role, and the service role bypasses RLS by design. F3 shipped
-- with no INSERT policy on lab_uploads, F4 found the same hole in
-- epigenetic_results, F5 found a recursive policy on clinic_members and F6
-- found that a user with a signed recommendation could not delete their
-- account -- so the behaviour is asserted here, by doing it.
--
--   * a user reads their own genotypes and nobody else's
--   * a user cannot WRITE one. A genotype the client could insert is a
--     genotype that never passed the allowlist
--   * a user CAN delete one, without closing their account. This is the one
--     table where that matters more than convenience: somebody who regrets
--     uploading their genome must be able to take it back
--   * deleting the account takes them too -- asserted by deleting an account,
--     not by reading `confdeltype`, which is the lesson of F6
--   * one genotype per locus per person
--
-- Runs inside a transaction that always rolls back.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/genetic_variants_test.sql

\set alice '\'c9c9c9c9-0000-4000-8000-000000000001\''
\set bob   '\'c9c9c9c9-0000-4000-8000-000000000002\''

\set alice_jwt '{"sub":"c9c9c9c9-0000-4000-8000-000000000001","role":"authenticated"}'

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
        'authenticated', 'variants-alice@example.com', '', now(), now()),
       (:bob, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'variants-bob@example.com', '', now(), now());

insert into genetic_variants (user_id, rsid, genotype, variants_version)
values (:alice, 'rs1801133', 'CT', 'variants.v1'),
       (:bob,   'rs1801133', 'TT', 'variants.v1');


-- ── Shape ───────────────────────────────────────────────────────────────────

select pg_temp.refuses(
  format(
    'insert into genetic_variants (user_id, rsid, genotype, variants_version) '
    'values (%L, %L, %L, %L)',
    'c9c9c9c9-0000-4000-8000-000000000001', 'rs1801133', 'AA', 'variants.v1'
  ),
  'a second genotype for the same locus is refused'
);

select pg_temp.refuses(
  format(
    'insert into genetic_variants (user_id, rsid, genotype, variants_version) '
    'values (%L, %L, %L, %L)',
    'c9c9c9c9-0000-4000-8000-000000000001', 'APOE', 'CT', 'variants.v1'
  ),
  'something that is not an rsid is refused'
);

select pg_temp.refuses(
  format(
    'insert into genetic_variants (user_id, rsid, genotype, variants_version) '
    'values (%L, %L, %L, %L)',
    'c9c9c9c9-0000-4000-8000-000000000001', 'rs2282679', 'probably GG',
    'variants.v1'
  ),
  'a genotype that is not a call is refused'
);


-- ── As the user ─────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims = :'alice_jwt';

select pg_temp.asserts(
  (select count(*) from genetic_variants) = 1,
  'a user sees their own genotypes and nobody else''s'
);

select pg_temp.refuses(
  format(
    'insert into genetic_variants (user_id, rsid, genotype, variants_version) '
    'values (%L, %L, %L, %L)',
    'c9c9c9c9-0000-4000-8000-000000000001', 'rs429358', 'CT', 'variants.v1'
  ),
  'a user cannot write a genotype that never passed the allowlist'
);

-- Asserted on the row and not with `refuses`, because an UPDATE against a
-- table with no UPDATE policy does not raise: RLS simply shows it no rows and
-- it reports success having changed nothing. A test that only watched for an
-- exception would pass just as happily against a table that HAD an update
-- policy and let this through.
update genetic_variants set genotype = 'AA';

select pg_temp.asserts(
  (select genotype from genetic_variants where rsid = 'rs1801133') = 'CT',
  'a user cannot rewrite a stored genotype'
);

delete from genetic_variants where rsid = 'rs1801133';

select pg_temp.asserts(
  (select count(*) from genetic_variants) = 0,
  'a user can take their genome back without closing their account'
);

reset role;

select pg_temp.asserts(
  (select count(*) from genetic_variants where user_id = :bob) = 1,
  'and that left everybody else''s alone'
);


-- ── Erasure of the person ───────────────────────────────────────────────────
--
-- By deleting an account, not by reading `confdeltype` off the constraint. F6
-- shipped a broken cascade that a `confdeltype = 'c'` assertion called correct
-- for its entire life.

delete from auth.users where id = :bob;

select pg_temp.asserts(
  (select count(*) from genetic_variants where user_id = :bob) = 0,
  'deleting the account takes the genotypes with it'
);


-- ── And the file in the bucket, not only the rows ───────────────────────────
--
-- Postgres cannot reach the object store, so `delete_own_account` records a
-- purge for the scheduler's sweep to action through the Storage API. A
-- deleted person's genome left in a bucket is the worst version of this
-- mistake available: it describes them for life and partly describes
-- relatives who never consented to anything.
--
-- Asserted on the function body because the effect is a sweep that runs
-- later and cannot be observed inside a transaction that rolls back. 019
-- reverted this by copying the pre-009 body, and the equivalent assertion in
-- lab_ingest_test.sql is what caught it.

select pg_temp.asserts(
  exists (
    select 1 from pg_proc
     where proname = 'delete_own_account'
       and prosrc like '%storage_purges%'
       and prosrc like '%genetics%'
  ),
  'delete_own_account enqueues the genetics bucket for reclamation too'
);

select pg_temp.asserts(
  exists (
    select 1 from pg_proc
     where proname = 'delete_own_account'
       and position('storage_purges' in prosrc) < position('delete from auth.users' in prosrc)
  ),
  'and records it before the account is deleted, not after'
);

rollback;
