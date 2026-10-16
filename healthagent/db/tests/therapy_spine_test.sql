-- F12 schema contract: constrained clinical history and tenant-safe reads.
-- Run after migrations through 029. The fixture rolls back.

\set owner_a   '\'f1200000-0000-4000-8000-000000000001\''
\set patient_a '\'f1200000-0000-4000-8000-000000000002\''
\set patient_b '\'f1200000-0000-4000-8000-000000000003\''
\set admin     '\'f1200000-0000-4000-8000-000000000004\''

\set owner_a_jwt   '{"sub":"f1200000-0000-4000-8000-000000000001","role":"authenticated"}'
\set patient_a_jwt '{"sub":"f1200000-0000-4000-8000-000000000002","role":"authenticated"}'
\set admin_jwt     '{"sub":"f1200000-0000-4000-8000-000000000004","role":"authenticated"}'

begin;

create or replace function pg_temp.asserts(ok boolean, label text)
returns void language plpgsql as $$
begin
  if ok then raise notice 'PASS: %', label;
  else raise exception 'FAIL: %', label; end if;
end $$;

create or replace function pg_temp.refuses(statement text, label text)
returns void language plpgsql as $$
begin
  begin execute statement;
  exception when others then raise notice 'PASS: %', label; return; end;
  raise exception 'FAIL: % (the statement was accepted)', label;
end $$;

insert into auth.users (id, instance_id, aud, role, email,
                        encrypted_password, created_at, updated_at)
values
  (:owner_a, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'f12-owner-a@example.com', '', now(), now()),
  (:patient_a, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'f12-patient-a@example.com', '', now(), now()),
  (:patient_b, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'f12-patient-b@example.com', '', now(), now()),
  (:admin, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'f12-admin@example.com', '', now(), now());

select set_config('telomy.granting_role', 'yes', true);
update profiles set app_role = 'centre' where id = :owner_a;
update profiles set app_role = 'admin' where id = :admin;
select set_config('telomy.granting_role', '', true);

select create_centre('F12 Centre A', :admin) as centre_a \gset
select create_centre('F12 Centre B', :admin) as centre_b \gset

insert into centre_memberships
  (centre_id, user_id, member_kind, status, invited_by, accepted_at)
values
  (:'centre_a', :owner_a, 'owner', 'active', :admin, now()),
  (:'centre_a', :patient_a, 'patient', 'active', :owner_a, now()),
  (:'centre_b', :patient_b, 'patient', 'active', :admin, now());

select pg_temp.refuses(
  format('update profiles set pregnancy_status = %L where id = %L',
         'maybe', :patient_a),
  'pregnancy status has a closed structured vocabulary'
);
update profiles set pregnancy_status = 'pregnant' where id = :patient_a;
select pg_temp.asserts(
  (select pregnancy_status = 'pregnant' from profiles where id = :patient_a),
  'pregnancy status is stored as a structured fact'
);

insert into therapy_catalogue (
  slug, version, display_name, category, summary, intended_experience,
  event_type, dose_schema, contraindication_rule_ids, content_sha256,
  publication_status, published_at, created_by
) values (
  'f12-contract-sauna', 1, 'F12 contract sauna', 'heat', 'Controlled heat exposure',
  'A warm supervised session', 'sauna',
  '{"duration":{"unit":"minutes"}}'::jsonb,
  array['pregnancy', 'alcohol_today'], repeat('a', 64),
  'published', now(), :admin
) returning id as catalogue_a \gset

insert into centre_therapy_offerings (
  centre_id, catalogue_id, indicative_price_minor, currency_code,
  default_duration_minutes, created_by, updated_by
) values (
  :'centre_a', :'catalogue_a', 149900, 'INR', 30, :owner_a, :owner_a
) returning id as offering_a \gset

insert into clinical_drafts (
  user_id, kind, title, body, model_version
) values (
  :patient_a, 'therapy', 'Sauna plan', 'Signed test plan', 'f12-test'
) returning id as draft_a \gset

insert into therapy_plans (
  patient_id, centre_id, version, proposed_by, status
) values (
  :patient_a, :'centre_a', 1, :patient_a, 'in_review'
) returning id as plan_a \gset

insert into therapy_plan_items (
  plan_id, catalogue_id, position, frequency, prescribed_dose, disposition
) values (
  :'plan_a', :'catalogue_a', 1, '{"sessions_per_week":3}'::jsonb,
  '{"duration_minutes":3}'::jsonb, 'active'
) returning id as item_a \gset

update therapy_plans
set status = 'signed', clinical_draft_id = :'draft_a',
    content_sha256 = repeat('b', 64), signed_by = :admin, signed_at = now()
where id = :'plan_a';

insert into therapy_safety_checks (
  patient_id, centre_id, catalogue_id, plan_item_id, evaluation_point,
  rule_version, fact_snapshot, eligible, reason_codes, explanations,
  evaluated_by
) values (
  :patient_a, :'centre_a', :'catalogue_a', :'item_a', 'signature',
  'therapy-safety-v1', '{"pregnancy_status":"not_pregnant"}'::jsonb,
  true, '{}', '[]'::jsonb, :admin
) returning id as check_a \gset

insert into therapy_service_sessions (
  patient_id, centre_id, offering_id, plan_item_id, status,
  prescribed_dose, delivered_dose, started_at, ended_at,
  idempotency_key, created_by
) values (
  :patient_a, :'centre_a', :'offering_a', :'item_a', 'completed',
  '{"duration_seconds":180}'::jsonb,
  '{"duration_seconds":160}'::jsonb,
  now() - interval '3 minutes', now(), 'f12-session-a', :patient_a
) returning id as session_a \gset

insert into therapy_checkins (
  session_id, patient_id, question_version, question_ordinal,
  question_code, answer
) values
  (:'session_a', :patient_a, 'v1', 1, 'perceived_effect', '"better"'::jsonb),
  (:'session_a', :patient_a, 'v1', 2, 'tolerability', '4'::jsonb);

select pg_temp.asserts(
  (select prescribed_dose <> delivered_dose
   from therapy_service_sessions where id = :'session_a'),
  'prescribed and delivered dose remain distinct'
);
select pg_temp.refuses(
  format(
    'insert into therapy_checkins '
    '(session_id,patient_id,question_version,question_ordinal,question_code,answer) '
    'values (%L,%L,%L,3,%L,%L::jsonb)',
    :'session_a', :patient_a, 'v1', 'extra', 'true'
  ),
  'a session cannot grow into a long form beyond two questions'
);
select pg_temp.refuses(
  format('update therapy_safety_checks set eligible = false where id = %L',
         :'check_a'),
  'safety history is immutable'
);
select pg_temp.refuses(
  format('update therapy_plans set status = %L where id = %L',
         'withdrawn', :'plan_a'),
  'a signed plan is immutable'
);
select pg_temp.refuses(
  format('update therapy_service_sessions set delivered_dose = %L::jsonb where id = %L',
         '{"duration_seconds":180}', :'session_a'),
  'a completed session is immutable'
);

insert into therapy_plans (
  patient_id, centre_id, version, proposed_by, status
) values (
  :patient_b, :'centre_b', 1, :patient_b, 'proposed'
) returning id as plan_b \gset

set local role authenticated;
select set_config('request.jwt.claims', :'patient_a_jwt', true);
select pg_temp.asserts(
  (select count(*) = 1 from therapy_plans),
  'a Patient reads their own plan and no other centre plan'
);
select pg_temp.refuses(
  format(
    'insert into therapy_plans '
    '(patient_id,centre_id,version,proposed_by,status) '
    'values (%L,%L,2,%L,%L)',
    :patient_a, :'centre_a', :patient_a, 'proposed'
  ),
  'authenticated clients cannot bypass the plan application service'
);

select set_config('request.jwt.claims', :'owner_a_jwt', true);
select pg_temp.asserts(
  (select count(*) = 0 from therapy_plans),
  'a Centre Owner gets no clinical plan rows without patient consent'
);

select set_config('request.jwt.claims', :'admin_jwt', true);
select pg_temp.asserts(
  (select count(*) = 0 from therapy_plans),
  'Super Admin clinical reads must use the audited gateway path'
);
select pg_temp.refuses(
  format('update therapy_plan_items set position = 2 where id = %L', :'item_a'),
  'Super Admin has no direct clinical mutation privilege'
);

reset role;
rollback;
