"""Applies pending database migrations. Run before a new version takes traffic.

    python -m app.migrate.main              # apply what is pending
    python -m app.migrate.main --baseline   # record as applied, run nothing
    python -m app.migrate.main --dry-run    # say what would run

Three properties make this safe to run automatically on every deploy:

**An advisory lock**, so several services deploying at once cannot apply the
same migration twice. The losers wait, then find nothing pending.

**One transaction per migration.** A failure rolls that migration back and
stops; the deploy fails loudly rather than leaving the schema half-changed.

**A checksum per applied file**, so editing history is refused rather than
silently diverging this database from the next one.

The lock key is arbitrary but must be stable — any process using the same key
for something else would deadlock against deploys.
"""

import sys
from pathlib import Path

import psycopg

from app.common.config import get_settings
from app.common.logging_config import configure_logging, get_logger
from app.migrate.plan import (
    baseline_records,
    checksum,
    load_migrations,
    pending_migrations,
)

logger = get_logger(__name__)

MIGRATIONS_DIR = Path(__file__).resolve().parents[2] / "db"
ADVISORY_LOCK_KEY = 8_241_957_310_442_001

CREATE_TABLE = """
create table if not exists schema_migrations (
  version text primary key,
  checksum text not null,
  applied_at timestamptz not null default now()
)
"""


def _applied(cursor) -> dict[str, str]:
    cursor.execute("select version, checksum from schema_migrations")
    return {row[0]: row[1] for row in cursor.fetchall()}


def _record(cursor, version: str, digest: str) -> None:
    cursor.execute(
        "insert into schema_migrations (version, checksum) values (%s, %s) "
        "on conflict (version) do update set checksum = excluded.checksum",
        (version, digest),
    )


def run(dsn: str, directory: Path, baseline: bool = False, dry_run: bool = False) -> int:
    """Returns the number applied. Raises on conflict or a failed migration."""
    migrations = load_migrations(directory)
    if not migrations:
        logger.warning(f"no migrations found in {directory}")
        return 0

    with psycopg.connect(dsn, autocommit=True) as connection:
        with connection.cursor() as cursor:
            cursor.execute(CREATE_TABLE)
            # Blocks until any concurrent deploy has finished, rather than
            # racing it. The waiter then finds nothing pending.
            cursor.execute("select pg_advisory_lock(%s)", (ADVISORY_LOCK_KEY,))
            try:
                if baseline:
                    for record in baseline_records(migrations):
                        _record(cursor, record["version"], record["checksum"])
                    logger.info(
                        f"baselined {len(migrations)} migration(s) as already applied"
                    )
                    return 0

                pending = pending_migrations(migrations, _applied(cursor))
                if not pending:
                    logger.info("schema is up to date")
                    return 0

                if dry_run:
                    for migration in pending:
                        logger.info(f"would apply {migration.name}")
                    return len(pending)

                for migration in pending:
                    logger.info(f"applying {migration.name}")
                    # One transaction per migration: a failure rolls that file
                    # back and stops, rather than leaving the schema partly
                    # changed with no record of how far it got.
                    with connection.transaction():
                        cursor.execute(migration.sql)
                        _record(cursor, migration.name, checksum(migration.sql))
                    logger.info(f"applied {migration.name}")

                logger.info(f"applied {len(pending)} migration(s)")
                return len(pending)
            finally:
                cursor.execute("select pg_advisory_unlock(%s)", (ADVISORY_LOCK_KEY,))


def main(argv: list[str] | None = None) -> int:
    configure_logging()
    args = argv if argv is not None else sys.argv[1:]
    settings = get_settings()
    dsn = settings.supabase_db_url
    if not dsn:
        # Failing the deploy is correct: starting a new version against an old
        # schema is how you get errors nobody can explain.
        logger.error("SUPABASE_DB_URL is not set; cannot migrate")
        return 1
    try:
        run(
            dsn,
            MIGRATIONS_DIR,
            baseline="--baseline" in args,
            dry_run="--dry-run" in args,
        )
    except Exception:
        logger.exception("migration failed; the deploy should not proceed")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
