"""Reading uploaded lab documents out of object storage.

One `fetch_document(provider, path)` behind which the store can change. Imaging
moves to R2 eventually, which R2 earns by being cheap at scale; it does not have
RLS, so moving today would push authorization into hand-rolled presigned URLs in
the gateway — a new place to serve one user another's lab report, for no benefit
at current volume.

**This module enforces tenant isolation, and nothing underneath it does.** The
storage policies in 007 key on the first path segment, so a phone holding a
user's token cannot read another user's folder. The extraction worker is not a
phone: it holds service-role credentials and bypasses RLS by design. Once a path
string reaches `download()` under that key, every object in the bucket is
reachable, so every entry point here takes the user the document is supposed to
belong to and refuses a path that is not theirs.

The check is on the path's first *segment*, after normalisation. A prefix string
compare is not enough — `{user}-evil/x.pdf` starts with `{user}` and is a
different folder — and neither is an unnormalised one, because `{user}/../{other}`
satisfies both a prefix compare and `storage.foldername()`.
"""

import posixpath
from datetime import datetime, timezone

LAB_REPORTS_BUCKET = "lab-reports"

# Long enough to open a report, short enough that a forwarded link is useless.
SIGNED_URL_TTL_SECONDS = 300

SUPABASE = "supabase"

_EXTENSIONS = {"pdf": "pdf", "image": "jpg"}


class UnknownProvider(ValueError):
    """A storage provider this build cannot read.

    Raised rather than defaulted: falling back to Supabase for an unrecognised
    provider would read the wrong store and report the document as missing,
    which is indistinguishable from a failed upload.
    """


class PathNotOwned(PermissionError):
    """The path is not inside this user's folder.

    Not a 404 and not a generic error — this is the cross-tenant case, and it
    should be loud enough to page someone.
    """


class DocumentNotFound(LookupError):
    """No object at that path.

    Routine rather than exceptional: an upload row whose object never arrived is
    what a crash mid-upload looks like, and the sweep needs to tell that apart
    from a broken bucket.
    """


def storage_prefix(user_id: str, report_id: str, year: int | None = None) -> str:
    """`{user_id}/{yyyy}/{report_id}/` — the folder one report's files live in.

    The first segment is the authorization boundary, not a naming convention:
    it is what the policies on `storage.objects` key on.
    """
    year = year or datetime.now(timezone.utc).year
    return f"{user_id}/{year}/{report_id}/"


def object_path(prefix: str, page_index: int, kind: str) -> str:
    """One file within a report, numbered by the page it is.

    The number is what `biomarker_results.page` refers to, which is what makes
    "from page 2" and the stored bbox mean something.
    """
    extension = _EXTENSIONS.get(kind)
    if extension is None:
        raise ValueError(f"unsupported document kind {kind!r}")
    return f"{prefix}{page_index}.{extension}"


def _owned_path(user_id: str, path: str) -> str:
    """The path, proven to be inside this user's folder, or `PathNotOwned`.

    Normalises first so that `a/../b` is judged as `b` — otherwise a path that
    reads as the user's folder and resolves to someone else's would pass.
    """
    if not path or path.startswith("/"):
        raise PathNotOwned(f"not a relative path inside a user folder: {path!r}")

    normalised = posixpath.normpath(path)
    if normalised != path.rstrip("/"):
        raise PathNotOwned(f"path is not in normal form: {path!r}")

    segments = normalised.split("/")
    if len(segments) < 2 or segments[0] != user_id:
        raise PathNotOwned("document path is outside the requesting user's folder")
    return normalised


def _bucket(supabase, provider: str, bucket: str):
    if provider != SUPABASE:
        raise UnknownProvider(f"no storage adapter for provider {provider!r}")
    return supabase.storage.from_(bucket)


def fetch_document(
    supabase,
    *,
    user_id: str,
    provider: str,
    path: str,
    bucket: str = LAB_REPORTS_BUCKET,
) -> bytes:
    """The document's bytes.

    `user_id` is not a filter here, it is the authorization check — which is why
    it is keyword-only and has no default.
    """
    safe = _owned_path(user_id, path)
    try:
        return _bucket(supabase, provider, bucket).download(safe)
    except UnknownProvider:
        raise
    except Exception as error:
        raise DocumentNotFound(f"no object at {safe}") from error


def signed_url(
    supabase,
    *,
    user_id: str,
    provider: str,
    path: str,
    ttl_seconds: int = SIGNED_URL_TTL_SECONDS,
    bucket: str = LAB_REPORTS_BUCKET,
) -> str:
    """A short-lived URL for showing a page to the person it belongs to.

    Checked the same way as a read, and deliberately not more loosely: a URL
    outlives the request and can be forwarded, so it leaks further than a read.
    """
    safe = _owned_path(user_id, path)
    try:
        response = _bucket(supabase, provider, bucket).create_signed_url(safe, ttl_seconds)
    except UnknownProvider:
        raise
    except Exception as error:
        raise DocumentNotFound(f"no object at {safe}") from error

    url = (response or {}).get("signedURL") or (response or {}).get("signedUrl")
    if not url:
        raise DocumentNotFound(f"storage returned no signed URL for {safe}")
    return url
