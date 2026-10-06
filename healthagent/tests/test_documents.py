"""Reading uploaded lab documents out of object storage.

The storage policies in 007 key on the first path segment, so a phone holding a
user's token physically cannot read another user's folder. **None of that
protects this code.** The extraction worker uses service-role credentials and
bypasses RLS by design — exactly as `healthagent/CLAUDE.md` says, RLS protects
the mobile app, not us, and application code is solely responsible for tenant
isolation.

So the adapter takes the user whose document it is being asked for and checks
the path belongs to them. It is the only place that check can live: once a path
string reaches `storage.download()` under the service role, every object in the
bucket is reachable.
"""

import pytest

from app.common.documents import (
    LAB_REPORTS_BUCKET,
    DocumentNotFound,
    PathNotOwned,
    UnknownProvider,
    fetch_document,
    object_path,
    signed_url,
    storage_prefix,
)

USER = "c3c4eefd-b60c-438e-8cdc-0f3f0fde7617"
OTHER = "0d6d0ca2-1d3e-4a1f-9b77-2f0d7a4c9e11"


class FakeBucket:
    def __init__(self, objects, bucket):
        self._objects, self.bucket = objects, bucket
        self.signed_calls = []

    def download(self, path):
        if path not in self._objects:
            raise Exception(f"Object not found: {path}")
        return self._objects[path]

    def create_signed_url(self, path, expires_in):
        if path not in self._objects:
            raise Exception(f"Object not found: {path}")
        self.signed_calls.append((path, expires_in))
        return {"signedURL": f"https://x.supabase.co/{path}?exp={expires_in}",
                "signedUrl": f"https://x.supabase.co/{path}?exp={expires_in}"}


class FakeStorage:
    def __init__(self, objects):
        self._objects = objects
        self.buckets = []

    def from_(self, bucket):
        proxy = FakeBucket(self._objects, bucket)
        self.buckets.append(proxy)
        return proxy


class FakeSupabase:
    def __init__(self, objects=None):
        self.storage = FakeStorage(objects or {})


@pytest.fixture
def supabase():
    return FakeSupabase({
        f"{USER}/2026/report-a/0.pdf": b"%PDF-1.7 the user's own report",
        f"{OTHER}/2026/report-b/0.pdf": b"%PDF-1.7 somebody else's report",
    })


# ── Paths ────────────────────────────────────────────────────────────────────

def test_the_prefix_puts_the_owner_first():
    """The first segment is what the storage policies key on, so it is not a
    naming convention — it is the authorization boundary."""
    prefix = storage_prefix(USER, "report-a", year=2026)

    assert prefix == f"{USER}/2026/report-a/"


def test_object_paths_are_numbered_by_page():
    prefix = storage_prefix(USER, "report-a", year=2026)

    assert object_path(prefix, 0, "pdf") == f"{USER}/2026/report-a/0.pdf"
    assert object_path(prefix, 2, "image") == f"{USER}/2026/report-a/2.jpg"


# ── Reading ──────────────────────────────────────────────────────────────────

def test_a_user_can_read_their_own_document(supabase):
    content = fetch_document(
        supabase, user_id=USER, provider="supabase",
        path=f"{USER}/2026/report-a/0.pdf",
    )

    assert content == b"%PDF-1.7 the user's own report"


def test_it_reads_from_the_private_lab_reports_bucket(supabase):
    fetch_document(supabase, user_id=USER, provider="supabase",
                   path=f"{USER}/2026/report-a/0.pdf")

    assert supabase.storage.buckets[0].bucket == LAB_REPORTS_BUCKET


def test_reading_another_users_document_is_refused(supabase):
    """The bug this exists to prevent. Under service-role credentials the object
    is perfectly readable; nothing but this check stops us serving it."""
    with pytest.raises(PathNotOwned):
        fetch_document(supabase, user_id=USER, provider="supabase",
                       path=f"{OTHER}/2026/report-b/0.pdf")


def test_traversing_out_of_the_users_folder_is_refused(supabase):
    """`storage.foldername()` would read the first segment as the user's id and
    be satisfied. A string compare on the prefix alone would be too."""
    with pytest.raises(PathNotOwned):
        fetch_document(supabase, user_id=USER, provider="supabase",
                       path=f"{USER}/../{OTHER}/2026/report-b/0.pdf")


def test_an_absolute_path_is_refused(supabase):
    with pytest.raises(PathNotOwned):
        fetch_document(supabase, user_id=USER, provider="supabase",
                       path=f"/{USER}/2026/report-a/0.pdf")


def test_a_path_that_merely_starts_with_the_user_id_is_refused(supabase):
    """`{user}-evil/...` shares a prefix with `{user}/...` but is a different
    folder. The check is on the segment, not on the string."""
    with pytest.raises(PathNotOwned):
        fetch_document(supabase, user_id=USER, provider="supabase",
                       path=f"{USER}-evil/2026/report-b/0.pdf")


def test_a_missing_object_is_a_named_failure(supabase):
    """An upload row whose object never arrived is routine — the app crashed
    mid-upload. The sweep needs to tell that apart from a broken bucket."""
    with pytest.raises(DocumentNotFound):
        fetch_document(supabase, user_id=USER, provider="supabase",
                       path=f"{USER}/2026/report-a/9.pdf")


# ── Providers ────────────────────────────────────────────────────────────────

def test_an_unknown_provider_raises_rather_than_guessing(supabase):
    """Imaging moves to R2 later and is a second adapter. Falling back to
    Supabase for an unrecognised provider would read the wrong store and report
    the file as missing."""
    with pytest.raises(UnknownProvider):
        fetch_document(supabase, user_id=USER, provider="r2",
                       path=f"{USER}/2026/report-a/0.pdf")


# ── Signed URLs ──────────────────────────────────────────────────────────────

def test_a_signed_url_is_short_lived(supabase):
    url = signed_url(supabase, user_id=USER, provider="supabase",
                     path=f"{USER}/2026/report-a/0.pdf")

    path, ttl = supabase.storage.buckets[0].signed_calls[0]
    assert ttl <= 300, "a lab report URL must not outlive the screen showing it"
    assert url.startswith("https://")


def test_a_signed_url_for_someone_elses_document_is_refused(supabase):
    """Worth its own test: a signed URL leaks further than a read does, because
    it survives the request and can be forwarded."""
    with pytest.raises(PathNotOwned):
        signed_url(supabase, user_id=USER, provider="supabase",
                   path=f"{OTHER}/2026/report-b/0.pdf")
