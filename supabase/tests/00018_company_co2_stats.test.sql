SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: Company CO₂ engine — refresh_company_co2_stats() (WEEKLY) + summary view + RLS
--
-- Migrations 20260627000001/2. Verifies the per-company WEEKLY upsert over the
-- derived scalar employee_pii.commute_distance_km, the delivered+active
-- lifecycle gate, the LEFT-JOIN-LATERAL zero row, idempotency, drop-to-zero,
-- the company_co2_summary roll-up view, and the HR-own-company RLS read policy.
--
-- Constants (skill references/co2-commute-engine.md):
--   week_km      = commute_distance_km × 2 × days_in_office
--   kg_co2_saved = week_km × 0.165
-- For emp1: 5.0 × 2 × 5 = 50 km; × 0.165 = 8.25 kg.
--
-- Fixtures (company A, days_in_office = 5):
--   emp1  commute 5.0,  benefit active + delivered   → QUALIFIES
--   emp2  commute NULL, benefit active + delivered   → excluded (no coords)
--   emp3  commute 8.0,  benefit active, NOT delivered→ excluded (gate)
--   emp4  commute 10.0, benefit terminated+delivered → excluded (gate)
--   + a prior-week company_co2_stats row for A (kg 5.0) to test the roll-up.
-- Company B: no riders → expects a zero row from the LEFT JOIN LATERAL.
--
--  T01 active_riders=1  T02 total_km=50  T03 kg=8.25  T04 company B zero row
--  V1 all_time_kg=13.25  V2 last_week_kg=5.0
--  T05 idempotent rerun  T06/07 drop-to-zero
--  T08/09 table RLS   V3/V4 view RLS
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_co_a  uuid;
  v_co_b  uuid;
  v_dom_a text := 'co2-a-' || gen_random_uuid()::text || '.test';
  v_dom_b text := 'co2-b-' || gen_random_uuid()::text || '.test';
  v_hr    uuid := gen_random_uuid();  -- HR in company A
  v_e1    uuid := gen_random_uuid();
  v_e2    uuid := gen_random_uuid();
  v_e3    uuid := gen_random_uuid();
  v_e4    uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain, days_in_office, address_lat, address_lon)
  VALUES ('co2-co-a-' || gen_random_uuid()::text, 72.00, 36, 'EUR', v_dom_a, 5, 46.77, 23.59) RETURNING id INTO v_co_a;
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain, days_in_office, address_lat, address_lon)
  VALUES ('co2-co-b-' || gen_random_uuid()::text, 72.00, 36, 'EUR', v_dom_b, 5, 44.43, 26.10) RETURNING id INTO v_co_b;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  VALUES
    (v_hr, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'hr@'  || v_dom_a, '', now(), now(), '', '', '', ''),
    (v_e1, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'e1@'  || v_dom_a, '', now(), now(), '', '', '', ''),
    (v_e2, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'e2@'  || v_dom_a, '', now(), now(), '', '', '', ''),
    (v_e3, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'e3@'  || v_dom_a, '', now(), now(), '', '', '', ''),
    (v_e4, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'e4@'  || v_dom_a, '', now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES
    (v_hr, 'hr@' || v_dom_a, v_co_a, 'active', 'HR', 'A'),
    (v_e1, 'e1@' || v_dom_a, v_co_a, 'active', 'E1', 'A'),
    (v_e2, 'e2@' || v_dom_a, v_co_a, 'active', 'E2', 'A'),
    (v_e3, 'e3@' || v_dom_a, v_co_a, 'active', 'E3', 'A'),
    (v_e4, 'e4@' || v_dom_a, v_co_a, 'active', 'E4', 'A');

  INSERT INTO public.user_roles (user_id, role) VALUES (v_hr, 'hr'::public.user_role);

  INSERT INTO public.employee_pii (user_id, company_id, commute_distance_km, commute_distance_computed_at) VALUES
    (v_e1, v_co_a, 5.0,  now()),
    (v_e2, v_co_a, NULL, NULL),
    (v_e3, v_co_a, 8.0,  now()),
    (v_e4, v_co_a, 10.0, now());

  -- bike_benefits: bypass the status trigger so we set exact gate states.
  SET LOCAL session_replication_role = replica;
  INSERT INTO public.bike_benefits (user_id, step, committed_at, delivered_at, benefit_status) VALUES
    (v_e1, 'sign_contract', now(), now(), 'active'::public.benefit_status),      -- qualifies
    (v_e2, 'sign_contract', now(), now(), 'active'::public.benefit_status),      -- excluded: no coords
    (v_e3, 'sign_contract', now(), NULL,  'active'::public.benefit_status),      -- excluded: not delivered
    (v_e4, 'sign_contract', now(), now(), 'terminated'::public.benefit_status);  -- excluded: terminated
  SET LOCAL session_replication_role = DEFAULT;

  -- A prior completed week for company A (for the roll-up view).
  INSERT INTO public.company_co2_stats (company_id, period, kg_co2_saved, active_riders, total_km)
  VALUES (v_co_a, date_trunc('week', now() - interval '1 week')::date, 5.0, 1, 30.0);

  PERFORM set_config('test.hr_id',   v_hr::text,   false);
  PERFORM set_config('test.e1_id',   v_e1::text,   false);
  PERFORM set_config('test.co_a_id', v_co_a::text, false);
  PERFORM set_config('test.co_b_id', v_co_b::text, false);
END;
$$;

SELECT plan(13);

-- Run the aggregation for the current week.
SELECT public.refresh_company_co2_stats();

-- ── Aggregate correctness for company A (only emp1 qualifies) ──────────────────
SELECT is(
  (SELECT active_riders FROM public.company_co2_stats
   WHERE company_id = current_setting('test.co_a_id')::uuid
     AND period = date_trunc('week', now())::date),
  1,
  'T01: company A counts exactly the one delivered+active rider with coords'
);

SELECT is(
  (SELECT total_km FROM public.company_co2_stats
   WHERE company_id = current_setting('test.co_a_id')::uuid
     AND period = date_trunc('week', now())::date),
  50::numeric,
  'T02: total_km = 5.0 × 2 × days_in_office(5) = 50'
);

SELECT is(
  (SELECT kg_co2_saved FROM public.company_co2_stats
   WHERE company_id = current_setting('test.co_a_id')::uuid
     AND period = date_trunc('week', now())::date),
  8.25::numeric,
  'T03: kg_co2_saved = 50 × 0.165 = 8.25'
);

-- ── Company B has no riders → still gets a zero row (LEFT JOIN LATERAL) ────────
SELECT is(
  (SELECT active_riders FROM public.company_co2_stats
   WHERE company_id = current_setting('test.co_b_id')::uuid
     AND period = date_trunc('week', now())::date),
  0,
  'T04: company with no qualifying riders upserts a zero row'
);

-- ── Roll-up view: all-time sums weeks, last_week reads the prior week ──────────
SELECT is(
  (SELECT all_time_kg FROM public.company_co2_summary
   WHERE company_id = current_setting('test.co_a_id')::uuid),
  13.25::numeric,
  'V1: all_time_kg = this week 8.25 + prior week 5.0 = 13.25'
);
SELECT is(
  (SELECT last_week_kg FROM public.company_co2_summary
   WHERE company_id = current_setting('test.co_a_id')::uuid),
  5.0::numeric,
  'V2: last_week_kg = the prior completed week (5.0)'
);

-- ── Idempotency: a second run does not double-count ───────────────────────────
SELECT public.refresh_company_co2_stats();
SELECT is(
  (SELECT active_riders FROM public.company_co2_stats
   WHERE company_id = current_setting('test.co_a_id')::uuid
     AND period = date_trunc('week', now())::date),
  1,
  'T05: re-running the upsert keeps active_riders = 1 (idempotent)'
);

-- ── Drop-to-zero: terminate the only rider, re-run → company A goes to 0 ───────
SET session_replication_role = replica;
UPDATE public.bike_benefits
SET benefit_status = 'terminated'::public.benefit_status
WHERE user_id = current_setting('test.e1_id')::uuid;
SET session_replication_role = DEFAULT;

SELECT public.refresh_company_co2_stats();

SELECT is(
  (SELECT active_riders FROM public.company_co2_stats
   WHERE company_id = current_setting('test.co_a_id')::uuid
     AND period = date_trunc('week', now())::date),
  0,
  'T06: terminating the last rider drops active_riders to 0 on the next run'
);
SELECT is(
  (SELECT kg_co2_saved FROM public.company_co2_stats
   WHERE company_id = current_setting('test.co_a_id')::uuid
     AND period = date_trunc('week', now())::date),
  0::numeric,
  'T07: kg_co2_saved also resets to 0 (no accrual after termination)'
);

-- ── RLS: HR of company A reads only their own company's stats + summary ───────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_id'), 'role', 'authenticated', 'user_role', 'hr')::text,
  true);

SELECT ok(
  EXISTS(SELECT 1 FROM public.company_co2_stats WHERE company_id = current_setting('test.co_a_id')::uuid),
  'T08: HR sees own-company CO₂ stats'
);
SELECT ok(
  NOT EXISTS(SELECT 1 FROM public.company_co2_stats WHERE company_id = current_setting('test.co_b_id')::uuid),
  'T09: HR cannot see another company''s CO₂ stats'
);
SELECT ok(
  EXISTS(SELECT 1 FROM public.company_co2_summary WHERE company_id = current_setting('test.co_a_id')::uuid),
  'V3: HR sees own-company summary row (view inherits RLS via security_invoker)'
);
SELECT ok(
  NOT EXISTS(SELECT 1 FROM public.company_co2_summary WHERE company_id = current_setting('test.co_b_id')::uuid),
  'V4: HR cannot see another company''s summary row'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
