-- Sync ownership: let the backend write rows the phone cannot destroy.
--
-- `save_normalized_wellness` deletes everything the user owns and re-inserts the
-- phone's copy, which made the phone an unconditional source of truth. Any lab
-- value, genotype, environment snapshot or derived measurement written by the
-- backend disappeared on the next sync — days later, looking like an extraction
-- bug rather than a sync bug.
--
-- `origin` records who wrote a row. The sync RPCs now operate strictly on the
-- phone's own rows:
--
--   save: deletes only origin='app' before re-inserting the phone's copy
--   load: returns only origin='app'
--
-- The load side matters as much as the save side. If load returned server rows,
-- the phone would store them in its local document and send them back on the
-- next save, where they would be inserted again as origin='app' — duplicating
-- every server-written value on every sync. Server-owned data reaches the app
-- through its own purpose-built reads instead.

alter table public.health_measurements
  add column if not exists origin text not null default 'app'
  check (origin in ('app', 'server'));

do $$
declare
  t text;
begin
  foreach t in array array[
    'timeline_events', 'therapy_sessions', 'meals', 'workouts',
    'hydration_logs', 'environment_logs', 'genetic_records', 'plans',
    'progress_checkins', 'lab_results', 'medications', 'medication_doses',
    'consultations', 'community_posts', 'community_replies'
  ] loop
    execute format(
      'alter table public.%I add column if not exists origin text not null
         default ''app'' check (origin in (''app'', ''server''))', t);
  end loop;
end $$;

-- Partial indexes: both RPCs now filter on origin, and the app's rows are the
-- hot path on every sync.
create index if not exists health_measurements_user_app_idx
  on public.health_measurements (user_id) where origin = 'app';

create or replace function public.save_normalized_wellness(payload jsonb)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  ring jsonb := coalesce(payload -> 'ring', '{}'::jsonb);
  ring_id text := ring ->> 'id';
  table_names text[] := array[
    'timeline_events', 'therapy_sessions', 'meals', 'workouts',
    'hydration_logs', 'environment_logs', 'genetic_records', 'plans',
    'progress_checkins', 'lab_results', 'medications', 'medication_doses',
    'consultations', 'community_posts', 'community_replies'
  ];
  kinds text[] := array[
    'event', 'therapy', 'meal', 'workout', 'water', 'environment', 'genetics',
    'plan', 'checkIn', 'lab', 'medication', 'medicationDose', 'consultation',
    'communityPost', 'communityReply'
  ];
  i integer;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  insert into public.user_preferences(user_id, profile, demo, updated_at)
  values (uid, coalesce(payload -> 'profile', '{}'::jsonb),
          coalesce((payload ->> 'demo')::boolean, false), now())
  on conflict (user_id) do update set
    profile = excluded.profile, demo = excluded.demo, updated_at = now();

  -- origin = 'app' only: server-written measurements are not the phone's to delete.
  delete from public.health_measurements where user_id = uid and origin = 'app';
  insert into public.health_measurements(
    id, user_id, measurement_type, value, secondary_value, unit, recorded_at,
    source, device_id, quality, ended_at, origin
  )
  select
    (item ->> 'id')::uuid, uid, item ->> 'measurement_type',
    (item ->> 'value')::double precision,
    nullif(item ->> 'secondary_value', '')::double precision,
    item ->> 'unit', (item ->> 'recorded_at')::timestamptz,
    item ->> 'source', nullif(item ->> 'device_id', ''),
    coalesce(item ->> 'quality', 'measured'),
    nullif(item ->> 'ended_at', '')::timestamptz,
    'app'
  from jsonb_array_elements(coalesce(payload -> 'measurements', '[]'::jsonb)) item;

  delete from public.wearable_devices where user_id = uid;
  if nullif(ring_id, '') is not null then
    insert into public.wearable_devices(
      user_id, device_id, name, firmware, battery, last_sync, metadata, updated_at
    ) values (
      uid, ring_id, coalesce(ring ->> 'name', ''),
      coalesce(ring #>> '{report,firmware}', ring ->> 'firmware'),
      nullif(coalesce(ring #>> '{report,battery}', ring ->> 'battery'), '')::integer,
      nullif(ring ->> 'lastSync', '')::timestamptz,
      ring - 'reports', now()
    );
    insert into public.wearable_daily_reports(user_id, device_id, report_date, snapshot)
    select uid, ring_id, key::date, value
    from jsonb_each(coalesce(ring -> 'reports', '{}'::jsonb));
  end if;

  for i in 1..array_length(table_names, 1) loop
    execute format(
      'delete from public.%I where user_id = $1 and origin = ''app''', table_names[i]
    ) using uid;
    execute format(
      'insert into public.%I(id,user_id,title,recorded_at,notes,fields,parent_id,origin)
       select (item->>''id'')::uuid, $1, item->>''title'',
              (item->>''recorded_at'')::timestamptz,
              coalesce(item->>''notes'',''''), coalesce(item->''fields'',''{}''::jsonb),
              nullif(item->>''parent_id'','''')::uuid, ''app''
       from jsonb_array_elements(coalesce($2->''entries'',''[]''::jsonb)) item
       where item->>''kind'' = $3', table_names[i]
    ) using uid, payload, kinds[i];
  end loop;
end;
$$;

-- The load side of the same change. Returning server-owned rows here would put
-- them into the phone's local document, and the next save would re-insert them
-- as origin='app' — duplicating every server-written value on every sync.

create or replace function public.load_normalized_wellness()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  table_names text[] := array[
    'timeline_events', 'therapy_sessions', 'meals', 'workouts',
    'hydration_logs', 'environment_logs', 'genetic_records', 'plans',
    'progress_checkins', 'lab_results', 'medications', 'medication_doses',
    'consultations', 'community_posts', 'community_replies'
  ];
  kinds text[] := array[
    'event', 'therapy', 'meal', 'workout', 'water', 'environment', 'genetics',
    'plan', 'checkIn', 'lab', 'medication', 'medicationDose', 'consultation',
    'communityPost', 'communityReply'
  ];
  entries jsonb := '[]'::jsonb;
  part jsonb;
  measurements jsonb;
  ring jsonb := '{}'::jsonb;
  reports jsonb := '{}'::jsonb;
  prefs record;
  device record;
  i integer;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into prefs from public.user_preferences where user_id = uid;
  if not found then return null; end if;

  for i in 1..array_length(table_names, 1) loop
    execute format(
      'select coalesce(jsonb_agg(jsonb_build_object(
        ''id'',id,''kind'',$2,''title'',title,''recorded_at'',recorded_at,
        ''notes'',notes,''fields'',fields,''parent_id'',parent_id)
        order by recorded_at), ''[]''::jsonb) from public.%I
       where user_id=$1 and origin=''app''',
      table_names[i]
    ) into part using uid, kinds[i];
    entries := entries || part;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'user_id',user_id,'measurement_type',measurement_type,'value',value,
    'secondary_value',secondary_value,'unit',unit,'recorded_at',recorded_at,
    'source',source,'device_id',device_id,'quality',quality,'ended_at',ended_at)
    order by recorded_at), '[]'::jsonb)
  into measurements from public.health_measurements
   where user_id = uid and origin = 'app';

  select * into device from public.wearable_devices
    where user_id = uid order by updated_at desc limit 1;
  if found then
    select coalesce(jsonb_object_agg(report_date::text, snapshot), '{}'::jsonb)
      into reports from public.wearable_daily_reports
      where user_id = uid and device_id = device.device_id;
    ring := device.metadata || jsonb_build_object(
      'id', device.device_id, 'name', device.name, 'lastSync', device.last_sync,
      'reports', reports
    );
  end if;

  return jsonb_build_object(
    'version', 2, 'profile', prefs.profile, 'entries', entries,
    'measurements', measurements, 'ring', ring, 'demo', prefs.demo
  );
end;
$$;

grant execute on function public.save_normalized_wellness(jsonb) to authenticated;
grant execute on function public.load_normalized_wellness() to authenticated;
