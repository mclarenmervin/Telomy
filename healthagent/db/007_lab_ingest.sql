-- Lab ingestion: many files per report, provenance for every date, and the
-- privacy and confirmation boundaries that 005 left open.
--
-- 005 assumed one report was one PDF. It is not. Users photograph a three-page
-- panel, and those three images are one report: one patient-name check, one
-- collection date, one extraction job, one duplicate check. Modelled as three
-- uploads it would be three of each, and duplicate detection would break
-- outright, because each image carries its own digest.
--
-- Three further things 005 left open, each a real hole rather than a tidy-up:
--
--   * No foreign key to auth.users on any of these tables. health_measurements
--     and lab_results cascade from a deleted account; lab_uploads,
--     biomarker_results and epigenetic_results did not, so deleting a user left
--     every lab value they ever uploaded in the database permanently.
--
--   * The phone could UPDATE its own biomarker_results. One statement setting
--     status='confirmed' skipped the patient-name check, the collection-date
--     prompt, the health_measurements projection with origin='server' and the
--     score recompute — leaving a row that reads confirmed and that no score
--     will ever read.
--
--   * No bucket existed, so nothing enforced a size cap or a MIME allowlist,
--     and nothing isolated one user's reports from another's.
--
-- Tested by db/tests/lab_ingest_test.sql.

-- ── A report belongs to a real account ───────────────────────────────────────
--
-- Cascade rather than restrict: a user deleting their account must take their
-- lab history with them, and failing the delete would be the wrong answer.
-- reference_range_overrides.created_by is deliberately left without one — a
-- clinician leaving must not delete the ranges they set for other people.

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'lab_uploads_user_fkey') then
    alter table lab_uploads add constraint lab_uploads_user_fkey
      foreign key (user_id) references auth.users(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'biomarker_results_user_fkey') then
    alter table biomarker_results add constraint biomarker_results_user_fkey
      foreign key (user_id) references auth.users(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'epigenetic_results_user_fkey') then
    alter table epigenetic_results add constraint epigenetic_results_user_fkey
      foreign key (user_id) references auth.users(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'range_overrides_user_fkey') then
    alter table reference_range_overrides add constraint range_overrides_user_fkey
      foreign key (user_id) references auth.users(id) on delete cascade;
  end if;
end $$;


-- ── One report, many files ───────────────────────────────────────────────────
--
-- `storage_path` becomes `storage_prefix`: the report's folder, not a file. The
-- files hang off lab_upload_files, and `content_sha256` on the parent is now a
-- digest over the ordered set of file digests, so it still identifies a report
-- and the `unique (user_id, content_sha256)` from 005 keeps working unchanged.

alter table lab_uploads rename column storage_path to storage_prefix;

alter table lab_uploads
  -- The three dates are different and real reports label none of them clearly.
  -- Trending uses collection date only; getting this wrong puts a 2023 panel on
  -- today's chart. `created_at` is the upload date and already exists.
  add column if not exists reported_at timestamptz,
  add column if not exists collected_at_source text not null default 'unknown',
  -- A new user uploading five years of reports in one sitting must not fire
  -- five years of retroactive alerts or create five years of clinician drafts.
  add column if not exists is_history boolean not null default false,
  -- OCR'd documents force the confirmation step rather than being silently
  -- accepted, so how we read the file is part of the record.
  add column if not exists text_layer text,
  add column if not exists extraction_version text;

alter table lab_uploads
  drop constraint if exists lab_uploads_collected_at_source_check,
  add constraint lab_uploads_collected_at_source_check
    check (collected_at_source in ('extracted', 'user', 'unknown'));

alter table lab_uploads
  drop constraint if exists lab_uploads_text_layer_check,
  add constraint lab_uploads_text_layer_check
    check (text_layer is null or text_layer in ('native', 'ocr', 'none'));

-- `confirmed` is the state after the user has been through the panel; the
-- original set stopped at `extracted` and had nowhere to record that.
alter table lab_uploads drop constraint if exists lab_uploads_status_check;
alter table lab_uploads add constraint lab_uploads_status_check
  check (status in ('uploaded', 'extracting', 'extracted',
                    'needs_password', 'confirmed', 'failed'));

create table if not exists lab_upload_files (
  id uuid primary key default gen_random_uuid(),
  upload_id uuid not null references lab_uploads(id) on delete cascade,
  storage_path text not null unique,
  content_sha256 text not null,
  -- Zero-based, and it is what `biomarker_results.page` refers to. Two files
  -- claiming one position would make page/bbox provenance meaningless.
  page_index integer not null check (page_index >= 0),
  kind text not null check (kind in ('pdf', 'image')),
  byte_size bigint check (byte_size > 0),
  created_at timestamptz not null default now(),

  unique (upload_id, page_index),
  -- The same photograph attached twice would double every value read from it.
  unique (upload_id, content_sha256)
);

create index if not exists lab_upload_files_upload_idx
  on lab_upload_files (upload_id, page_index);


-- ── The same marker twice in one report ──────────────────────────────────────
--
-- Fasting and post-prandial glucose from one draw are two real results, not a
-- duplicate, so identity is (biomarker_id, collected_at, context) and never
-- marker alone.

alter table biomarker_results
  add column if not exists context text not null default 'standard',
  -- The conversion factors that produced value_canonical live in the catalog,
  -- so a value is only reproducible alongside the version that converted it.
  add column if not exists catalog_version text,
  add column if not exists extraction_version text;

-- Two indexes rather than one, because collected_at is legitimately null while
-- the confirmation UI is still asking for it.
--
-- Dated results are unique per marker, instant and context across the whole
-- account: the same panel arriving as a PDF and again as photographs is a
-- duplicate however it is packaged.
--
-- Undated results are unique only within their own report. A single unique
-- index over a nullable column would not constrain them at all — SQL counts
-- nulls as distinct, so re-running the worker would silently double them —
-- while folding nulls together across reports would block a user who legitimately
-- uploads two reports that each omit a readable collection date.
create unique index if not exists biomarker_results_dated_identity_idx
  on biomarker_results (user_id, biomarker_id, collected_at, context)
  where collected_at is not null and status <> 'rejected';

create unique index if not exists biomarker_results_undated_identity_idx
  on biomarker_results (user_id, upload_id, biomarker_id, context)
  where collected_at is null and status <> 'rejected';


-- ── Confirmation cannot be self-served ───────────────────────────────────────
--
-- Status transitions move through POST /api/v1/labs/uploads/{id}/confirm under
-- the service role, which is the only path that also runs the patient-name
-- check, captures the collection date, projects into health_measurements with
-- origin='server' and queues the recompute. The phone keeps its read.

drop policy if exists "users confirm their own results" on biomarker_results;

alter table lab_upload_files enable row level security;

create policy "users read files of their own uploads"
  on lab_upload_files for select using (
    upload_id in (select id from lab_uploads where user_id = auth.uid())
  );


-- ── Storage: the path is the security model ──────────────────────────────────
--
-- Private bucket, and isolation is enforced by the storage layer keyed on the
-- first path segment rather than by our code remembering to filter. The size
-- cap and MIME allowlist sit on the bucket because uploaded files are untrusted
-- and the phone writes to Storage directly — app code is not in that path.
--
-- 20 MB covers a multi-page photographed panel. HEIC is deliberately absent:
-- the phone exports JPEG at capture, which is one line there against a server
-- dependency and a class of failures here.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('lab-reports', 'lab-reports', false, 20971520,
        array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

do $$
begin
  -- `{user_id}/{yyyy}/{report_uuid}/{index}.ext` — segment one is the owner.
  drop policy if exists "lab reports are readable by their owner" on storage.objects;
  create policy "lab reports are readable by their owner"
    on storage.objects for select using (
      bucket_id = 'lab-reports'
      and (storage.foldername(name))[1] = auth.uid()::text
    );

  drop policy if exists "lab reports are writable into your own folder" on storage.objects;
  create policy "lab reports are writable into your own folder"
    on storage.objects for insert with check (
      bucket_id = 'lab-reports'
      and (storage.foldername(name))[1] = auth.uid()::text
    );

  drop policy if exists "lab reports are replaceable by their owner" on storage.objects;
  create policy "lab reports are replaceable by their owner"
    on storage.objects for update using (
      bucket_id = 'lab-reports'
      and (storage.foldername(name))[1] = auth.uid()::text
    );

  -- Deletable so a user can abandon a half-finished upload, and so account
  -- deletion can purge.
  drop policy if exists "lab reports are deletable by their owner" on storage.objects;
  create policy "lab reports are deletable by their owner"
    on storage.objects for delete using (
      bucket_id = 'lab-reports'
      and (storage.foldername(name))[1] = auth.uid()::text
    );
end $$;


-- ── Deleting an account takes the reports with it ────────────────────────────
--
-- The cascades above handle the rows. The objects need saying explicitly, or a
-- deleted user's lab PDFs stay in the bucket — which 202609140001 did not do
-- because there was no bucket to clear.
--
-- Deleting the storage.objects row removes every route to the file: the bucket
-- is private and signed URLs are issued from that row. The underlying blob is
-- reclaimed by the scheduler's storage sweep, which reconciles objects against
-- rows; a DELETE here cannot reach the object store from inside Postgres.

create or replace function public.delete_own_account()
returns void
language plpgsql
security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'delete_own_account requires an authenticated caller';
  end if;

  -- Before auth.users, because afterwards there is no uid to scope this by.
  delete from storage.objects
   where bucket_id = 'lab-reports'
     and (storage.foldername(name))[1] = uid::text;

  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_own_account() from public;
grant execute on function public.delete_own_account() to authenticated;
