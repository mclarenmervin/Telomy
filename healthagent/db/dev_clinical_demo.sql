-- Puts two findings in front of the test-harness account, so the clinician
-- spine can be checked on a device rather than in a SQL prompt.
--
-- The handoff's ninth bite: F3's extraction was correct in Postgres and
-- invisible in the app, and F4's marker labels read "Rdw" and "Hs crp" on
-- screen with every test green. A review workflow nobody can see working is
-- the same bug one phase later.
--
-- Two findings on purpose, because the distinction they draw is the whole
-- point of the phase:
--
--   1. SIGNED — a named clinician read the body and put their registration
--      number against it. The card must name them.
--   2. SLA-EXPIRED — no clinician reached it in time and it was delivered
--      unreviewed. The card must say so plainly, in words.
--
-- Writes drafts, walks them through the state machine, signs one for real
-- (through `clinician_may_sign` and the signature trigger) and lets delivery
-- happen the way it happens in production: the insights rows here are inserted
-- through the same gate the sweep inserts through, so a body that did not hash
-- to its signature would be refused here too.
--
-- Idempotent, and removable:
--
--   psql "$SUPABASE_DB_URL" -f db/dev_clinical_demo.sql
--   psql "$SUPABASE_DB_URL" -c "delete from clinical_drafts
--     where dedupe_key like 'demo:%'"
--
-- Deleting the drafts takes the reviews and insights with them by cascade.

\set uid '\'99f9d063-1d36-48fe-a1e1-609e4fcf269d\''
\set doctor '\'d0cd0cd0-0000-4000-8000-00000000d0c0\''
\set clinic '\'c1c1c1c1-0000-4000-8000-00000000c1c1\''
\set signed_draft '\'dddddddd-0000-4000-8000-00000000d001\''
\set expired_draft '\'dddddddd-0000-4000-8000-00000000d002\''

begin;

-- A clinician who can actually sign: active, licensed, and a member of a
-- clinic. `clinician_may_sign` checks all three at signing time.
insert into auth.users (id, email)
values (:doctor, 'demo-clinician@example.com')
on conflict (id) do nothing;

insert into clinics (id, name)
values (:clinic, 'Bonphul Demo Clinic')
on conflict (id) do nothing;

insert into clinic_members (clinic_id, user_id, role)
values (:clinic, :doctor, 'clinician'),
       (:clinic, :uid, 'patient')
on conflict (clinic_id, user_id) do update set role = excluded.role,
                                               left_at = null;

insert into clinicians
  (user_id, full_name, registration_number, registration_body,
   licence_expires_at, status)
values (:doctor, 'Dr Meera Raghavan', 'KMC-2019-44871',
        'Karnataka Medical Council', now() + interval '2 years', 'active')
on conflict (user_id) do update
  set licence_expires_at = excluded.licence_expires_at,
      status = 'active';

select format('clinician_may_sign = %s', clinician_may_sign(:doctor)) as check;

-- Clear any previous run so the script can be re-run while iterating on the UI.
delete from clinical_drafts where user_id = :uid and dedupe_key like 'demo:%';


-- ── 1. A finding a clinician signed ──────────────────────────────────────────

insert into clinical_drafts
  (id, user_id, clinic_id, kind, title, body, evidence, model_version,
   source_kind, dedupe_key, sla_due_at)
values (
  :signed_draft, :uid, :clinic, 'lab_finding',
  'HbA1c has risen across 3 results',
  'HbA1c has risen 11.1% across 3 results, from 5.4% on 12 February 2026 '
  'to 6.0% on 30 September 2026.',
  '[{"biomarker_id":"hba1c","value_canonical":5.4,"unit_canonical":"%",'
  '"collected_at":"2026-02-12","context":"standard","lab_name":"Thyrocare"},'
  '{"biomarker_id":"hba1c","value_canonical":5.7,"unit_canonical":"%",'
  '"collected_at":"2026-06-04","context":"standard","lab_name":"Thyrocare"},'
  '{"biomarker_id":"hba1c","value_canonical":6.0,"unit_canonical":"%",'
  '"collected_at":"2026-09-30","context":"standard","lab_name":"Thyrocare"}]'::jsonb,
  'marker-trend-v1', 'biomarker_trend', 'demo:trend:hba1c',
  now() + interval '72 hours'
);

update clinical_drafts set status = 'queued' where id = :signed_draft;
update clinical_drafts
   set status = 'in_review', claimed_by = :doctor, claimed_at = now()
 where id = :signed_draft;

-- The clinician revises it before signing, which is the workflow this phase
-- actually buys: the agent states the arithmetic and the clinician supplies the
-- meaning. The signature below is over the revised text, and would be refused
-- if it were over the original.
update clinical_drafts
   set body = body || ' This is still below the diabetic threshold, but the '
                      'direction is worth acting on. Worth repeating the panel '
                      'in three months alongside a fasting insulin.'
 where id = :signed_draft;

insert into clinical_reviews
  (draft_id, clinician_id, action, signed_body_sha256, notes)
select :signed_draft, :doctor, 'signed',
       encode(sha256(convert_to(body, 'UTF8')), 'hex'),
       'Agree with the trend. Added context and a follow-up suggestion.'
  from clinical_drafts where id = :signed_draft;

update clinical_drafts set status = 'signed' where id = :signed_draft;

-- Delivered through the same gate the sweep uses. The reviewer's name and
-- registration are stamped by the trigger, not supplied here.
insert into insights
  (user_id, draft_id, review_id, kind, title, body, evidence, noticed_by)
select d.user_id, d.id, r.id, d.kind, d.title, d.body, d.evidence, 'agent'
  from clinical_drafts d
  join clinical_reviews r on r.draft_id = d.id and r.action = 'signed'
 where d.id = :signed_draft;

update clinical_drafts set status = 'delivered' where id = :signed_draft;


-- ── 2. A finding nobody reviewed in time ─────────────────────────────────────
--
-- No routing flags, so the SLA path is open to it. A supplement draft could
-- never arrive this way, which is the narrowness the gate depends on.

insert into clinical_drafts
  (id, user_id, clinic_id, kind, title, body, evidence, model_version,
   source_kind, dedupe_key, sla_due_at)
values (
  :expired_draft, :uid, :clinic, 'lab_finding',
  'Ferritin has fallen across 3 results',
  'Ferritin has fallen 34.0% across 3 results, from 94 ng/mL on '
  '12 February 2026 to 62 ng/mL on 30 September 2026.',
  '[{"biomarker_id":"ferritin","value_canonical":94,"unit_canonical":"ng/mL",'
  '"collected_at":"2026-02-12","context":"standard","lab_name":"Thyrocare"},'
  '{"biomarker_id":"ferritin","value_canonical":78,"unit_canonical":"ng/mL",'
  '"collected_at":"2026-06-04","context":"standard","lab_name":"Thyrocare"},'
  '{"biomarker_id":"ferritin","value_canonical":62,"unit_canonical":"ng/mL",'
  '"collected_at":"2026-09-30","context":"standard","lab_name":"Thyrocare"}]'::jsonb,
  'marker-trend-v1', 'biomarker_trend', 'demo:trend:ferritin',
  now() - interval '1 hour'
);

update clinical_drafts set status = 'queued' where id = :expired_draft;
update clinical_drafts set status = 'expired' where id = :expired_draft;

insert into insights
  (user_id, draft_id, kind, title, body, evidence, noticed_by, delivery_route)
select user_id, id, kind, title, body, evidence, 'agent', 'sla_expired'
  from clinical_drafts where id = :expired_draft;

update clinical_drafts set status = 'delivered' where id = :expired_draft;


select delivery_route,
       reviewer_name,
       reviewer_registration,
       left(body, 48) || '...' as body
  from insights where user_id = :uid order by delivered_at desc;

commit;
