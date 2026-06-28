SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: get_company_metrics RPC — windowed counts, CO₂ range, guards, scoping
--
-- Migration 20260627000005. The parameterized any-range reader for the HR
-- Reports "at a glance" cards: returns active_accounts / active_benefits / co2_kg
-- for the caller's own company over [p_from, p_to], computed on read.
--
-- Fixtures (company A, days_in_office = 5):
--   inv1 active, created_at = now()-60d  → last_activity 60d ago
--   inv2 active, created_at = now()-3d   → last_activity  3d ago
--   inv3 inactive                        → never counts
--   e1: profile + employee_pii(5.0) + active+delivered benefit, updated_at=now()-3d
--   company B: 3 active invites (must NOT leak into A's numbers)
--
--  R01 all-time accounts=2  R02 all-time benefits=1  R03 all-time co2=8.25
--  R04 last-month(now-28d) accounts=1  R05 last-week(now-7d) accounts=1
--  R06 last-day(now-1d) benefits=0  R07 past-window co2=0
--  R08 company scoping (B's invites excluded)  R09 employee role → throws
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_co_a  uuid;
  v_co_b  uuid;
  v_dom_a text := 'rpc-a-' || gen_random_uuid()::text || '.test';
  v_dom_b text := 'rpc-b-' || gen_random_uuid()::text || '.test';
  v_hr    uuid := gen_random_uuid();
  v_e1    uuid := gen_random_uuid();
  v_emp   uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain, days_in_office, address_lat, address_lon)
  VALUES ('rpc-co-a-' || gen_random_uuid()::text, 72.00, 36, 'EUR', v_dom_a, 5, 46.77, 23.59) RETURNING id INTO v_co_a;
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain, days_in_office, address_lat, address_lon)
  VALUES ('rpc-co-b-' || gen_random_uuid()::text, 72.00, 36, 'EUR', v_dom_b, 5, 44.43, 26.10) RETURNING id INTO v_co_b;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  VALUES
    (v_hr,  '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'hr@'  || v_dom_a, '', now(), now(), '', '', '', ''),
    (v_e1,  '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'e1@'  || v_dom_a, '', now(), now(), '', '', '', ''),
    (v_emp, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'emp@' || v_dom_a, '', now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES
    (v_hr,  'hr@'  || v_dom_a, v_co_a, 'active', 'HR',  'A'),
    (v_e1,  'e1@'  || v_dom_a, v_co_a, 'active', 'E1',  'A'),
    (v_emp, 'emp@' || v_dom_a, v_co_a, 'active', 'EMP', 'A');

  INSERT INTO public.user_roles (user_id, role) VALUES
    (v_hr,  'hr'::public.user_role),
    (v_emp, 'employee'::public.user_role);

  -- Company A active invites with controlled created_at (no linked profile →
  -- last_activity = pi.created_at), plus one inactive.
  INSERT INTO public.profile_invites (email, company_id, first_name, last_name, status, created_at) VALUES
    ('inv1@' || v_dom_a, v_co_a, 'I1', 'A', 'active'::public.user_profile_status,   now() - interval '60 days'),
    ('inv2@' || v_dom_a, v_co_a, 'I2', 'A', 'active'::public.user_profile_status,   now() - interval '3 days'),
    ('inv3@' || v_dom_a, v_co_a, 'I3', 'A', 'inactive'::public.user_profile_status, now() - interval '1 day');

  -- Company B: 3 active invites that must never appear in A's results.
  INSERT INTO public.profile_invites (email, company_id, first_name, last_name, status) VALUES
    ('b1@' || v_dom_b, v_co_b, 'B1', 'B', 'active'::public.user_profile_status),
    ('b2@' || v_dom_b, v_co_b, 'B2', 'B', 'active'::public.user_profile_status),
    ('b3@' || v_dom_b, v_co_b, 'B3', 'B', 'active'::public.user_profile_status);

  INSERT INTO public.employee_pii (user_id, company_id, commute_distance_km, commute_distance_computed_at)
  VALUES (v_e1, v_co_a, 5.0, now());

  -- e1: active+delivered benefit set exactly via replica (no trigger), updated 3d ago.
  SET LOCAL session_replication_role = replica;
  INSERT INTO public.bike_benefits (user_id, step, committed_at, delivered_at, benefit_status, updated_at)
  VALUES (v_e1, 'sign_contract', now() - interval '3 days', now() - interval '3 days', 'active'::public.benefit_status, now() - interval '3 days');
  SET LOCAL session_replication_role = DEFAULT;

  PERFORM set_config('test.hr_id',  v_hr::text,  false);
  PERFORM set_config('test.emp_id', v_emp::text, false);
END;
$$;

SELECT plan(9);

-- Populate this week's CO₂ stats for company A (e1: 5km*2*5*0.165 = 8.25).
SELECT public.refresh_company_co2_stats();

-- Authenticate as HR of company A.
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_id'), 'role', 'authenticated', 'user_role', 'hr')::text, true);

-- ── All-time (p_from = NULL) ──────────────────────────────────────────────────
SELECT is((SELECT active_accounts FROM public.get_company_metrics(NULL, now())),
  2, 'R01: all-time active_accounts = 2 (inv1 + inv2)');
SELECT is((SELECT active_benefits FROM public.get_company_metrics(NULL, now())),
  1, 'R02: all-time active_benefits = 1 (e1)');
SELECT is((SELECT co2_kg FROM public.get_company_metrics(NULL, now())),
  8.25::numeric, 'R03: all-time co2_kg = 8.25 (e1 this week)');

-- ── Windowed accounts ─────────────────────────────────────────────────────────
SELECT is((SELECT active_accounts FROM public.get_company_metrics(now() - interval '28 days', now())),
  1, 'R04: last-month active_accounts = 1 (inv2 only; inv1 is 60d old)');
SELECT is((SELECT active_accounts FROM public.get_company_metrics(now() - interval '7 days', now())),
  1, 'R05: last-week active_accounts = 1 (inv2)');

-- ── Windowed benefits: benefit was updated 3d ago, so a 1-day window excludes it
SELECT is((SELECT active_benefits FROM public.get_company_metrics(now() - interval '1 day', now())),
  0, 'R06: last-day active_benefits = 0 (e1 updated 3d ago)');

-- ── CO₂ range entirely before this week → 0 ───────────────────────────────────
SELECT is((SELECT co2_kg FROM public.get_company_metrics(now() - interval '60 days', now() - interval '30 days')),
  0::numeric, 'R07: past-window co2_kg = 0 (only the current week has stats)');

-- ── Company scoping: B''s 3 active invites never leak into A''s count ─────────
SELECT is((SELECT active_accounts FROM public.get_company_metrics(NULL, now())),
  2, 'R08: company scoping — A sees only its own 2 active invites, not B''s 3');

-- ── Role guard: an employee is rejected ───────────────────────────────────────
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp_id'), 'role', 'authenticated', 'user_role', 'employee')::text, true);
SELECT throws_ok(
  $$ SELECT * FROM public.get_company_metrics(NULL, now()) $$,
  '42501',
  'not_authorized',
  'R09: employee role is rejected (42501 not_authorized)');

SELECT * FROM finish();
ROLLBACK;
