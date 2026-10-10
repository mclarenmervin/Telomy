-- A user with a signed recommendation could not delete their account.
--
-- 013 made `clinical_reviews` append-only with a BEFORE UPDATE OR DELETE
-- trigger that refuses unconditionally, and gave the table an ON DELETE CASCADE
-- from `clinical_drafts`. Those two are in direct contradiction: the cascade
-- issues a DELETE against the child table, the trigger refuses it, and the
-- whole statement fails. So deleting the account of anybody with one signed
-- draft raised
--
--   clinical_reviews is append-only; a recorded review cannot be delete
--
-- which means `delete_own_account` failed, which is a right-to-erasure failure
-- under the DPDP Act rather than an inconvenience.
--
-- It also broke `db/dev_clinical_demo.sql`, which documents its own cleanup as
-- `delete from clinical_drafts where dedupe_key like 'demo:%'` -- that is how
-- this was found, on the second run of the seed.
--
-- The test that was supposed to cover it asserted `confdeltype = 'c'` on the
-- foreign key. That was true the entire time the behaviour was broken, which is
-- the same shape of mistake as F3's missing insert policy: a test that checks
-- what the schema says rather than what the database does. It is now a test
-- that deletes an account.
--
-- F6 is when this would have started happening to real people. A supplement
-- insight cannot exist without a signature, where F5's signed drafts existed
-- only in a demo.
--
-- ── The fix ─────────────────────────────────────────────────────────────────
--
-- A review may be deleted only as part of its draft being deleted, which is
-- exactly what the cascade is. Postgres applies a cascading delete after the
-- parent row has gone, so "the draft no longer exists" distinguishes the
-- cascade from somebody deleting a signature directly -- and a direct
-- `delete from clinical_reviews` still raises, because the draft is still
-- there.
--
-- What this keeps: a recorded review cannot be edited, and cannot be erased
-- while the thing it reviewed still exists. A signature is still not something
-- the signer can take back.
--
-- What it allows: erasing the person erases the trail about them. That is what
-- the cascade was always declared to do, and the only reading under which the
-- RESTRICT on `clinical_reviews.clinician_id` means anything -- a *clinician*
-- deleting their account must still fail while their signatures stand, and it
-- does, because that constraint is untouched.

create or replace function refuse_review_mutation()
returns trigger
language plpgsql
as $$
begin
  -- The cascade from clinical_drafts. The parent is already gone by the time
  -- the child delete runs, so this is not a statement anybody could have
  -- issued against a review that is still attached to a draft.
  if tg_op = 'DELETE'
     and not exists (select 1 from clinical_drafts where id = old.draft_id) then
    return old;
  end if;

  raise exception
    'clinical_reviews is append-only; a recorded review cannot be % ',
    lower(tg_op)
    using errcode = '23514';
end $$;

comment on function refuse_review_mutation() is
  'Append-only, with one exception: a review goes when its draft goes, which '
  'is how erasing an account erases the trail about them. Deleting a review '
  'whose draft still exists is refused.';
