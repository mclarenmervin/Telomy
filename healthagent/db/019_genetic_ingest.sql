-- Getting a genetics export into the four rows we keep from it.
--
-- A clone of `007_lab_ingest.sql` in shape, because the problem is the same
-- one: a large file the user owns, which must not pass through the gateway
-- (P4), whose isolation must be the storage layer's rather than our code
-- remembering to filter.
--
-- ── Why a separate bucket from lab-reports ──────────────────────────────────
--
-- One bucket per sensitivity class, as the plan says. A lab report and a
-- genome are not the same kind of secret: a lab report describes a person
-- today and a genome describes them for life and partly describes their
-- relatives, who never consented to anything. Separate buckets mean a policy
-- mistake on one cannot reach the other, and mean the two can have different
-- retention later without a migration that moves objects.
--
-- ── Why the raw file is kept at all ─────────────────────────────────────────
--
-- This is the uncomfortable part and it deserves stating rather than
-- defaulting. `genetic_variants` holds four rows; the export holds 600,000,
-- and keeping it means keeping every one of the variants the allowlist
-- refused, in a bucket, indefinitely.
--
-- It is kept because a user who re-imports after the allowlist grows should
-- not have to find the file again, and because an import that read a file
-- wrongly is not diagnosable without the file. Both are real.
--
-- But the balance is different from a lab report's, so the object is kept on
-- a short leash: the sweep deletes it once the import has succeeded and the
-- retention window has passed, which `GENETICS_RETENTION_DAYS` sets. A lab
-- PDF is provenance for a number we show forever and is kept forever; a
-- genetics export is provenance for a parse and is not.
--
-- ── What the phone does ─────────────────────────────────────────────────────
--
-- Uploads the object, then inserts the row. The row firing the webhook is
-- what starts work, exactly as for a lab report, and the job carries no path:
-- the worker re-reads this row, so a replayed webhook cannot pin an import to
-- a stale location.
--
-- The trigger itself is configured outside these migrations, like
-- `lab-uploads-webhook` and `events-webhook`, because it embeds the shared
-- secret:
--
--   AFTER INSERT ON public.genetic_uploads FOR EACH ROW
--   EXECUTE FUNCTION supabase_functions.http_request(
--     '<gateway>/webhooks/genetic-uploads', 'POST', ...)

create table if not exists genetic_uploads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,

  storage_provider text not null default 'supabase'
    check (storage_provider in ('supabase')),

  -- `{user_id}/{yyyy}/{upload_id}/raw.txt` — segment one is the owner, which
  -- is what the storage policies key on.
  storage_path text not null unique,

  --   uploaded     the object is there and nothing has read it
  --   imported     the allowlisted variants are in `genetic_variants`
  --   unreadable   not a 23andMe export or a VCF. A terminal state, and a
  --                different thing from `failed`: there is nothing to retry
  --   failed       something broke on our side
  --   purged       the object is gone and the variants remain
  status text not null default 'uploaded'
    check (status in ('uploaded', 'imported', 'unreadable', 'failed', 'purged')),

  -- Which format the parser recognised, for support rather than for logic.
  source_format text check (source_format in ('23andme', 'vcf')),

  -- How many rows the file held and how many survived the allowlist. A COUNT
  -- and never an identity: "we read 612,431 rows and kept 3" is useful to a
  -- person, and which of the other 612,428 were interesting is precisely
  -- what this product refuses to say. There is no column here, and no column
  -- anywhere, in which a refused rsid could be recorded.
  rows_read integer,
  rows_kept integer,

  -- Why a user sees "we could not read this" rather than a spinner forever.
  -- Never contains a locus.
  failure_reason text,

  -- The same duplicate guard a lab report has: re-importing the same export
  -- would do no harm to `genetic_variants`, whose unique constraint absorbs
  -- it, but it would upload a second copy of a genome.
  content_sha256 text not null,

  imported_at timestamptz,
  purged_at timestamptz,
  created_at timestamptz not null default now(),

  unique (user_id, content_sha256)
);

create index if not exists genetic_uploads_user_time_idx
  on genetic_uploads (user_id, created_at desc);

alter table genetic_uploads enable row level security;

create policy "users read their own genetic uploads"
  on genetic_uploads for select
  using (user_id = (select auth.uid()));

-- The phone inserts the row that starts the import, so this policy exists --
-- unlike `genetic_variants`, where it deliberately does not. F3 shipped with
-- this missing on `lab_uploads` and the upload silently did nothing.
create policy "users start their own genetic imports"
  on genetic_uploads for insert
  with check (user_id = (select auth.uid()));

-- No update policy: status is the worker's. A client that could set
-- `imported` would be a client that could skip the allowlist.

create policy "users delete their own genetic uploads"
  on genetic_uploads for delete
  using (user_id = (select auth.uid()));


-- ── Storage: the path is the security model ─────────────────────────────────
--
-- 30 MB covers an uncompressed 23andMe export with room to spare. Plain text
-- only: a gzip or a zip would be an archive this product has to open, and an
-- archive from an untrusted source is a class of problem we have no reason to
-- take on for a file the user can decompress on the phone.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('genetics', 'genetics', false, 31457280,
        array['text/plain', 'text/tab-separated-values'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

do $$
begin
  drop policy if exists "genetics are readable by their owner" on storage.objects;
  create policy "genetics are readable by their owner"
    on storage.objects for select using (
      bucket_id = 'genetics'
      and (storage.foldername(name))[1] = auth.uid()::text
    );

  drop policy if exists "genetics are writable into your own folder" on storage.objects;
  create policy "genetics are writable into your own folder"
    on storage.objects for insert with check (
      bucket_id = 'genetics'
      and (storage.foldername(name))[1] = auth.uid()::text
    );

  -- Deliberately NOT replaceable. A lab report can be re-uploaded in place
  -- because the extraction is re-run against it; a genome that changed
  -- underneath an import would mean the stored variants came from a file
  -- that no longer exists. Replacing means a new upload row.
  drop policy if exists "genetics are replaceable by their owner" on storage.objects;

  -- Deletable, and this is the one that matters. Somebody who regrets
  -- uploading their genome must be able to remove the file as well as the
  -- four rows, without closing their account.
  drop policy if exists "genetics are deletable by their owner" on storage.objects;
  create policy "genetics are deletable by their owner"
    on storage.objects for delete using (
      bucket_id = 'genetics'
      and (storage.foldername(name))[1] = auth.uid()::text
    );
end $$;


-- ── Deleting an account takes the genome with it ────────────────────────────
--
-- Extending `delete_own_account` rather than replacing what it does. 007
-- added the lab-reports purge after the same omission was found; a second
-- bucket is a second line, and forgetting it would leave a deleted person's
-- genome in object storage, which is the worst version of this mistake
-- available.

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

  delete from storage.objects
   where bucket_id = 'lab-reports'
     and (storage.foldername(name))[1] = uid::text;

  delete from storage.objects
   where bucket_id = 'genetics'
     and (storage.foldername(name))[1] = uid::text;

  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_own_account() from public;
grant execute on function public.delete_own_account() to authenticated;

comment on table genetic_uploads is
  'One genetics export. The file is kept only until the import has succeeded '
  'and the retention window passes, unlike a lab report, which is provenance '
  'for a number we show forever. rows_read and rows_kept are counts; no '
  'column here or anywhere records which loci were refused.';
