"""Deciding which migrations still need to run.

The decision is pure so it can be tested without a database; applying them is
a thin wrapper around it.

Our migrations are deliberately not idempotent — `alter publication ... add
table` and `create policy` both fail on a second run — so "apply everything on
every deploy" would break the deploy. What makes automatic migration safe is
knowing precisely what has already been applied.
"""

import pytest

from app.migrate.plan import (
    MigrationConflict,
    Migration,
    checksum,
    pending_migrations,
)


def m(name, sql="create table x();"):
    return Migration(name=name, sql=sql)


def test_nothing_applied_means_everything_is_pending():
    available = [m("001_a.sql"), m("002_b.sql")]

    assert [p.name for p in pending_migrations(available, applied={})] == [
        "001_a.sql", "002_b.sql"]


def test_an_applied_migration_is_skipped():
    available = [m("001_a.sql"), m("002_b.sql")]
    applied = {"001_a.sql": checksum("create table x();")}

    assert [p.name for p in pending_migrations(available, applied)] == ["002_b.sql"]


def test_migrations_run_in_filename_order_not_directory_order():
    available = [m("010_j.sql"), m("002_b.sql"), m("001_a.sql")]

    assert [p.name for p in pending_migrations(available, applied={})] == [
        "001_a.sql", "002_b.sql", "010_j.sql"]


def test_editing_an_already_applied_migration_is_refused():
    """Editing applied history silently diverges environments: this database
    ran one thing, the next database will run another."""
    available = [m("001_a.sql", sql="create table y();")]
    applied = {"001_a.sql": checksum("create table x();")}

    with pytest.raises(MigrationConflict, match="001_a.sql"):
        pending_migrations(available, applied)


def test_a_migration_recorded_but_no_longer_present_is_refused():
    """A deleted migration means this database cannot be rebuilt from the repo."""
    with pytest.raises(MigrationConflict, match="002_gone.sql"):
        pending_migrations([m("001_a.sql")], applied={
            "001_a.sql": checksum("create table x();"),
            "002_gone.sql": "whatever",
        })


def test_checksums_ignore_trailing_whitespace_but_not_content():
    assert checksum("select 1;\n") == checksum("select 1;")
    assert checksum("select 1;") != checksum("select 2;")


def test_nothing_pending_is_an_empty_list_not_an_error():
    applied = {"001_a.sql": checksum("create table x();")}

    assert pending_migrations([m("001_a.sql")], applied) == []


def test_a_baseline_marks_everything_applied_without_running_it():
    """For a database whose migrations were applied by hand before this runner
    existed — which is exactly how this one got here."""
    from app.migrate.plan import baseline_records

    records = baseline_records([m("001_a.sql"), m("002_b.sql")])

    assert [r["version"] for r in records] == ["001_a.sql", "002_b.sql"]
    assert all(r["checksum"] for r in records)


# ── What counts as a migration ───────────────────────────────────────────────

def test_only_numbered_files_are_migrations(tmp_path):
    """dev_harness.sql grants anon RLS policies for local browser testing.
    Applying it in production would be a security incident, so a migration must
    declare itself with a numbered prefix rather than merely being a .sql file
    in the folder."""
    from app.migrate.plan import load_migrations

    (tmp_path / "001_schema.sql").write_text("create table a();")
    (tmp_path / "002_more.sql").write_text("create table b();")
    (tmp_path / "dev_harness.sql").write_text("create policy anon_everything ...;")
    (tmp_path / "dev_check_in_demo.sql").write_text("insert into ...;")
    (tmp_path / "notes.txt").write_text("not sql")

    names = [m.name for m in load_migrations(tmp_path)]

    assert names == ["001_schema.sql", "002_more.sql"]


def test_numbered_files_sort_by_their_number_not_lexically(tmp_path):
    from app.migrate.plan import load_migrations

    for name in ("010_ten.sql", "002_two.sql", "001_one.sql"):
        (tmp_path / name).write_text("select 1;")

    assert [m.name for m in load_migrations(tmp_path)] == [
        "001_one.sql", "002_two.sql", "010_ten.sql"]


def test_a_directory_with_no_migrations_is_empty_not_an_error(tmp_path):
    from app.migrate.plan import load_migrations

    (tmp_path / "dev_only.sql").write_text("select 1;")

    assert load_migrations(tmp_path) == []
