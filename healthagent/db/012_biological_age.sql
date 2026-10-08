-- Two gaps F4 found, both the same shape as the one that bit F3 on a real
-- device: a table RLS protects, missing the policy or the constraint that makes
-- the feature possible, invisible because every other test path bypasses RLS.
--
-- Tested by db/tests/biological_age_test.sql, which switches to the
-- `authenticated` role and carries a JWT claim rather than running as owner.
--
-- No new table. A biological age is a score and belongs in score_snapshots,
-- whose check constraint has permitted 'biological_age' since 006.

-- ── A score does not outlive the account it describes ────────────────────────
--
-- 006 declared `user_id uuid not null` with no foreign key, so every snapshot
-- survived the user. 007 added the cascade for lab_uploads, biomarker_results,
-- epigenetic_results and reference_range_overrides and did not reach this
-- table, which mattered less when the only score was a readiness number and
-- matters a great deal now that one of them is a biological age.
--
-- `delete_own_account` deletes the auth.users row and relies on cascades for
-- everything else, so without this the DPDP promise is quietly untrue.
--
-- Cascade rather than restrict, for the reason 007 gives: a user deleting their
-- account must take their history with them, and failing the delete would be
-- the wrong answer.

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'score_snapshots_user_fkey'
  ) then
    -- Any snapshot already orphaned by a deletion that happened before this
    -- constraint existed would block the ALTER, and it is also precisely the
    -- data that should not be here.
    delete from score_snapshots
     where user_id not in (select id from auth.users);

    alter table score_snapshots add constraint score_snapshots_user_fkey
      foreign key (user_id) references auth.users(id) on delete cascade;
  end if;
end $$;


-- ── Deliberately no write policy on score_snapshots ──────────────────────────
--
-- Postgres holds facts, Python computes, Flutter renders. 006 gave the table a
-- SELECT policy and nothing else, which is correct and is restated here so that
-- the absence reads as a decision rather than an oversight.
--
-- A client that could insert or update a row here could put any biological age
-- on its own screen and walk straight around the clinical-review gate -- which
-- is the single thing that gate exists to prevent. The score worker and the
-- REST recompute endpoint write these rows under the service role, which also
-- means they pass through `biological_age_for_display` and cannot publish a
-- number the catalog has not earned.


-- ── The user can tell us about a clock they paid for ─────────────────────────
--
-- 005 enabled RLS on epigenetic_results with a SELECT policy and no INSERT
-- policy. The feature is "display the third-party epigenetic clocks the user
-- already has", and there was no way for the user to record one -- they could
-- read rows they could never create. Identical in shape to the lab_uploads
-- insert that failed with 42501 on the first real device, and invisible for the
-- same reason: the SQL tests run as postgres, the Python tests use fakes and
-- the scripts use the service key.
--
-- `source` is not in the policy because 005 already pins it with a check
-- constraint to 'third_party'. Nothing can write a value here and call it ours,
-- whatever role it holds, and that is the stronger guarantee of the two.

create policy "users record their own epigenetic results"
  on epigenetic_results for insert
  with check (auth.uid() = user_id);

-- A user mistyping their own GrimAge result should be able to fix it, and a
-- result they decide was entered against the wrong date should be removable.
-- Unlike lab_uploads there is no server-side workflow to protect here: the row
-- has no status, no extraction and no confirmation step -- it is a number the
-- user copied off a report from somebody else's laboratory.
create policy "users correct their own epigenetic results"
  on epigenetic_results for update using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "users remove their own epigenetic results"
  on epigenetic_results for delete using (auth.uid() = user_id);


-- ── A clock result needs a date ──────────────────────────────────────────────
--
-- Already not-null in 005. Restated as an index because the app's primary read
-- is "this user's clocks, newest first" and 005's index is on
-- (user_id, collected_at desc) -- adding `clock` lets a per-clock trend come
-- straight off the index rather than filtering the user's whole history.

create index if not exists epigenetic_results_user_clock_time_idx
  on epigenetic_results (user_id, clock, collected_at desc);
