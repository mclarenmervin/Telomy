-- Normalized application storage. The legacy wellness_documents table remains
-- temporarily available so existing installations can migrate on first load.

create table if not exists public.user_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  profile jsonb not null default '{}'::jsonb,
  demo boolean not null default false,
  updated_at timestamptz not null default now()
);

create table if not exists public.health_measurements (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  measurement_type text not null,
  value double precision not null,
  secondary_value double precision,
  unit text not null,
  recorded_at timestamptz not null,
  source text not null,
  device_id text,
  quality text not null default 'measured',
  ended_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists health_measurements_user_time_idx
  on public.health_measurements (user_id, recorded_at desc);
create index if not exists health_measurements_user_type_time_idx
  on public.health_measurements (user_id, measurement_type, recorded_at desc);

create table if not exists public.wearable_devices (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null,
  name text not null default '',
  firmware text,
  battery integer check (battery between 0 and 100),
  last_sync timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, device_id)
);
create table if not exists public.wearable_daily_reports (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null,
  report_date date not null,
  snapshot jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, device_id, report_date),
  foreign key (user_id, device_id)
    references public.wearable_devices(user_id, device_id) on delete cascade
);

-- Each product module has an independently queryable table. Flexible fields
-- remain JSONB because the UI definitions are extensible, while identity,
-- ownership, relationships and time are relational columns.
do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'timeline_events', 'therapy_sessions', 'meals', 'workouts',
    'hydration_logs', 'environment_logs', 'genetic_records', 'plans',
    'progress_checkins', 'lab_results', 'medications', 'medication_doses',
    'consultations', 'community_posts', 'community_replies'
  ] loop
    execute format(
      'create table if not exists public.%I (
        id uuid primary key,
        user_id uuid not null references auth.users(id) on delete cascade,
        title text not null,
        recorded_at timestamptz not null,
        notes text not null default '''',
        fields jsonb not null default ''{}''::jsonb,
        parent_id uuid,
        created_at timestamptz not null default now(),
        updated_at timestamptz not null default now()
      )', table_name
    );
    execute format(
      'create index if not exists %I on public.%I (user_id, recorded_at desc)',
      table_name || '_user_time_idx', table_name
    );
  end loop;
end $$;

-- RLS is identical for every private user-owned table.
do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'user_preferences', 'health_measurements', 'wearable_devices',
    'wearable_daily_reports', 'timeline_events', 'therapy_sessions', 'meals',
    'workouts', 'hydration_logs', 'environment_logs', 'genetic_records',
    'plans', 'progress_checkins', 'lab_results', 'medications',
    'medication_doses', 'consultations', 'community_posts', 'community_replies'
  ] loop
    execute format('alter table public.%I enable row level security', table_name);
    execute format('drop policy if exists "Users manage own rows" on public.%I', table_name);
    execute format(
      'create policy "Users manage own rows" on public.%I for all to authenticated
       using ((select auth.uid()) = user_id)
       with check ((select auth.uid()) = user_id)', table_name
    );
  end loop;
end $$;

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

  delete from public.health_measurements where user_id = uid;
  insert into public.health_measurements(
    id, user_id, measurement_type, value, secondary_value, unit, recorded_at,
    source, device_id, quality, ended_at
  )
  select
    (item ->> 'id')::uuid, uid, item ->> 'measurement_type',
    (item ->> 'value')::double precision,
    nullif(item ->> 'secondary_value', '')::double precision,
    item ->> 'unit', (item ->> 'recorded_at')::timestamptz,
    item ->> 'source', nullif(item ->> 'device_id', ''),
    coalesce(item ->> 'quality', 'measured'),
    nullif(item ->> 'ended_at', '')::timestamptz
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
    execute format('delete from public.%I where user_id = $1', table_names[i]) using uid;
    execute format(
      'insert into public.%I(id,user_id,title,recorded_at,notes,fields,parent_id)
       select (item->>''id'')::uuid, $1, item->>''title'',
              (item->>''recorded_at'')::timestamptz,
              coalesce(item->>''notes'',''''), coalesce(item->''fields'',''{}''::jsonb),
              nullif(item->>''parent_id'','''')::uuid
       from jsonb_array_elements(coalesce($2->''entries'',''[]''::jsonb)) item
       where item->>''kind'' = $3', table_names[i]
    ) using uid, payload, kinds[i];
  end loop;
end;
$$;

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
        order by recorded_at), ''[]''::jsonb) from public.%I where user_id=$1',
      table_names[i]
    ) into part using uid, kinds[i];
    entries := entries || part;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'user_id',user_id,'measurement_type',measurement_type,'value',value,
    'secondary_value',secondary_value,'unit',unit,'recorded_at',recorded_at,
    'source',source,'device_id',device_id,'quality',quality,'ended_at',ended_at)
    order by recorded_at), '[]'::jsonb)
  into measurements from public.health_measurements where user_id = uid;

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
