-- Letting the purge sweep find out what it has to delete.
--
-- The sweep needs the exact object paths under a prefix, and it cannot get them
-- two obvious ways:
--
--   * PostgREST only exposes the schemas the project declares, and `storage` is
--     not one of them, so `from('objects')` cannot reach `storage.objects`.
--   * The Storage API's own list call returns a folder's immediate children, so
--     reaching every file under `{user}/` would mean walking the tree one
--     request per report — slow, and racy against anything still uploading.
--
-- Reading the rows is exact and cheap, which is the reason 009 stopped deleting
-- them: they are the only record of what the bytes are called.
--
-- `security definer` because `storage.objects` is owned by the storage role.
-- Exposed to no one: service-role callers bypass RLS, and nothing in the app
-- has any reason to enumerate another layer's storage.

create or replace function public.storage_objects_under(
  p_bucket text,
  p_prefix text
)
returns table (name text)
language plpgsql
security definer set search_path = ''
as $$
begin
  -- A prefix must name a folder. Requiring the trailing slash is what makes
  -- `{uid}/` fail to match `{uid}-archive/...`, which a bare string compare
  -- would happily take — and deleting a live user's reports is unrecoverable.
  if p_prefix is null or p_prefix = '' or right(p_prefix, 1) <> '/' then
    raise exception 'a purge prefix must be a non-empty folder path ending in /';
  end if;
  if p_prefix like '%..%' then
    raise exception 'a purge prefix must not contain ..';
  end if;

  return query
    select o.name::text
      from storage.objects o
     where o.bucket_id = p_bucket
       -- `like` would treat _ and % in a path as wildcards; this is a literal
       -- prefix test.
       and left(o.name, length(p_prefix)) = p_prefix;
end;
$$;

revoke all on function public.storage_objects_under(text, text) from public;
revoke all on function public.storage_objects_under(text, text) from anon;
revoke all on function public.storage_objects_under(text, text) from authenticated;
