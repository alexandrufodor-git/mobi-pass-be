SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: RLS — cross-company isolation for HR/admin policies
--
-- Covers the tables fixed by migration 20260610000004, none of which were
-- exercised by 00005 (that file only tested user_roles + profiles SELECT,
-- both of which were already scoped). Each table previously gated only on the
-- JWT user_role claim, leaking every company's rows to any HR user.
--
--  profile_invites  T01 see own / T02 not other / T03 update other blocked
--                   T04 delete other blocked / T05 insert into other blocked
--  bike_benefits    T06 see own / T07 not other / T08 update other blocked
--  bike_orders      T09 see own / T10 not other
--  contracts        T11 see own / T12 not other
--  user_roles       T13 HR cannot assign a role to an out-of-company user
-- ============================================================

BEGIN;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_co_a   uuid;
  v_co_b   uuid;
  v_dom_a  text := 'rlsiso-a-' || gen_random_uuid()::text || '.test';
  v_dom_b  text := 'rlsiso-b-' || gen_random_uuid()::text || '.test';
  v_hr     uuid := gen_random_uuid();  -- HR in company A
  v_emp    uuid := gen_random_uuid();  -- employee in company A
  v_out    uuid := gen_random_uuid();  -- employee in company B
  v_bb_emp uuid;
  v_bb_out uuid;
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('rlsiso-co-a-' || gen_random_uuid()::text, 100.00, 12, 'EUR', v_dom_a) RETURNING id INTO v_co_a;
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('rlsiso-co-b-' || gen_random_uuid()::text, 100.00, 12, 'EUR', v_dom_b) RETURNING id INTO v_co_b;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  VALUES
    (v_hr,  '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'hr@'  || v_dom_a, '', now(), now(), '', '', '', ''),
    (v_emp, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'emp@' || v_dom_a, '', now(), now(), '', '', '', ''),
    (v_out, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'out@' || v_dom_b, '', now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES
    (v_hr,  'hr@'  || v_dom_a, v_co_a, 'active', 'HR',       'A'),
    (v_emp, 'emp@' || v_dom_a, v_co_a, 'active', 'Employee', 'A'),
    (v_out, 'out@' || v_dom_b, v_co_b, 'active', 'Outside',  'B');

  INSERT INTO public.user_roles (user_id, role) VALUES
    (v_hr,  'hr'::public.user_role),
    (v_emp, 'employee'::public.user_role),
    (v_out, 'employee'::public.user_role);

  -- profile_invites: one per company
  INSERT INTO public.profile_invites (id, email, company_id, first_name, last_name) VALUES
    ('11111111-aaaa-0000-0000-000000000001', 'inv@' || v_dom_a, v_co_a, 'Inv', 'A'),
    ('22222222-bbbb-0000-0000-000000000002', 'inv@' || v_dom_b, v_co_b, 'Inv', 'B');

  -- bike_benefits + bike_orders + contracts for the two employees
  INSERT INTO public.bike_benefits (user_id) VALUES (v_emp) RETURNING id INTO v_bb_emp;
  INSERT INTO public.bike_benefits (user_id) VALUES (v_out) RETURNING id INTO v_bb_out;

  INSERT INTO public.bike_orders (user_id, bike_benefit_id) VALUES
    (v_emp, v_bb_emp),
    (v_out, v_bb_out);

  INSERT INTO public.contracts (user_id, bike_benefit_id, esignatures_contract_id, esignatures_template_id) VALUES
    (v_emp, v_bb_emp, 'es-' || v_emp::text, 'tmpl-a'),
    (v_out, v_bb_out, 'es-' || v_out::text, 'tmpl-b');

  PERFORM set_config('test.hr_id',  v_hr::text,  false);
  PERFORM set_config('test.emp_id', v_emp::text, false);
  PERFORM set_config('test.out_id', v_out::text, false);
  PERFORM set_config('test.co_a_id', v_co_a::text, false);
  PERFORM set_config('test.co_b_id', v_co_b::text, false);
END;
$$;

SELECT plan(13);

-- Become HR of company A for the read/write checks.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_id'), 'role', 'authenticated', 'user_role', 'hr')::text,
  true);

-- ── profile_invites ──────────────────────────────────────────────────────────
SELECT ok(
  EXISTS(SELECT 1 FROM public.profile_invites WHERE company_id = current_setting('test.co_a_id')::uuid),
  'T01: HR sees own-company profile_invites'
);
SELECT ok(
  NOT EXISTS(SELECT 1 FROM public.profile_invites WHERE company_id = current_setting('test.co_b_id')::uuid),
  'T02: HR cannot see other-company profile_invites'
);

-- UPDATE on an other-company invite must affect 0 rows (RLS USING filters it out).
WITH upd AS (
  UPDATE public.profile_invites SET last_name = 'HACK'
  WHERE id = '22222222-bbbb-0000-0000-000000000002' RETURNING 1
)
SELECT is( (SELECT count(*)::int FROM upd), 0, 'T03: HR cannot UPDATE other-company invite');

-- DELETE likewise affects 0 rows.
WITH del AS (
  DELETE FROM public.profile_invites
  WHERE id = '22222222-bbbb-0000-0000-000000000002' RETURNING 1
)
SELECT is( (SELECT count(*)::int FROM del), 0, 'T04: HR cannot DELETE other-company invite');

-- INSERT into another company must be rejected by the WITH CHECK predicate.
SELECT throws_ok(
  $$ INSERT INTO public.profile_invites (email, company_id, first_name, last_name)
     VALUES ('sneak@x.test', current_setting('test.co_b_id')::uuid, 'Sneak', 'Y') $$,
  '42501',
  NULL,
  'T05: HR cannot INSERT invite into another company'
);

-- ── bike_benefits ──────────────────────────────────────────────────────────────
SELECT ok(
  EXISTS(SELECT 1 FROM public.bike_benefits WHERE user_id = current_setting('test.emp_id')::uuid),
  'T06: HR sees own-company bike_benefits'
);
SELECT ok(
  NOT EXISTS(SELECT 1 FROM public.bike_benefits WHERE user_id = current_setting('test.out_id')::uuid),
  'T07: HR cannot see other-company bike_benefits'
);
WITH upd AS (
  UPDATE public.bike_benefits SET live_test_location = 'HACK'
  WHERE user_id = current_setting('test.out_id')::uuid RETURNING 1
)
SELECT is( (SELECT count(*)::int FROM upd), 0, 'T08: HR cannot UPDATE other-company bike_benefits');

-- ── bike_orders ──────────────────────────────────────────────────────────────
SELECT ok(
  EXISTS(SELECT 1 FROM public.bike_orders WHERE user_id = current_setting('test.emp_id')::uuid),
  'T09: HR sees own-company bike_orders'
);
SELECT ok(
  NOT EXISTS(SELECT 1 FROM public.bike_orders WHERE user_id = current_setting('test.out_id')::uuid),
  'T10: HR cannot see other-company bike_orders'
);

-- ── contracts ──────────────────────────────────────────────────────────────────
SELECT ok(
  EXISTS(SELECT 1 FROM public.contracts WHERE user_id = current_setting('test.emp_id')::uuid),
  'T11: HR sees own-company contracts'
);
SELECT ok(
  NOT EXISTS(SELECT 1 FROM public.contracts WHERE user_id = current_setting('test.out_id')::uuid),
  'T12: HR cannot see other-company contracts'
);

-- ── user_roles INSERT ──────────────────────────────────────────────────────────
-- HR must not be able to grant a role to a user in another company.
SELECT throws_ok(
  $$ INSERT INTO public.user_roles (user_id, role)
     VALUES (current_setting('test.out_id')::uuid, 'hr'::public.user_role) $$,
  '42501',
  NULL,
  'T13: HR cannot assign a role to an out-of-company user'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
