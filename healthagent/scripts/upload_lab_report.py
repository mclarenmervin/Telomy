#!/usr/bin/env python
"""Push a lab report through the real pipeline, without the app.

    PYTHONPATH=. python scripts/upload_lab_report.py report.pdf
    PYTHONPATH=. python scripts/upload_lab_report.py --demo
    PYTHONPATH=. python scripts/upload_lab_report.py report.pdf --cleanup

This does exactly what the phone does and nothing more: writes the object to
Storage, then inserts the rows. The database trigger fires the webhook, the
gateway enqueues, and the deployed worker picks it up — so a run here exercises
the trigger, the secret, the queue, the worker and the catalog together. If any
one of them is misconfigured, this is where it shows.

It uses the service key, so it bypasses RLS. That is appropriate for an
operator script and is exactly why it must never be shipped to a device.

`--cleanup` removes the upload, its results and its object afterwards, which is
what you want when testing against a database real people use.
"""

import argparse
import hashlib
import sys
import time
import uuid
from pathlib import Path

from app.common.config import get_settings
from app.common.documents import LAB_REPORTS_BUCKET, object_path, storage_prefix
from app.common.supabase_client import get_supabase_client

TERMINAL = {"extracted", "confirmed", "failed", "needs_password"}


def upload(supabase, path: Path, user_id: str) -> str:
    data = path.read_bytes()
    kind = "pdf" if path.suffix.lower() == ".pdf" else "image"
    upload_id = str(uuid.uuid4())
    prefix = storage_prefix(user_id, upload_id)
    object_name = object_path(prefix, 0, kind)

    digest = hashlib.sha256(data).hexdigest()
    report_digest = hashlib.sha256(digest.encode()).hexdigest()

    print(f"  object  {object_name}  ({len(data):,} bytes)")
    supabase.storage.from_(LAB_REPORTS_BUCKET).upload(
        object_name, data, {"content-type": "application/pdf" if kind == "pdf" else "image/jpeg"}
    )

    # The row insert is what fires the trigger, so it goes second — exactly as
    # the app does it. The reverse would start extraction on a missing file.
    supabase.table("lab_uploads").insert({
        "id": upload_id,
        "user_id": user_id,
        "storage_provider": "supabase",
        "storage_prefix": prefix,
        "content_sha256": report_digest,
        "status": "uploaded",
    }).execute()

    supabase.table("lab_upload_files").insert({
        "upload_id": upload_id,
        "storage_path": object_name,
        "content_sha256": digest,
        "page_index": 0,
        "kind": kind,
        "byte_size": len(data),
    }).execute()

    print(f"  upload  {upload_id}  inserted, trigger fired")
    return upload_id


def wait(supabase, upload_id: str, seconds: int = 60) -> dict:
    deadline = time.time() + seconds
    last = None
    while time.time() < deadline:
        rows = supabase.table("lab_uploads").select("*").eq("id", upload_id).execute().data
        row = rows[0] if rows else {}
        status = row.get("status")
        if status != last:
            print(f"  status  {status}")
            last = status
        if status in TERMINAL:
            return row
        time.sleep(2)
    print("  status  still not terminal after "
          f"{seconds}s — the worker may not be running, or the webhook never arrived")
    return {}


def report(supabase, upload_id: str, row: dict) -> None:
    print()
    print(f"  lab          {row.get('lab_name')}")
    print(f"  patient      {row.get('patient_name')}")
    print(f"  collected    {row.get('collected_at')}  ({row.get('collected_at_source')})")
    print(f"  reported     {row.get('reported_at')}")
    print(f"  pages        {row.get('page_count')}   text layer: {row.get('text_layer')}")
    print(f"  history      {row.get('is_history')}")
    if row.get("error"):
        print(f"  error        {row['error']}")

    results = (
        supabase.table("biomarker_results").select("*")
        .eq("upload_id", upload_id).order("biomarker_id").execute().data
    )
    print(f"\n  {len(results)} result(s):")
    for r in results:
        operator = r["operator"] if r["operator"] != "=" else ""
        print(
            f"    {r['biomarker_id']:<22} {operator}{r['raw_value']:>10} {str(r['raw_unit'] or ''):<8}"
            f" -> {r['value_canonical']:>10} {r['unit_canonical'] or ''}"
            f"   [{r['context']}, p{r['page']}, conf {r['confidence']}]"
        )

    escalations = (
        supabase.table("lab_escalations").select("*").eq("upload_id", upload_id).execute().data
    )
    for e in escalations:
        print(f"\n  ESCALATION  {e['biomarker_id']}: {e['message']}")


def cleanup(supabase, upload_id: str, user_id: str) -> None:
    files = (
        supabase.table("lab_upload_files").select("storage_path")
        .eq("upload_id", upload_id).execute().data
    )
    for f in files:
        supabase.storage.from_(LAB_REPORTS_BUCKET).remove([f["storage_path"]])
    # biomarker_results, lab_upload_files and lab_escalations cascade from here.
    supabase.table("lab_uploads").delete().eq("id", upload_id).execute()
    print(f"\n  cleaned up {upload_id} and {len(files)} object(s)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", help="a lab report PDF")
    parser.add_argument("--demo", action="store_true",
                        help="use a generated synthetic report instead of a file")
    parser.add_argument("--user-id", required=True, help="an existing auth.users id")
    parser.add_argument("--cleanup", action="store_true",
                        help="delete the upload, its results and its object afterwards")
    parser.add_argument("--wait", type=int, default=60)
    args = parser.parse_args()

    get_settings()  # fails loudly now rather than inside a call
    supabase = get_supabase_client()

    if args.demo:
        from tests.lab_fixtures import lab_report_pdf
        path = Path("/tmp/telomy-demo-report.pdf")
        path.write_bytes(lab_report_pdf())
        print(f"generated a synthetic report at {path}")
    elif args.path:
        path = Path(args.path)
        if not path.exists():
            print(f"no such file: {path}", file=sys.stderr)
            return 1
    else:
        parser.error("give a path or --demo")

    print(f"\nuploading for {args.user_id}")
    upload_id = upload(supabase, path, args.user_id)
    row = wait(supabase, upload_id, args.wait)
    if row:
        report(supabase, upload_id, row)
    if args.cleanup:
        cleanup(supabase, upload_id, args.user_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
