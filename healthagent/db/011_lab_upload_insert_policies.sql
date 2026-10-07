-- Letting the phone start an upload.
--
-- 005 enabled RLS on lab_uploads with a SELECT policy and no INSERT policy, and
-- 007 did the same for lab_upload_files. The app could read uploads it was
-- never able to create -- and the entire flow begins with that insert, because
-- the insert is what fires the webhook.
--
-- It failed on the first real device with 42501, and nothing had caught it
-- because every test path bypasses RLS: the SQL tests run as postgres, the
-- Python tests use fakes, and the operator script uses the service key. This is
-- the blind spot CLAUDE.md warns about from the other direction -- "RLS
-- protects the mobile app, not us" also means our tests prove nothing about it.
--
-- Tested by db/tests/lab_ingest_test.sql, which switches to the `authenticated`
-- role and carries a JWT claim rather than running as the owner.

-- The row has to agree with the storage path, which is keyed on the same uid.
-- And an upload may only start at `uploaded`: inserting one already further
-- along would let a client skip extraction and present unread values as read.
create policy "users start their own uploads"
  on lab_uploads for insert
  with check (auth.uid() = user_id and status = 'uploaded');

-- Files are attached to an upload the caller owns. Checked through the parent
-- rather than by trusting a path string, because the parent is the thing the
-- SELECT policy already governs.
create policy "users attach files to their own uploads"
  on lab_upload_files for insert
  with check (
    upload_id in (select id from lab_uploads where user_id = auth.uid())
  );

-- Deliberately no UPDATE or DELETE policy on either table. Status transitions
-- belong to the confirm endpoint under the service role, which is the only path
-- that also runs the patient-name check, captures the collection date, projects
-- with origin='server' and queues the recompute. A client that could edit these
-- rows could bypass all four.
