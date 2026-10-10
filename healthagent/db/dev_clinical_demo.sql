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
\set supplement_draft '\'dddddddd-0000-4000-8000-00000000d003\''
\set stranded_draft '\'dddddddd-0000-4000-8000-00000000d004\''

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


-- ── 3. A supplement recommendation a clinician signed ────────────────────────
--
-- F6's artefact, and the first one a user can be told to *act* on. It carries a
-- routing flag, so unlike the two above it could never have arrived by the SLA
-- path -- the insert below only works because there is a signature over this
-- exact body.
--
-- The evidence carries all four shapes the card has to render: the
-- measurement, the range the value fell below, the reviewed rule that was
-- applied, and the medication that complicates it. Three of them are new in
-- F6, and a phone that could not read them would show blank rows rather than
-- fail -- which is the whole reason this seed exists.

insert into clinical_drafts
  (id, user_id, clinic_id, kind, title, body, evidence, model_version,
   source_kind, routing_flags, dedupe_key, sla_due_at)
values (
  :supplement_draft, :uid, :clinic, 'supplement',
  'Magnesium is below the standard range',
  'Magnesium was 1.4 mg/dL on 30 September 2026, below the standard range of '
  '1.7–2.2 mg/dL. Magnesium supplementation is the usual response to a level '
  'below the reference range, once the cause of the loss has been considered. '
  'Also recorded: Spironolactone 25mg. Potassium-sparing diuretics retain '
  'magnesium, so supplementing on top of one risks hypermagnesaemia, '
  'particularly with any renal impairment.',
  '[{"kind":"measurement","biomarker_id":"magnesium","value_canonical":1.4,'
  '"unit_canonical":"mg/dL","collected_at":"2026-09-30","context":"standard",'
  '"lab_name":"Thyrocare"},'
  '{"kind":"reference_range","biomarker_id":"magnesium","standard_low":1.7,'
  '"standard_high":2.2,"unit_canonical":"mg/dL","ranges_version":"global.v1",'
  '"citation":"Costello RB et al. Interpreting magnesium status. PMID 27385293"},'
  '{"kind":"rule","rule_id":"magnesium_repletion","supplement":"Oral magnesium",'
  '"trigger":"below_standard","citation":"Ayuk J, Gittoes NJ. Ann Clin Biochem 2014",'
  '"reviewer":"Dr Meera Raghavan, MBBS MD, reg. KMC-2019-44871",'
  '"reviewed_at":"2026-10-10"},'
  '{"kind":"interaction","medication":"spironolactone",'
  '"recorded_as":"Spironolactone 25mg",'
  '"note":"Potassium-sparing diuretics retain magnesium, so supplementing on '
  'top of one risks hypermagnesaemia, particularly with any renal impairment."}]'::jsonb,
  'supplement-rule-v1', 'biomarker_deficiency', array['medication'],
  'demo:supplement:magnesium', now() + interval '72 hours'
);

update clinical_drafts set status = 'queued' where id = :supplement_draft;
update clinical_drafts
   set status = 'in_review', claimed_by = :doctor, claimed_at = now()
 where id = :supplement_draft;

insert into clinical_reviews
  (draft_id, clinician_id, action, signed_body_sha256, notes)
select :supplement_draft, :doctor, 'signed',
       encode(sha256(convert_to(body, 'UTF8')), 'hex'),
       'Agree, but review the spironolactone dose before starting magnesium.'
  from clinical_drafts where id = :supplement_draft;

update clinical_drafts set status = 'signed' where id = :supplement_draft;

insert into insights
  (user_id, draft_id, review_id, kind, title, body, evidence, noticed_by)
select d.user_id, d.id, r.id, d.kind, d.title, d.body, d.evidence, 'agent'
  from clinical_drafts d
  join clinical_reviews r on r.draft_id = d.id and r.action = 'signed'
 where d.id = :supplement_draft;

update clinical_drafts set status = 'delivered' where id = :supplement_draft;


-- ── 4. A supplement recommendation nobody signed ─────────────────────────────
--
-- Deliberately left stranded: flagged, past its SLA, and expired. There is no
-- insight row and there must not be one, because no clinician read it.
--
-- This is the number the handoff says to watch. `sweep_queue` counts it as
-- `stranded`, and with F5 it could only ever be zero because nothing produced a
-- flagged draft. It can move now, and what it means is a person who was
-- promised nothing and told nothing -- the cost of having no clinician console
-- yet, made visible rather than inferred.
--
-- On the phone the correct behaviour is that this does not appear at all.

insert into clinical_drafts
  (id, user_id, clinic_id, kind, title, body, evidence, model_version,
   source_kind, routing_flags, dedupe_key, sla_due_at)
values (
  :stranded_draft, :uid, :clinic, 'supplement',
  'Vitamin D (25-OH) is below the standard range',
  'Vitamin D (25-OH) was 14 ng/mL on 30 September 2026, below the standard '
  'range of 30–100 ng/mL. Vitamin D supplementation is the usual response to a '
  'level this low, at a dose and duration a clinician sets.',
  '[{"kind":"measurement","biomarker_id":"vitamin_d_25oh","value_canonical":14,'
  '"unit_canonical":"ng/mL","collected_at":"2026-09-30","context":"standard",'
  '"lab_name":"Thyrocare"}]'::jsonb,
  'supplement-rule-v1', 'biomarker_deficiency', array['medication'],
  'demo:supplement:vitamin_d', now() - interval '1 hour'
);

update clinical_drafts set status = 'queued' where id = :stranded_draft;
update clinical_drafts set status = 'expired' where id = :stranded_draft;

select format(
  'stranded supplement drafts for this user: %s',
  (select count(*) from clinical_drafts d
    where d.user_id = :uid and d.status = 'expired'
      and coalesce(array_length(d.routing_flags, 1), 0) > 0
      and not exists (select 1 from insights i where i.draft_id = d.id))
) as check;


select kind,
       delivery_route,
       reviewer_name,
       reviewer_registration,
       left(body, 48) || '...' as body
  from insights where user_id = :uid order by delivered_at desc;

commit;
