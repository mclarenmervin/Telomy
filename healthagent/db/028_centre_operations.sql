-- F11 centre operations: rooms, services, bookings and tenant-safe history.
--
-- Centre Owner APIs use the service role, so RLS is necessary but insufficient:
-- every procedure below rechecks the current actor and every application query
-- must still carry its derived centre scope. Authenticated clients receive
-- SELECT only; all operational mutation goes through these procedures.

alter table centres
  add column if not exists timezone_name text not null default 'Asia/Kolkata',
  add column if not exists currency_code text not null default 'INR';

alter table centres drop constraint if exists centres_timezone_name_present;
alter table centres add constraint centres_timezone_name_present
  check (length(trim(timezone_name)) > 0);
alter table centres drop constraint if exists centres_currency_code_known;
alter table centres add constraint centres_currency_code_known
  check (currency_code ~ '^[A-Z]{3}$');


-- ── Rooms and configured capacity ──────────────────────────────────────────

create table if not exists centre_rooms (
  id uuid primary key default gen_random_uuid(),
  centre_id uuid not null references centres(id) on delete restrict,
  name text not null check (length(trim(name)) > 0),
  status text not null default 'active'
    check (status in ('active', 'inactive')),
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists centre_rooms_active_name_idx
  on centre_rooms (centre_id, lower(name)) where status = 'active';
create index if not exists centre_rooms_scope_idx
  on centre_rooms (centre_id, status, created_at);

create table if not exists centre_room_hours (
  id uuid primary key default gen_random_uuid(),
  centre_id uuid not null references centres(id) on delete restrict,
  room_id uuid not null references centre_rooms(id) on delete restrict,
  weekday smallint not null check (weekday between 0 and 6),
  opens_at time not null,
  closes_at time not null,
  valid_from date not null default current_date,
  valid_until date,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint centre_room_hours_positive check (opens_at < closes_at),
  constraint centre_room_hours_validity check (
    valid_until is null or valid_until >= valid_from
  )
);

create index if not exists centre_room_hours_capacity_idx
  on centre_room_hours (centre_id, room_id, weekday, valid_from, valid_until);


-- ── Services and compatible rooms ─────────────────────────────────────────

create table if not exists centre_services (
  id uuid primary key default gen_random_uuid(),
  centre_id uuid not null references centres(id) on delete restrict,
  name text not null check (length(trim(name)) > 0),
  description text,
  duration_minutes integer not null
    check (duration_minutes between 5 and 1440),
  indicative_price_minor bigint not null
    check (indicative_price_minor >= 0),
  currency_code text not null check (currency_code ~ '^[A-Z]{3}$'),
  status text not null default 'active'
    check (status in ('active', 'inactive')),
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists centre_services_active_name_idx
  on centre_services (centre_id, lower(name)) where status = 'active';
create index if not exists centre_services_scope_idx
  on centre_services (centre_id, status, created_at);

create table if not exists centre_room_services (
  id uuid primary key default gen_random_uuid(),
  centre_id uuid not null references centres(id) on delete restrict,
  room_id uuid not null references centre_rooms(id) on delete restrict,
  service_id uuid not null references centre_services(id) on delete restrict,
  linked_by uuid not null references auth.users(id) on delete restrict,
  linked_at timestamptz not null default now(),
  unlinked_by uuid references auth.users(id) on delete restrict,
  unlinked_at timestamptz,
  constraint centre_room_service_unlink_is_whole check (
    (unlinked_at is null and unlinked_by is null)
    or (unlinked_at is not null and unlinked_by is not null)
  )
);

create unique index if not exists centre_room_services_current_idx
  on centre_room_services (centre_id, room_id, service_id)
  where unlinked_at is null;
create index if not exists centre_room_services_service_idx
  on centre_room_services (centre_id, service_id, room_id)
  where unlinked_at is null;


-- ── Bookings and append-only transition history ───────────────────────────

create table if not exists centre_bookings (
  id uuid primary key default gen_random_uuid(),
  centre_id uuid not null references centres(id) on delete restrict,
  patient_id uuid not null references auth.users(id) on delete restrict,
  service_id uuid not null references centre_services(id) on delete restrict,
  room_id uuid not null references centre_rooms(id) on delete restrict,
  scheduled_start timestamptz not null,
  scheduled_end timestamptz not null,
  status text not null default 'booked'
    check (status in ('booked', 'checked_in', 'completed', 'no_show', 'cancelled')),
  version integer not null default 0 check (version >= 0),
  service_name_snapshot text not null
    check (length(trim(service_name_snapshot)) > 0),
  duration_minutes_snapshot integer not null
    check (duration_minutes_snapshot between 5 and 1440),
  indicative_price_minor_snapshot bigint not null
    check (indicative_price_minor_snapshot >= 0),
  currency_code_snapshot text not null
    check (currency_code_snapshot ~ '^[A-Z]{3}$'),
  checked_in_at timestamptz,
  completed_at timestamptz,
  no_show_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint centre_booking_positive_window check (
    scheduled_start < scheduled_end
  ),
  constraint centre_booking_cancel_reason check (
    status <> 'cancelled'
    or checked_in_at is null
    or length(trim(coalesce(cancellation_reason, ''))) > 0
  )
);

create index if not exists centre_bookings_scope_time_idx
  on centre_bookings (centre_id, scheduled_start, status);
create index if not exists centre_bookings_patient_idx
  on centre_bookings (centre_id, patient_id, scheduled_start desc);
create index if not exists centre_bookings_room_active_idx
  on centre_bookings (centre_id, room_id, scheduled_start, scheduled_end)
  where status in ('booked', 'checked_in');

create table if not exists centre_booking_transitions (
  id uuid primary key default gen_random_uuid(),
  centre_id uuid not null references centres(id) on delete restrict,
  booking_id uuid not null references centre_bookings(id) on delete restrict,
  actor_id uuid not null references auth.users(id) on delete restrict,
  from_status text check (
    from_status is null
    or from_status in ('booked', 'checked_in', 'completed', 'no_show', 'cancelled')
  ),
  to_status text not null
    check (to_status in ('booked', 'checked_in', 'completed', 'no_show', 'cancelled')),
  command text not null
    check (command in ('create', 'check_in', 'complete', 'mark_no_show', 'cancel')),
  expected_version integer not null check (expected_version >= 0),
  reason text,
  created_at timestamptz not null default now(),
  constraint centre_booking_create_transition check (
    (command = 'create' and from_status is null and to_status = 'booked')
    or (command <> 'create' and from_status is not null)
  )
);

create index if not exists centre_booking_transitions_booking_idx
  on centre_booking_transitions (centre_id, booking_id, created_at);


-- ── Current-state authority ────────────────────────────────────────────────

create or replace function centre_operational_actor_may_manage(
  p_actor uuid,
  p_centre uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app_role_of(p_actor) = 'admin'
    or centre_owner_may_manage(p_actor, p_centre);
$$;


-- ── History and overlap guards ─────────────────────────────────────────────

create or replace function protect_centre_operation_history()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception '% history is append-only', tg_table_name
      using errcode = '55000';
  end if;

  if tg_table_name = 'centre_rooms' then
    if new.id is distinct from old.id
       or new.centre_id is distinct from old.centre_id
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'room identity is immutable' using errcode = '55000';
    end if;
    new.updated_at := now();
    return new;
  end if;

  if tg_table_name = 'centre_services' then
    if new.id is distinct from old.id
       or new.centre_id is distinct from old.centre_id
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'service identity is immutable' using errcode = '55000';
    end if;
    new.updated_at := now();
    return new;
  end if;

  if tg_table_name = 'centre_room_hours' then
    if new.id is distinct from old.id
       or new.centre_id is distinct from old.centre_id
       or new.room_id is distinct from old.room_id
       or new.weekday is distinct from old.weekday
       or new.opens_at is distinct from old.opens_at
       or new.closes_at is distinct from old.closes_at
       or new.valid_from is distinct from old.valid_from
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'room hours identity is immutable' using errcode = '55000';
    end if;
    if old.valid_until is not null then
      raise exception 'ended room hours are immutable' using errcode = '55000';
    end if;
    return new;
  end if;

  if tg_table_name = 'centre_room_services' then
    if new.id is distinct from old.id
       or new.centre_id is distinct from old.centre_id
       or new.room_id is distinct from old.room_id
       or new.service_id is distinct from old.service_id
       or new.linked_by is distinct from old.linked_by
       or new.linked_at is distinct from old.linked_at then
      raise exception 'room-service link identity is immutable'
        using errcode = '55000';
    end if;
    if old.unlinked_at is not null then
      raise exception 'ended room-service link is immutable'
        using errcode = '55000';
    end if;
    return new;
  end if;

  if tg_table_name = 'centre_bookings' then
    if new.id is distinct from old.id
       or new.centre_id is distinct from old.centre_id
       or new.patient_id is distinct from old.patient_id
       or new.service_id is distinct from old.service_id
       or new.room_id is distinct from old.room_id
       or new.scheduled_start is distinct from old.scheduled_start
       or new.scheduled_end is distinct from old.scheduled_end
       or new.service_name_snapshot is distinct from old.service_name_snapshot
       or new.duration_minutes_snapshot is distinct from old.duration_minutes_snapshot
       or new.indicative_price_minor_snapshot is distinct from old.indicative_price_minor_snapshot
       or new.currency_code_snapshot is distinct from old.currency_code_snapshot
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'booking identity and snapshots are immutable'
        using errcode = '55000';
    end if;
    new.updated_at := now();
    return new;
  end if;

  raise exception 'booking transitions are append-only' using errcode = '55000';
end;
$$;

create or replace function reject_overlapping_room_hours()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if exists (
    select 1
    from centre_room_hours other
    where other.room_id = new.room_id
      and other.weekday = new.weekday
      and other.id <> new.id
      and other.opens_at < new.closes_at
      and other.closes_at > new.opens_at
      and coalesce(other.valid_until, 'infinity'::date) >= new.valid_from
      and coalesce(new.valid_until, 'infinity'::date) >= other.valid_from
  ) then
    raise exception 'room availability overlaps an existing window'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists centre_rooms_history_guard on centre_rooms;
create trigger centre_rooms_history_guard
  before update or delete on centre_rooms
  for each row execute function protect_centre_operation_history();

drop trigger if exists centre_services_history_guard on centre_services;
create trigger centre_services_history_guard
  before update or delete on centre_services
  for each row execute function protect_centre_operation_history();

drop trigger if exists centre_room_hours_history_guard on centre_room_hours;
create trigger centre_room_hours_history_guard
  before update or delete on centre_room_hours
  for each row execute function protect_centre_operation_history();

drop trigger if exists centre_room_hours_overlap_guard on centre_room_hours;
create trigger centre_room_hours_overlap_guard
  before insert or update on centre_room_hours
  for each row execute function reject_overlapping_room_hours();

drop trigger if exists centre_room_services_history_guard on centre_room_services;
create trigger centre_room_services_history_guard
  before update or delete on centre_room_services
  for each row execute function protect_centre_operation_history();

drop trigger if exists centre_bookings_history_guard on centre_bookings;
create trigger centre_bookings_history_guard
  before update or delete on centre_bookings
  for each row execute function protect_centre_operation_history();

drop trigger if exists centre_booking_transitions_history_guard
  on centre_booking_transitions;
create trigger centre_booking_transitions_history_guard
  before update or delete on centre_booking_transitions
  for each row execute function protect_centre_operation_history();


-- ── Configuration commands ────────────────────────────────────────────────

create or replace function create_centre_room(
  p_actor uuid,
  p_centre uuid,
  p_name text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare new_id uuid;
begin
  if not centre_operational_actor_may_manage(p_actor, p_centre) then
    raise exception 'actor cannot manage this centre' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'room name is required' using errcode = '22023';
  end if;
  insert into centre_rooms (
    centre_id, name, created_by, updated_by
  ) values (
    p_centre, trim(p_name), p_actor, p_actor
  ) returning id into new_id;
  return new_id;
end;
$$;

create or replace function set_centre_room_status(
  p_actor uuid,
  p_centre uuid,
  p_room uuid,
  p_status text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not centre_operational_actor_may_manage(p_actor, p_centre)
     or p_status not in ('active', 'inactive') then
    raise exception 'room status change is not permitted' using errcode = '42501';
  end if;
  update centre_rooms set status = p_status, updated_by = p_actor
  where id = p_room and centre_id = p_centre;
  if not found then
    raise exception 'room not found' using errcode = 'P0002';
  end if;
  return p_room;
end;
$$;

create or replace function add_centre_room_hours(
  p_actor uuid,
  p_centre uuid,
  p_room uuid,
  p_weekday integer,
  p_opens_at time,
  p_closes_at time,
  p_valid_from date default current_date,
  p_valid_until date default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare new_id uuid;
begin
  if not centre_operational_actor_may_manage(p_actor, p_centre) then
    raise exception 'actor cannot manage this centre' using errcode = '42501';
  end if;
  if not exists (
    select 1 from centre_rooms
    where id = p_room and centre_id = p_centre and status = 'active'
  ) then
    raise exception 'active room not found' using errcode = 'P0002';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    p_room::text || ':' || p_weekday::text, 0
  ));
  insert into centre_room_hours (
    centre_id, room_id, weekday, opens_at, closes_at,
    valid_from, valid_until, created_by
  ) values (
    p_centre, p_room, p_weekday, p_opens_at, p_closes_at,
    p_valid_from, p_valid_until, p_actor
  ) returning id into new_id;
  return new_id;
end;
$$;

create or replace function create_centre_service(
  p_actor uuid,
  p_centre uuid,
  p_name text,
  p_description text,
  p_duration_minutes integer,
  p_indicative_price_minor bigint,
  p_currency_code text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare new_id uuid;
begin
  if not centre_operational_actor_may_manage(p_actor, p_centre) then
    raise exception 'actor cannot manage this centre' using errcode = '42501';
  end if;
  insert into centre_services (
    centre_id, name, description, duration_minutes,
    indicative_price_minor, currency_code, created_by, updated_by
  ) values (
    p_centre, trim(p_name), nullif(trim(coalesce(p_description, '')), ''),
    p_duration_minutes, p_indicative_price_minor, upper(trim(p_currency_code)),
    p_actor, p_actor
  ) returning id into new_id;
  return new_id;
end;
$$;

create or replace function set_centre_service_status(
  p_actor uuid,
  p_centre uuid,
  p_service uuid,
  p_status text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not centre_operational_actor_may_manage(p_actor, p_centre)
     or p_status not in ('active', 'inactive') then
    raise exception 'service status change is not permitted'
      using errcode = '42501';
  end if;
  update centre_services set status = p_status, updated_by = p_actor
  where id = p_service and centre_id = p_centre;
  if not found then
    raise exception 'service not found' using errcode = 'P0002';
  end if;
  return p_service;
end;
$$;

create or replace function link_centre_room_service(
  p_actor uuid,
  p_centre uuid,
  p_room uuid,
  p_service uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare link_id uuid;
begin
  if not centre_operational_actor_may_manage(p_actor, p_centre) then
    raise exception 'actor cannot manage this centre' using errcode = '42501';
  end if;
  if not exists (
    select 1 from centre_rooms
    where id = p_room and centre_id = p_centre and status = 'active'
  ) or not exists (
    select 1 from centre_services
    where id = p_service and centre_id = p_centre and status = 'active'
  ) then
    raise exception 'active room and service are required' using errcode = '22023';
  end if;
  select id into link_id from centre_room_services
  where centre_id = p_centre and room_id = p_room
    and service_id = p_service and unlinked_at is null;
  if link_id is not null then return link_id; end if;
  insert into centre_room_services (
    centre_id, room_id, service_id, linked_by
  ) values (
    p_centre, p_room, p_service, p_actor
  ) returning id into link_id;
  return link_id;
end;
$$;


-- ── Booking commands ──────────────────────────────────────────────────────

create or replace function create_centre_booking(
  p_actor uuid,
  p_centre uuid,
  p_patient uuid,
  p_service uuid,
  p_room uuid,
  p_scheduled_start timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  centre_timezone text;
  service_row centre_services%rowtype;
  scheduled_finish timestamptz;
  local_start timestamp;
  local_finish timestamp;
  local_day date;
  local_weekday integer;
  new_id uuid;
begin
  if not centre_operational_actor_may_manage(p_actor, p_centre) then
    raise exception 'actor cannot manage this centre' using errcode = '42501';
  end if;

  select timezone_name into centre_timezone
  from centres
  where id = p_centre and status = 'active';
  if centre_timezone is null then
    raise exception 'active centre not found' using errcode = 'P0002';
  end if;

  if not active_centre_membership(p_patient, p_centre, 'patient') then
    raise exception 'active patient membership not found' using errcode = '42501';
  end if;

  select * into service_row
  from centre_services
  where id = p_service and centre_id = p_centre and status = 'active';
  if not found then
    raise exception 'active service not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1
    from centre_rooms room
    join centre_room_services link
      on link.room_id = room.id
     and link.service_id = p_service
     and link.centre_id = p_centre
     and link.unlinked_at is null
    where room.id = p_room
      and room.centre_id = p_centre
      and room.status = 'active'
  ) then
    raise exception 'active compatible room not found' using errcode = '23P01';
  end if;

  if p_scheduled_start is null then
    raise exception 'scheduled start is required' using errcode = '22023';
  end if;
  scheduled_finish := p_scheduled_start
    + make_interval(mins => service_row.duration_minutes);
  local_start := p_scheduled_start at time zone centre_timezone;
  local_finish := scheduled_finish at time zone centre_timezone;
  local_day := local_start::date;
  local_weekday := extract(dow from local_start)::integer;

  if local_finish::date <> local_day or not exists (
    select 1
    from centre_room_hours hours
    where hours.centre_id = p_centre
      and hours.room_id = p_room
      and hours.weekday = local_weekday
      and hours.valid_from <= local_day
      and (hours.valid_until is null or hours.valid_until >= local_day)
      and hours.opens_at <= local_start::time
      and hours.closes_at >= local_finish::time
  ) then
    raise exception 'requested booking is outside room availability'
      using errcode = '23P01';
  end if;

  -- Serialising all bookings for one room is deliberately conservative. It
  -- makes the subsequent overlap check deterministic without weakening the
  -- invariant when two requested intervals start at different instants.
  perform pg_advisory_xact_lock(hashtextextended(p_room::text, 0));
  if exists (
    select 1
    from centre_bookings booking
    where booking.centre_id = p_centre
      and booking.room_id = p_room
      and booking.status in ('booked', 'checked_in')
      and booking.scheduled_start < scheduled_finish
      and booking.scheduled_end > p_scheduled_start
  ) then
    raise exception 'requested booking overlaps an active booking'
      using errcode = '23P01';
  end if;

  insert into centre_bookings (
    centre_id, patient_id, service_id, room_id,
    scheduled_start, scheduled_end, status, version,
    service_name_snapshot, duration_minutes_snapshot,
    indicative_price_minor_snapshot, currency_code_snapshot, created_by
  ) values (
    p_centre, p_patient, p_service, p_room,
    p_scheduled_start, scheduled_finish, 'booked', 0,
    service_row.name, service_row.duration_minutes,
    service_row.indicative_price_minor, service_row.currency_code, p_actor
  ) returning id into new_id;

  insert into centre_booking_transitions (
    centre_id, booking_id, actor_id, from_status, to_status,
    command, expected_version
  ) values (
    p_centre, new_id, p_actor, null, 'booked', 'create', 0
  );

  return new_id;
end;
$$;

create or replace function transition_centre_booking(
  p_actor uuid,
  p_centre uuid,
  p_booking uuid,
  p_command text,
  p_expected_version integer,
  p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  booking_row centre_bookings%rowtype;
  next_status text;
  clean_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  if not centre_operational_actor_may_manage(p_actor, p_centre) then
    raise exception 'actor cannot manage this centre' using errcode = '42501';
  end if;

  select * into booking_row
  from centre_bookings
  where id = p_booking and centre_id = p_centre
  for update;
  if not found then
    raise exception 'booking not found' using errcode = 'P0002';
  end if;

  if booking_row.version <> p_expected_version then
    raise exception 'stale booking version: current version is %', booking_row.version
      using errcode = '40001';
  end if;

  next_status := case
    when booking_row.status = 'booked' and p_command = 'check_in'
      then 'checked_in'
    when booking_row.status = 'booked' and p_command = 'mark_no_show'
      then 'no_show'
    when booking_row.status = 'booked' and p_command = 'cancel'
      then 'cancelled'
    when booking_row.status = 'checked_in' and p_command = 'complete'
      then 'completed'
    when booking_row.status = 'checked_in' and p_command = 'cancel'
      then 'cancelled'
    else null
  end;

  if next_status is null then
    raise exception 'command % is invalid from status %',
      p_command, booking_row.status using errcode = '22023';
  end if;
  if p_command = 'mark_no_show'
     and now() < booking_row.scheduled_start + interval '15 minutes' then
    raise exception 'no-show grace period has not passed' using errcode = '22023';
  end if;
  if booking_row.status = 'checked_in'
     and p_command = 'cancel'
     and clean_reason is null then
    raise exception 'a cancellation reason is required after check-in'
      using errcode = '22023';
  end if;

  update centre_bookings
  set status = next_status,
      version = version + 1,
      checked_in_at = case
        when next_status = 'checked_in' then now() else checked_in_at end,
      completed_at = case
        when next_status = 'completed' then now() else completed_at end,
      no_show_at = case
        when next_status = 'no_show' then now() else no_show_at end,
      cancelled_at = case
        when next_status = 'cancelled' then now() else cancelled_at end,
      cancellation_reason = case
        when next_status = 'cancelled' then clean_reason else cancellation_reason end
  where id = booking_row.id;

  insert into centre_booking_transitions (
    centre_id, booking_id, actor_id, from_status, to_status,
    command, expected_version, reason
  ) values (
    p_centre, p_booking, p_actor, booking_row.status, next_status,
    p_command, p_expected_version, clean_reason
  );

  return p_booking;
end;
$$;

revoke all on function create_centre_room(uuid, uuid, text)
  from public, authenticated, anon;
revoke all on function set_centre_room_status(uuid, uuid, uuid, text)
  from public, authenticated, anon;
revoke all on function add_centre_room_hours(
  uuid, uuid, uuid, integer, time, time, date, date
) from public, authenticated, anon;
revoke all on function create_centre_service(
  uuid, uuid, text, text, integer, bigint, text
) from public, authenticated, anon;
revoke all on function set_centre_service_status(uuid, uuid, uuid, text)
  from public, authenticated, anon;
revoke all on function link_centre_room_service(uuid, uuid, uuid, uuid)
  from public, authenticated, anon;
revoke all on function create_centre_booking(
  uuid, uuid, uuid, uuid, uuid, timestamptz
) from public, authenticated, anon;
revoke all on function transition_centre_booking(
  uuid, uuid, uuid, text, integer, text
) from public, authenticated, anon;


-- ── RLS and privileges ─────────────────────────────────────────────────────

alter table centre_rooms enable row level security;
alter table centre_room_hours enable row level security;
alter table centre_services enable row level security;
alter table centre_room_services enable row level security;
alter table centre_bookings enable row level security;
alter table centre_booking_transitions enable row level security;

create policy "admins and owners read centre rooms"
  on centre_rooms for select using (
    app_role_of(auth.uid()) = 'admin'
    or centre_owner_may_manage(auth.uid(), centre_id)
  );
create policy "admins and owners read centre room hours"
  on centre_room_hours for select using (
    app_role_of(auth.uid()) = 'admin'
    or centre_owner_may_manage(auth.uid(), centre_id)
  );
create policy "admins and owners read centre services"
  on centre_services for select using (
    app_role_of(auth.uid()) = 'admin'
    or centre_owner_may_manage(auth.uid(), centre_id)
  );
create policy "admins and owners read centre room service links"
  on centre_room_services for select using (
    app_role_of(auth.uid()) = 'admin'
    or centre_owner_may_manage(auth.uid(), centre_id)
  );
create policy "admins and owners read centre bookings"
  on centre_bookings for select using (
    app_role_of(auth.uid()) = 'admin'
    or centre_owner_may_manage(auth.uid(), centre_id)
  );
create policy "admins and owners read centre booking history"
  on centre_booking_transitions for select using (
    app_role_of(auth.uid()) = 'admin'
    or centre_owner_may_manage(auth.uid(), centre_id)
  );

grant select on centre_rooms, centre_room_hours, centre_services,
  centre_room_services, centre_bookings, centre_booking_transitions
  to authenticated;

revoke insert, update, delete on centre_rooms from authenticated, anon;
revoke insert, update, delete on centre_room_hours from authenticated, anon;
revoke insert, update, delete on centre_services from authenticated, anon;
revoke insert, update, delete on centre_room_services from authenticated, anon;
revoke insert, update, delete on centre_bookings from authenticated, anon;
revoke insert, update, delete on centre_booking_transitions
  from authenticated, anon;
