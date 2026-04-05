SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: user_profile_detail view
-- Tests:
--  T01: View exists
--  T02: View has expected columns (delivered_at, company_contact_email, helmet, insurance)
--  T03: Employee can SELECT own row from the view
--  T04: Employee cannot see another employee's row
--  T05: HR can SELECT employee rows
--  T06: View returns bike_order data (helmet, insurance)
--  T07: View returns delivered_at
--  T08: View returns company_contact_email
-- ============================================================

BEGIN;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_co     uuid;
  v_emp_a  uuid := gen_random_uuid();
  v_emp_b  uuid := gen_random_uuid();
  v_hr     uuid := gen_random_uuid();
  v_dealer uuid;
  v_bike   uuid;
  v_bb     uuid;
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, contact_email)
  VALUES ('BigTech1', 100.00, 12, 'EUR', 'hr@bigtech.com') RETURNING id INTO v_co;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  VALUES
    (v_emp_a, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'emp-a@test.local', '', now(), now(), '', '', '', ''),
    (v_emp_b, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'emp-b@test.local', '', now(), now(), '', '', '', ''),
    (v_hr,    '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'hr-view@test.local', '', now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES
    (v_emp_a, 'emp-a@test.local', v_co, 'active', 'Alice', 'A'),
    (v_emp_b, 'emp-b@test.local', v_co, 'active', 'Bob',   'B'),
    (v_hr,    'hr-view@test.local', v_co, 'active', 'HR',   'Admin');

  INSERT INTO public.user_roles (user_id, role) VALUES
    (v_emp_a, 'employee'::public.user_role),
    (v_emp_b, 'employee'::public.user_role),
    (v_hr,    'hr'::public.user_role);

  INSERT INTO public.profile_invites (email, company_id, status, first_name, last_name)
  VALUES
    ('emp-a@test.local', v_co, 'active', 'Alice', 'A'),
    ('emp-b@test.local', v_co, 'active', 'Bob',   'B');

  INSERT INTO public.dealers (name) VALUES ('Test Dealer 00008')
  RETURNING id INTO v_dealer;

  INSERT INTO public.bikes (name, brand, full_price, dealer_id)
  VALUES ('TestBike', 'TestBrand', 2000.00, v_dealer) RETURNING id INTO v_bike;

  INSERT INTO public.bike_benefits (user_id, bike_id, benefit_status, delivered_at)
  VALUES (v_emp_a, v_bike, 'active', now())
  RETURNING id INTO v_bb;

  INSERT INTO public.bike_orders (user_id, bike_benefit_id, helmet, insurance)
  VALUES (v_emp_a, v_bb, true, true);

  PERFORM set_config('test.emp_a_id', v_emp_a::text, false);
  PERFORM set_config('test.emp_b_id', v_emp_b::text, false);
  PERFORM set_config('test.hr_id',    v_hr::text,    false);
  PERFORM set_config('test.co_id',    v_co::text,    false);
END;
$$;

SELECT plan(8);

-- ── T01: View exists ─────────────────────────────────────────────────────────
SELECT has_view('public', 'user_profile_detail', 'T01: user_profile_detail view exists');

-- ── T02: View has new columns ────────────────────────────────────────────────
SELECT columns_are(
  'public', 'user_profile_detail',
  ARRAY[
    'invite_id', 'email', 'invite_status', 'company_id',
    'company_name', 'logo_image_path', 'company_contact_email',
    'user_id', 'profile_image_path',
    'first_name', 'last_name', 'description', 'department', 'hire_date',
    'bike_benefit_id', 'benefit_status', 'contract_status', 'bike_id',
    'employee_monthly_price', 'employee_full_price',
    'employee_contract_months', 'employee_currency',
    'contract_approved_at', 'delivered_at',
    'bike_name', 'bike_brand', 'bike_images',
    'weight_kg', 'charge_time_hours', 'range_max_km', 'power_wh',
    'sign_page_url',
    'helmet', 'insurance'
  ],
  'T02: view has all expected columns'
);

-- ── T03: Employee can SELECT own row ─────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp_a_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

SELECT ok(
  EXISTS(SELECT 1 FROM public.user_profile_detail WHERE user_id = current_setting('test.emp_a_id')::uuid),
  'T03: employee can SELECT own row from user_profile_detail'
);

-- ── T04: Employee cannot see another employee's row ──────────────────────────
SELECT ok(
  NOT EXISTS(SELECT 1 FROM public.user_profile_detail WHERE user_id = current_setting('test.emp_b_id')::uuid),
  'T04: employee cannot see another employee''s row'
);

RESET ROLE;

-- ── T05: HR can SELECT employee rows ─────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_id'), 'role', 'authenticated', 'user_role', 'hr')::text,
  true);

SELECT ok(
  EXISTS(SELECT 1 FROM public.user_profile_detail WHERE user_id = current_setting('test.emp_a_id')::uuid),
  'T05: HR can SELECT employee row from user_profile_detail'
);

RESET ROLE;

-- ── T06: View returns helmet and insurance ───────────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM public.user_profile_detail
    WHERE user_id = current_setting('test.emp_a_id')::uuid
      AND helmet = true AND insurance = true
  ),
  'T06: view returns bike_order data (helmet=true, insurance=true)'
);

-- ── T07: View returns delivered_at ───────────────────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM public.user_profile_detail
    WHERE user_id = current_setting('test.emp_a_id')::uuid
      AND delivered_at IS NOT NULL
  ),
  'T07: view returns delivered_at'
);

-- ── T08: View returns company_contact_email ──────────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM public.user_profile_detail
    WHERE user_id = current_setting('test.emp_a_id')::uuid
      AND company_contact_email = 'hr@bigtech.com'
  ),
  'T08: view returns company_contact_email'
);

SELECT * FROM finish();
ROLLBACK;
