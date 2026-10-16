"""Render the reviewed YAML catalogue into migration-owned publication rows.

The migration is the production publisher: a deployed API must not depend on
an operator remembering to copy the file into Supabase.  Keeping the renderer
here lets a test prove the checked-in SQL still matches the reviewed source.
"""

from __future__ import annotations

import hashlib
import json
import re

from psycopg.types.json import Jsonb

from app.analytics.therapy_catalog import load_modalities


def catalogue_seed_rows() -> list[dict]:
    catalogue_version, modalities = load_modalities()
    match = re.search(r"(\d+)$", catalogue_version)
    if match is None:
        raise ValueError("therapy catalogue version must end in a number")
    version = int(match.group(1))
    rows = []
    for modality in modalities.values():
        operational = {
            "slug": modality.id,
            "version": version,
            "display_name": modality.label,
            "category": modality.category,
            "summary": modality.summary,
            "intended_experience": modality.intended_experience,
            "event_type": modality.event_types[0],
            "dose_schema": modality.dose_schema,
            "contraindication_rule_ids": list(modality.contraindication_rule_ids),
            "evidence_metadata": {
                "catalogue_version": catalogue_version,
                "declared_effect_count": len(modality.effects),
            },
        }
        canonical = json.dumps(
            operational, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        )
        rows.append({
            **operational,
            "content_sha256": hashlib.sha256(canonical.encode()).hexdigest(),
        })
    return rows


def publish_catalogue(cursor) -> int:
    """Upsert the current version while retaining retired history."""
    rows = catalogue_seed_rows()
    for row in rows:
        params = {
            **row,
            "dose_schema": Jsonb(row["dose_schema"]),
            "evidence_metadata": Jsonb(row["evidence_metadata"]),
        }
        cursor.execute(
            "update therapy_catalogue set publication_status = 'retired' "
            "where slug = %(slug)s and version <> %(version)s "
            "and publication_status = 'published'",
            params,
        )
        cursor.execute(
            """
            insert into therapy_catalogue (
              slug, version, display_name, category, summary,
              intended_experience, event_type, dose_schema,
              contraindication_rule_ids, evidence_metadata, content_sha256,
              publication_status, published_at
            ) values (
              %(slug)s, %(version)s, %(display_name)s, %(category)s, %(summary)s,
              %(intended_experience)s, %(event_type)s, %(dose_schema)s,
              %(contraindication_rule_ids)s, %(evidence_metadata)s,
              %(content_sha256)s, 'published', now()
            )
            on conflict (slug, version) do nothing
            """,
            params,
        )
    return len(rows)


if __name__ == "__main__":
    print(json.dumps(catalogue_seed_rows(), indent=2, ensure_ascii=False))
