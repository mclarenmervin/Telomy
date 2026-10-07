-- Making "deleted" mean the bytes are gone, not just unreachable.
--
-- 007 had `delete_own_account` delete the user's `storage.objects` rows. That
-- removes every route to the file — the bucket is private and signed URLs are
-- issued from that row — but it does **not** remove the object from the store
-- behind it. Postgres cannot reach the object store; only the Storage API can,
-- and only something outside a SQL function can call it.
--
-- Worse, deleting the row first destroys the one record of what to delete. By
-- the time anything could reclaim the blob, nothing knows its path. The purge
-- has to be recorded *before* the row goes.
--
-- So account deletion now enqueues the work and leaves the rows alone. Between
-- the delete and the sweep the files are already unreachable: the policies key
-- on `auth.uid()`, and the account that could satisfy them no longer exists.
--
-- The same queue serves any other case where objects outlive their purpose,
-- such as an upload that failed after its files were written.
--
-- Tested by db/tests/lab_ingest_test.sql.

create table if not exists storage_purges (
  id uuid primary key default gen_random_uuid(),
  bucket_id text not null,
  -- A folder prefix, not one object: a report is a folder of files and an
  -- account is a folder of reports, so one row can retire either.
  path_prefix text not null,
  reason text not null check (reason in ('account_deleted', 'upload_failed', 'manual')),
  -- Kept for the audit trail only. The account may already be gone, so this
  -- deliberately has no foreign key — the whole point is that it outlives the user.
  requested_for uuid,
  attempts integer not null default 0,
  last_error text,
  purged_at timestamptz,
  created_at timestamptz not null default now(),

  unique (bucket_id, path_prefix)
);

-- The sweep's query: outstanding work, oldest first.
create index if not exists storage_purges_pending_idx
  on storage_purges (created_at) where purged_at is null;

alter table storage_purges enable row level security;

-- No policy of any kind. Users have no business reading or writing this, and
-- the service role bypasses RLS: the absence of a policy *is* the enforcement,
-- the same way clinical_drafts will have no user-facing select policy.


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

  -- Recorded before the account goes, because afterwards there is no uid to
  -- scope it by and no row left naming the path.
  insert into public.storage_purges (bucket_id, path_prefix, reason, requested_for)
  values ('lab-reports', uid::text || '/', 'account_deleted', uid)
  on conflict (bucket_id, path_prefix) do nothing;

  -- The storage.objects rows are deliberately left in place for the sweep to
  -- remove through the Storage API, which is the only thing that also reclaims
  -- the underlying object. They are already unreachable: the policies key on
  -- auth.uid(), and this account is about to stop existing.
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_own_account() from public;
grant execute on function public.delete_own_account() to authenticated;
