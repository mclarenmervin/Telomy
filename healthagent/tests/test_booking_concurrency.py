"""Real PostgreSQL concurrency proofs for the F11 booking commands."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from uuid import uuid4

import psycopg
import pytest


MIGRATION = Path(__file__).parents[1] / "db" / "028_centre_operations.sql"


@pytest.fixture(scope="module")
def booking_database():
    initdb = shutil.which("initdb")
    pg_ctl = shutil.which("pg_ctl")
    if not initdb or not pg_ctl:
        pytest.skip("local PostgreSQL binaries are required for concurrency tests")

    root = Path(tempfile.mkdtemp(prefix="telomy-booking-pg-", dir="/tmp"))
    data = root / "data"
    socket_dir = root / "socket"
    socket_dir.mkdir()
    port = 55000 + (abs(hash(str(root))) % 10000)
    subprocess.run(
        [initdb, "-D", str(data), "--auth=trust", "--no-locale", "--encoding=UTF8"],
        check=True,
        capture_output=True,
        text=True,
    )
    subprocess.run(
        [
            pg_ctl,
            "-D",
            str(data),
            "-o",
            f"-F -c listen_addresses='' -k {socket_dir} -p {port}",
            "-l",
            str(root / "postgres.log"),
            "-w",
            "start",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    dsn = f"dbname=postgres host={socket_dir} port={port}"
    try:
        with psycopg.connect(dsn, autocommit=True) as conn:
            conn.execute(
                """
                create extension if not exists pgcrypto;
                create role anon nologin;
                create role authenticated nologin;
                create schema auth;
                create table auth.users (id uuid primary key);
                create function auth.uid() returns uuid language sql stable as $$
                  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
                $$;
                create table profiles (
                  id uuid primary key references auth.users(id),
                  app_role text not null
                );
                create function app_role_of(p_user uuid) returns text
                language sql stable security definer set search_path=public,pg_temp as $$
                  select app_role from profiles where id = p_user
                $$;
                create table centres (
                  id uuid primary key default gen_random_uuid(),
                  name text not null,
                  status text not null default 'active',
                  created_by uuid not null references auth.users(id),
                  created_at timestamptz not null default now(),
                  updated_at timestamptz not null default now()
                );
                create table centre_memberships (
                  id uuid primary key default gen_random_uuid(),
                  centre_id uuid not null references centres(id),
                  user_id uuid not null references auth.users(id),
                  member_kind text not null,
                  status text not null,
                  invited_by uuid not null references auth.users(id),
                  accepted_at timestamptz,
                  left_at timestamptz
                );
                create function active_centre_membership(
                  p_user uuid, p_centre uuid, p_kind text
                ) returns boolean language sql stable security definer
                set search_path=public,pg_temp as $$
                  select exists (
                    select 1 from centre_memberships membership
                    join centres centre on centre.id = membership.centre_id
                    where membership.user_id = p_user
                      and membership.centre_id = p_centre
                      and membership.member_kind = p_kind
                      and membership.status = 'active'
                      and membership.left_at is null
                      and centre.status = 'active'
                  )
                $$;
                create function centre_owner_may_manage(
                  p_actor uuid, p_centre uuid
                ) returns boolean language sql stable security definer
                set search_path=public,pg_temp as $$
                  select app_role_of(p_actor) = 'centre'
                    and active_centre_membership(p_actor, p_centre, 'owner')
                $$;
                """
            )
            conn.execute(MIGRATION.read_text())
        yield dsn
    finally:
        subprocess.run(
            [pg_ctl, "-D", str(data), "-m", "fast", "-w", "stop"],
            check=True,
            capture_output=True,
            text=True,
        )
        shutil.rmtree(root, ignore_errors=True)


@pytest.fixture()
def booking_scope(booking_database: str):
    owner, patient, centre = uuid4(), uuid4(), uuid4()
    with psycopg.connect(booking_database, autocommit=True) as conn:
        conn.execute("insert into auth.users (id) values (%s), (%s)", (owner, patient))
        conn.execute(
            "insert into profiles (id, app_role) values (%s, 'centre'), (%s, 'member')",
            (owner, patient),
        )
        conn.execute(
            "insert into centres (id, name, created_by) values (%s, 'Concurrent Centre', %s)",
            (centre, owner),
        )
        conn.execute(
            """insert into centre_memberships
               (centre_id, user_id, member_kind, status, invited_by, accepted_at)
               values (%s, %s, 'owner', 'active', %s, now()),
                      (%s, %s, 'patient', 'active', %s, now())""",
            (centre, owner, owner, centre, patient, owner),
        )
        room = conn.execute(
            "select create_centre_room(%s, %s, 'Concurrency Room')", (owner, centre)
        ).fetchone()[0]
        conn.execute(
            "select add_centre_room_hours(%s, %s, %s, 1, '09:00', '17:00', '2030-01-01', null)",
            (owner, centre, room),
        )
        service = conn.execute(
            "select create_centre_service(%s, %s, 'Session', null, 45, 10000, 'INR')",
            (owner, centre),
        ).fetchone()[0]
        conn.execute(
            "select link_centre_room_service(%s, %s, %s, %s)",
            (owner, centre, room, service),
        )
    return {
        "dsn": booking_database,
        "owner": owner,
        "patient": patient,
        "centre": centre,
        "room": room,
        "service": service,
    }


def _race(callables):
    barrier = threading.Barrier(len(callables))

    def run(operation):
        barrier.wait(timeout=5)
        try:
            return ("ok", operation())
        except psycopg.Error as exc:
            return (exc.sqlstate, None)

    with ThreadPoolExecutor(max_workers=len(callables)) as pool:
        return list(pool.map(run, callables))


def test_only_one_overlapping_room_booking_commits(booking_scope):
    scope = booking_scope

    def create(start: str):
        with psycopg.connect(scope["dsn"]) as conn:
            conn.execute("set local statement_timeout = '5s'")
            return conn.execute(
                "select create_centre_booking(%s, %s, %s, %s, %s, %s::timestamptz)",
                (
                    scope["owner"],
                    scope["centre"],
                    scope["patient"],
                    scope["service"],
                    scope["room"],
                    start,
                ),
            ).fetchone()[0]

    outcomes = _race(
        [
            lambda: create("2030-01-07 10:00 Asia/Kolkata"),
            lambda: create("2030-01-07 10:15 Asia/Kolkata"),
        ]
    )
    assert sorted(outcome[0] for outcome in outcomes) == ["23P01", "ok"]
    with psycopg.connect(scope["dsn"]) as conn:
        assert conn.execute(
            "select count(*) from centre_bookings where centre_id = %s", (scope["centre"],)
        ).fetchone()[0] == 1


def test_only_one_same_version_transition_commits(booking_scope):
    scope = booking_scope
    with psycopg.connect(scope["dsn"]) as conn:
        booking = conn.execute(
            "select create_centre_booking(%s, %s, %s, %s, %s, %s::timestamptz)",
            (
                scope["owner"],
                scope["centre"],
                scope["patient"],
                scope["service"],
                scope["room"],
                "2030-01-07 12:00 Asia/Kolkata",
            ),
        ).fetchone()[0]

    def transition(command: str):
        with psycopg.connect(scope["dsn"]) as conn:
            conn.execute("set local statement_timeout = '5s'")
            return conn.execute(
                "select transition_centre_booking(%s, %s, %s, %s, 0, null)",
                (scope["owner"], scope["centre"], booking, command),
            ).fetchone()[0]

    outcomes = _race([lambda: transition("check_in"), lambda: transition("cancel")])
    assert sorted(outcome[0] for outcome in outcomes) == ["40001", "ok"]
    with psycopg.connect(scope["dsn"]) as conn:
        status, version = conn.execute(
            "select status, version from centre_bookings where id = %s", (booking,)
        ).fetchone()
        assert status in {"checked_in", "cancelled"}
        assert version == 1
        assert conn.execute(
            "select count(*) from centre_booking_transitions where booking_id = %s",
            (booking,),
        ).fetchone()[0] == 2
