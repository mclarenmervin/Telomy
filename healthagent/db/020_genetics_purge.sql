-- Restoring `delete_own_account`, and adding the genetics bucket to it
-- properly this time.
--
-- 019 redefined this function by copying the version in 007 and adding a
-- second bucket to it. 007's version was superseded by 009, which changed the
-- mechanism entirely: it stopped deleting `storage.objects` rows directly --
-- which makes a file unreachable without reclaiming it, because Postgres
-- cannot reach the object store -- and started recording a row in
-- `storage_purges` for the scheduler's sweep to action through the Storage
-- API.
--
-- Copying the older body silently reverted that. A deleted user's lab PDFs
-- would have been unreachable and still present in the bucket, which is the
-- difference between deleting somebody's data and hiding it from them. The
-- SQL test for 007 caught it on the next run, by asserting on the function
-- body rather than on the effect -- the effect is a sweep that runs later and
-- cannot be observed inside a transaction that rolls back.
--
-- The lesson worth keeping: `create or replace function` in a migration is not
-- additive, and the version to extend is whichever migration last touched it,
-- not the one that created it.

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
  --
  -- One row per bucket. A genome is the item on this list it would be worst
  -- to leave behind: it describes the person for life, and partly describes
  -- relatives who never consented to anything.
  insert into public.storage_purges (bucket_id, path_prefix, reason, requested_for)
  values ('lab-reports', uid::text || '/', 'account_deleted', uid),
         ('genetics',    uid::text || '/', 'account_deleted', uid)
  on conflict (bucket_id, path_prefix) do nothing;

  -- The storage.objects rows are deliberately left in place for the sweep to
  -- remove through the Storage API, which is the only thing that also
  -- reclaims the underlying object.
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_own_account() from public;
grant execute on function public.delete_own_account() to authenticated;
