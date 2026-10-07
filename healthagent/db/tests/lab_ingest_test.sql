-- The constraints in 007_lab_ingest.sql encode safety and privacy properties,
-- so they are tested rather than assumed. Each case asserts the database either
-- REFUSES something that would corrupt a clinical result, or ACCEPTS something
-- real reports genuinely contain.
--
-- Runs inside a transaction that always rolls back.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/lab_ingest_test.sql

\set uid '\'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617\''
\set ghost '\'00000000-dead-4000-8000-000000000001\''

begin;

-- Only an integrity violation counts. A missing table or a typo is a broken
-- test, not a passing one — the trap the biomarkers test fell into first time.
create or replace function pg_temp.refuses(stmt text, label text)
returns void language plpgsql as $$
declare
  state text;
begin
  begin
    execute stmt;
  exception
    when integrity_constraint_violation then
      raise notice 'PASS: %', label;
      return;
    when others then
      get stacked diagnostics state = returned_sqlstate;
      raise exception 'FAIL: % — refused for the wrong reason (SQLSTATE %)', label, state;
  end;
  raise exception 'FAIL: % — the database accepted it', label;
end $$;

-- The mirror image, and just as necessary. A schema that refuses a fasting and
-- a post-prandial glucose from the same draw is as broken as one that silently
-- merges them; without this half, the uniqueness rules could be too strict and
-- every test would still pass.
create or replace function pg_temp.accepts(stmt text, label text)
returns void language plpgsql as $$
begin
  execute stmt;
  raise notice 'PASS: %', label;
exception
  when others then
    raise exception 'FAIL: % — the database refused it (%)', label, sqlerrm;
end $$;

create or replace function pg_temp.asserts(ok boolean, label text)
returns void language plpgsql as $$
begin
  if ok then
    raise notice 'PASS: %', label;
  else
    raise exception 'FAIL: %', label;
  end if;
end $$;


-- ── A report belongs to a real account ───────────────────────────────────────
--
-- Without this FK, deleting a user leaves their lab uploads and every value
-- extracted from them in the database forever. health_measurements and
-- lab_results already cascade from auth.users; these tables did not.

select pg_temp.refuses(format($$
  insert into lab_uploads (user_id, storage_prefix, content_sha256)
  values (%L, %L, 'a1')
$$, :ghost, :ghost || '/2026/aaaa/'), 'an upload for a non-existent account is refused');


-- ── One report, many files ───────────────────────────────────────────────────

insert into lab_uploads (id, user_id, storage_prefix, content_sha256)
values ('11111111-1111-4111-8111-111111111111', :uid,
        :uid || '/2026/11111111-1111-4111-8111-111111111111/', 'report-digest-1');

select pg_temp.accepts($$
  insert into lab_upload_files (upload_id, storage_path, content_sha256, page_index, kind)
  values ('11111111-1111-4111-8111-111111111111',
          'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617/2026/11111111-1111-4111-8111-111111111111/0.jpg',
          'file-a', 0, 'image')
$$, 'a photographed page is accepted');

select pg_temp.accepts($$
  insert into lab_upload_files (upload_id, storage_path, content_sha256, page_index, kind)
  values ('11111111-1111-4111-8111-111111111111',
          'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617/2026/11111111-1111-4111-8111-111111111111/1.jpg',
          'file-b', 1, 'image')
$$, 'a second page of the same report is accepted');

-- Two files claiming the same position would make page/bbox provenance
-- ambiguous: "page 1" would no longer identify an image.
select pg_temp.refuses($$
  insert into lab_upload_files (upload_id, storage_path, content_sha256, page_index, kind)
  values ('11111111-1111-4111-8111-111111111111',
          'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617/2026/11111111-1111-4111-8111-111111111111/dup.jpg',
          'file-c', 1, 'image')
$$, 'two files at the same page index are refused');

-- The same photograph attached twice doubles every value read from it.
select pg_temp.refuses($$
  insert into lab_upload_files (upload_id, storage_path, content_sha256, page_index, kind)
  values ('11111111-1111-4111-8111-111111111111',
          'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617/2026/11111111-1111-4111-8111-111111111111/again.jpg',
          'file-a', 2, 'image')
$$, 'the same file content twice in one report is refused');

select pg_temp.refuses($$
  insert into lab_upload_files (upload_id, storage_path, content_sha256, page_index, kind)
  values ('11111111-1111-4111-8111-111111111111',
          'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617/2026/11111111-1111-4111-8111-111111111111/x.tiff',
          'file-d', 3, 'fax')
$$, 'an unsupported file kind is refused');


-- ── The same PDF twice ───────────────────────────────────────────────────────
--
-- The digest is now over the ordered set of file digests, so it still identifies
-- a report rather than a file.

select pg_temp.refuses(format($$
  insert into lab_uploads (user_id, storage_prefix, content_sha256)
  values (%L, %L, 'report-digest-1')
$$, :uid, :uid || '/2026/bbbb/'), 'the same report uploaded twice is refused');


-- ── Upload state the extractor actually needs ────────────────────────────────

select pg_temp.accepts($$
  update lab_uploads set status = 'confirmed'
   where id = '11111111-1111-4111-8111-111111111111'
$$, 'an upload can reach the confirmed state');

select pg_temp.refuses($$
  update lab_uploads set text_layer = 'telepathy'
   where id = '11111111-1111-4111-8111-111111111111'
$$, 'an unknown text-layer provenance is refused');

-- Collection date is the one date trending may use, and the UI must know
-- whether we extracted it or the user told us.
select pg_temp.refuses($$
  update lab_uploads set collected_at_source = 'vibes'
   where id = '11111111-1111-4111-8111-111111111111'
$$, 'an unknown collection-date provenance is refused');


-- ── The same marker twice in one report ──────────────────────────────────────
--
-- Fasting and post-prandial glucose from one draw are two real results, not a
-- duplicate. Keyed by (biomarker_id, collected_at, context), never marker alone.

insert into biomarker_results
  (user_id, upload_id, biomarker_id, value_canonical, unit_canonical, collected_at, context)
values (:uid, '11111111-1111-4111-8111-111111111111', 'glucose_fasting',
        92, 'mg/dL', '2026-09-28T07:30:00Z', 'fasting');

select pg_temp.accepts(format($$
  insert into biomarker_results
    (user_id, upload_id, biomarker_id, value_canonical, unit_canonical, collected_at, context)
  values (%L, '11111111-1111-4111-8111-111111111111', 'glucose_fasting',
          141, 'mg/dL', '2026-09-28T07:30:00Z', 'post_prandial')
$$, :uid), 'the same marker in a second context is accepted');

select pg_temp.refuses(format($$
  insert into biomarker_results
    (user_id, upload_id, biomarker_id, value_canonical, unit_canonical, collected_at, context)
  values (%L, '11111111-1111-4111-8111-111111111111', 'glucose_fasting',
          92, 'mg/dL', '2026-09-28T07:30:00Z', 'fasting')
$$, :uid), 'the same marker, time and context twice is refused');

-- A re-run of the extraction worker must not double the panel.
select pg_temp.asserts(
  (select count(*) from biomarker_results
    where user_id = :uid and biomarker_id = 'glucose_fasting') = 2,
  'one draw yields exactly its two real results');


-- ── Results whose collection date we could not read ──────────────────────────
--
-- Legitimately null while the confirmation UI is still asking. A single unique
-- index over a nullable column would not constrain these at all, because SQL
-- counts nulls as distinct — so a worker re-run would silently double them.

insert into biomarker_results
  (user_id, upload_id, biomarker_id, value_canonical, unit_canonical, collected_at)
values (:uid, '11111111-1111-4111-8111-111111111111', 'ferritin', 60, 'ng/mL', null);

select pg_temp.refuses(format($$
  insert into biomarker_results
    (user_id, upload_id, biomarker_id, value_canonical, unit_canonical, collected_at)
  values (%L, '11111111-1111-4111-8111-111111111111', 'ferritin', 60, 'ng/mL', null)
$$, :uid), 'an undated result cannot be inserted twice for one report');

-- But folding all nulls together across reports would be too strict: a user who
-- uploads two reports that each omit a readable date must not be blocked.
insert into lab_uploads (id, user_id, storage_prefix, content_sha256)
values ('33333333-3333-4333-8333-333333333333', :uid,
        :uid || '/2026/33333333-3333-4333-8333-333333333333/', 'report-digest-3');

select pg_temp.accepts(format($$
  insert into biomarker_results
    (user_id, upload_id, biomarker_id, value_canonical, unit_canonical, collected_at)
  values (%L, '33333333-3333-4333-8333-333333333333', 'ferritin', 72, 'ng/mL', null)
$$, :uid), 'a second undated report may carry the same marker');


-- ── Confirmation cannot be self-served ───────────────────────────────────────
--
-- 005 let the phone UPDATE its own results, so a single statement could set
-- status='confirmed' and skip the patient-name check, the collection-date
-- prompt, the health_measurements projection with origin='server' and the score
-- recompute. The row would read confirmed and no score would ever see it.

select pg_temp.asserts(
  not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'biomarker_results'
       and cmd = 'UPDATE' and 'authenticated' = any(roles)
  ),
  'no end-user UPDATE policy remains on biomarker_results');

select pg_temp.asserts(
  exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'biomarker_results' and cmd = 'SELECT'
  ),
  'the phone can still read its own results');


-- ── Storage is the security boundary ─────────────────────────────────────────

select pg_temp.asserts(
  exists (
    select 1 from storage.buckets
     where id = 'lab-reports' and public = false
       and file_size_limit is not null and allowed_mime_types is not null
  ),
  'the lab-reports bucket is private, size-capped and MIME-restricted');

-- An INSERT policy keeps its expression in with_check and leaves qual null, so
-- testing qual alone would pass on read/update/delete while missing the write
-- policy — the one that stops a user putting a file in someone else's folder.
select pg_temp.asserts(
  (select count(*) from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and coalesce(qual, '') || coalesce(with_check, '') like '%lab-reports%') >= 4,
  'storage.objects carries per-user policies for the lab-reports bucket');

-- Isolation must be enforced by the path, not by our code remembering to filter.
select pg_temp.asserts(
  (select count(*) from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and coalesce(qual, '') || coalesce(with_check, '') like '%foldername%') >= 4,
  'those policies key on the first path segment');

select pg_temp.asserts(
  exists (
    select 1 from pg_policies
     where schemaname = 'storage' and tablename = 'objects' and cmd = 'INSERT'
       and with_check like '%foldername%'
  ),
  'writing into another user''s folder is refused by the bucket, not by app code');


-- ── Critical values escalate once, and only once ─────────────────────────────

insert into lab_escalations
  (user_id, upload_id, biomarker_id, value_canonical, unit, message)
values (:uid, '11111111-1111-4111-8111-111111111111', 'haemoglobin',
        4.1, 'g/dL', 'far outside the range we would expect');

-- The webhook retries and the worker may re-run. A person seeing the same
-- critical value three times is how an alert stops being believed.
select pg_temp.refuses(format($$
  insert into lab_escalations
    (user_id, upload_id, biomarker_id, value_canonical, unit, message)
  values (%L, '11111111-1111-4111-8111-111111111111', 'haemoglobin',
          4.1, 'g/dL', 'far outside the range we would expect')
$$, :uid), 'the same critical finding cannot escalate twice');

select pg_temp.refuses(format($$
  insert into lab_escalations
    (user_id, upload_id, biomarker_id, value_canonical, unit, message, severity)
  values (%L, '11111111-1111-4111-8111-111111111111', 'ferritin',
          9999, 'ng/mL', 'x', 'informational')
$$, :uid), 'an escalation cannot be downgraded below critical');

-- RLS admits rows, not columns. Without column privileges the acknowledge
-- policy would let the phone rewrite the finding itself.
select pg_temp.asserts(
  not exists (
    select 1 from information_schema.column_privileges
     where table_name = 'lab_escalations' and grantee = 'authenticated'
       and privilege_type = 'UPDATE' and column_name <> 'acknowledged_at'
  ),
  'the phone may only acknowledge an escalation, not rewrite it');

select pg_temp.asserts(
  exists (
    select 1 from information_schema.column_privileges
     where table_name = 'lab_escalations' and grantee = 'authenticated'
       and privilege_type = 'UPDATE' and column_name = 'acknowledged_at'
  ),
  'the phone can still mark an escalation as seen');

select pg_temp.asserts(
  not exists (
    select 1 from pg_policies
     where tablename = 'lab_escalations' and cmd in ('INSERT', 'DELETE')
  ),
  'the phone cannot manufacture or remove an escalation');


-- ── Deleting an account takes the reports with it ────────────────────────────

insert into auth.users (id, email)
values (:ghost, 'ghost@example.test');

insert into lab_uploads (id, user_id, storage_prefix, content_sha256)
values ('22222222-2222-4222-8222-222222222222', :ghost,
        :ghost || '/2026/22222222-2222-4222-8222-222222222222/', 'report-digest-2');

insert into lab_upload_files (upload_id, storage_path, content_sha256, page_index, kind)
values ('22222222-2222-4222-8222-222222222222',
        '00000000-dead-4000-8000-000000000001/2026/22222222-2222-4222-8222-222222222222/0.pdf',
        'ghost-file', 0, 'pdf');

insert into biomarker_results
  (user_id, upload_id, biomarker_id, value_canonical, unit_canonical, collected_at)
values (:ghost, '22222222-2222-4222-8222-222222222222', 'hba1c', 5.4, '%', now());

insert into epigenetic_results (user_id, clock, value, unit, provider, collected_at)
values (:ghost, 'phenoage', 41.2, 'years', 'TruDiagnostic', now());

delete from auth.users where id = :ghost;

select pg_temp.asserts(
  not exists (select 1 from lab_uploads where user_id = :ghost)
  and not exists (select 1 from lab_upload_files
                   where upload_id = '22222222-2222-4222-8222-222222222222')
  and not exists (select 1 from biomarker_results where user_id = :ghost)
  and not exists (select 1 from epigenetic_results where user_id = :ghost),
  'deleting an account removes its uploads, files, results and clocks');

-- Postgres rows are only half of it. The objects themselves must go too, or a
-- deleted user''s lab PDFs are merely unreachable rather than gone — and
-- Postgres cannot reach the object store, so the work has to be handed to
-- something that can. Recorded before the account goes, because afterwards
-- there is no uid to scope it by and no row left naming the path.
select pg_temp.asserts(
  exists (
    select 1 from pg_proc
     where proname = 'delete_own_account' and prosrc like '%storage_purges%'
  ),
  'delete_own_account enqueues the user''s objects for reclamation');

select pg_temp.asserts(
  exists (
    select 1 from pg_proc
     where proname = 'delete_own_account'
       and position('storage_purges' in prosrc) < position('delete from auth.users' in prosrc)
  ),
  'the purge is recorded before the account is deleted, not after');

-- One prefix cannot be queued twice, or the sweep does the same work forever.
insert into storage_purges (bucket_id, path_prefix, reason)
values ('lab-reports', 'some-user/', 'account_deleted');

select pg_temp.refuses($$
  insert into storage_purges (bucket_id, path_prefix, reason)
  values ('lab-reports', 'some-user/', 'manual')
$$, 'the same prefix cannot be queued for purge twice');

select pg_temp.refuses($$
  insert into storage_purges (bucket_id, path_prefix, reason)
  values ('lab-reports', 'other-user/', 'because-i-said-so')
$$, 'a purge needs a reason we recognise');

-- requested_for deliberately has no foreign key: the row has to outlive the
-- account it belongs to, which is the entire point of it.
select pg_temp.accepts($$
  insert into storage_purges (bucket_id, path_prefix, reason, requested_for)
  values ('lab-reports', 'long-gone-user/', 'account_deleted',
          '00000000-0000-4000-8000-00000000dead')
$$, 'a purge survives the account that asked for it');

-- No policy at all: users have no business reading this, and the absence of a
-- policy is the enforcement rather than a filter someone has to remember.
select pg_temp.asserts(
  not exists (select 1 from pg_policies where tablename = 'storage_purges'),
  'storage_purges is not reachable by any user role');

rollback;
