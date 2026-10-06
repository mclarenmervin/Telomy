"""Which migrations still need to run.

Pure, so the decision is testable without a database. Applying them is a thin
wrapper around this.

Our migrations are deliberately not idempotent — `alter publication ... add
table` and `create policy` both fail on a second run — so what makes automatic
migration safe is knowing exactly what has already been applied, not hoping
that re-running is harmless.
"""

import hashlib
from dataclasses import dataclass
from pathlib import Path


class MigrationConflict(RuntimeError):
    """The repo and the database disagree about history. Never caught."""


@dataclass(frozen=True)
class Migration:
    name: str
    sql: str


def checksum(sql: str) -> str:
    """Content fingerprint, insensitive to trailing whitespace only.

    Anything that changes what the database would do changes the checksum.
    """
    normalised = "\n".join(line.rstrip() for line in sql.strip().splitlines())
    return "sha256:" + hashlib.sha256(normalised.encode()).hexdigest()


# A migration declares itself with a numbered prefix. Being a .sql file in the
# folder is not enough: db/ also holds dev_harness.sql, which grants anon RLS
# policies for local browser testing, and applying that in production would be a
# security incident rather than a bug.
MIGRATION_PATTERN = "[0-9][0-9][0-9]_*.sql"


def load_migrations(directory: Path) -> list[Migration]:
    """Numbered .sql files, in order. Everything else in the folder is ignored."""
    return sorted(
        (
            Migration(name=path.name, sql=path.read_text())
            for path in directory.glob(MIGRATION_PATTERN)
        ),
        key=lambda migration: migration.name,
    )


def pending_migrations(
    available: list[Migration], applied: dict[str, str]
) -> list[Migration]:
    """What to run, in filename order.

    Refuses on two kinds of divergence rather than papering over them:

    An **edited** migration that has already run means this database did one
    thing and the next will do another — the environments have silently forked.

    A **deleted** migration that has already run means this database can no
    longer be rebuilt from the repo.
    """
    by_name = {migration.name: migration for migration in available}

    for name, recorded in applied.items():
        migration = by_name.get(name)
        if migration is None:
            raise MigrationConflict(
                f"{name} is recorded as applied but is not in the repo; "
                "this database can no longer be rebuilt from source"
            )
        if checksum(migration.sql) != recorded:
            raise MigrationConflict(
                f"{name} has changed since it was applied; applied migrations "
                "are history and must not be edited — add a new one instead"
            )

    return [
        migration
        for migration in sorted(available, key=lambda m: m.name)
        if migration.name not in applied
    ]


def baseline_records(available: list[Migration]) -> list[dict]:
    """Mark everything applied without running it.

    For a database whose migrations were applied by hand before this runner
    existed — which is exactly how this one got here.
    """
    return [
        {"version": migration.name, "checksum": checksum(migration.sql)}
        for migration in sorted(available, key=lambda m: m.name)
    ]
