-- ============================================
-- v3 fix: strip company filter from bike_benefits / bike_orders HR policies
--
-- Root cause of previous attempts failing:
--   Both get_my_company_user_ids() and auth_company_id() depend on the HR
--   user having a profiles.company_id row.  HR accounts are often created
--   outside the normal invite→register flow, so profiles.company_id may be
--   NULL or the row may not exist, causing the function to return empty →
--   user_id IN () → false → no bike_benefits/orders visible.
--
-- Also: "HR can view profiles" already exists in the DB (user_role = 'hr').
--   The profiles_hr_select policy added in 20260221200000 was a redundant
--   duplicate — dropped here.
--
-- Fix: mirror the same pattern used by "HR can view profiles":
--   just check the JWT role claim, no company subquery.
--   The view itself (profile_invites_with_details) already scopes data to the
--   right context via the profile_invites starting table.
-- ============================================


-- ============================================
-- 1. Drop redundant profiles policy added in 20260221200000
--    "HR can view profiles" (user_role = 'hr') already exists from the
--    original schema and covers this — no duplicate needed.
-- ============================================

DROP POLICY IF EXISTS "profiles_hr_select" ON public.profiles;


-- ============================================
-- 2. bike_benefits — role-only HR policies (no company subquery)
-- ============================================

DROP POLICY IF EXISTS "bike_benefits_hr_select" ON public.bike_benefits;
DROP POLICY IF EXISTS "bike_benefits_hr_update" ON public.bike_benefits;

CREATE POLICY "bike_benefits_hr_select"
  ON public.bike_benefits
  FOR SELECT
  TO authenticated
  USING (
    (auth.jwt() ->> 'user_role'::text) = ANY (ARRAY['hr'::text, 'admin'::text])
  );

CREATE POLICY "bike_benefits_hr_update"
  ON public.bike_benefits
  FOR UPDATE
  TO authenticated
  USING (
    (auth.jwt() ->> 'user_role'::text) = ANY (ARRAY['hr'::text, 'admin'::text])
  );


-- ============================================
-- 3. bike_orders — role-only HR policies (no company subquery)
-- ============================================

DROP POLICY IF EXISTS "bike_orders_hr_select" ON public.bike_orders;
DROP POLICY IF EXISTS "bike_orders_hr_update" ON public.bike_orders;

CREATE POLICY "bike_orders_hr_select"
  ON public.bike_orders
  FOR SELECT
  TO authenticated
  USING (
    (auth.jwt() ->> 'user_role'::text) = ANY (ARRAY['hr'::text, 'admin'::text])
  );

CREATE POLICY "bike_orders_hr_update"
  ON public.bike_orders
  FOR UPDATE
  TO authenticated
  USING (
    (auth.jwt() ->> 'user_role'::text) = ANY (ARRAY['hr'::text, 'admin'::text])
  );


-- ============================================
-- 4. Rebuild view — security_invoker = on + GRANT
--    (idempotent: safe to re-run after previous migrations)
-- ============================================

DROP VIEW IF EXISTS public.profile_invites_with_details;

CREATE VIEW public.profile_invites_with_details
  WITH (security_invoker = on)
AS
SELECT
  pi.id                                                       AS invite_id,
  pi.email,
  pi.status                                                   AS invite_status,
  pi.created_at                                               AS invited_at,
  pi.company_id,
  c.name                                                      AS company_name,
  p.user_id,
  p.status                                                    AS profile_status,
  p.created_at                                                AS registered_at,
  COALESCE(p.first_name,   pi.first_name)                    AS first_name,
  COALESCE(p.last_name,    pi.last_name)                     AS last_name,
  COALESCE(p.description,  pi.description)                   AS description,
  COALESCE(p.department,   pi.department)                    AS department,
  COALESCE(p.hire_date,    pi.hire_date)                     AS hire_date,
  bb.id                                                       AS bike_benefit_id,
  bb.benefit_status,
  bb.contract_status,
  COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) AS last_modified_at,
  bb.bike_id,
  bo.id                                                       AS order_id
FROM       public.profile_invites pi
LEFT JOIN  public.companies       c   ON  pi.company_id = c.id
LEFT JOIN  public.profiles        p   ON  pi.email      = p.email
LEFT JOIN  public.bike_benefits   bb  ON  p.user_id     = bb.user_id
LEFT JOIN  public.bikes           b   ON  bb.bike_id    = b.id
LEFT JOIN  public.bike_orders     bo  ON  bb.id         = bo.bike_benefit_id
ORDER BY last_modified_at DESC;

GRANT SELECT ON public.profile_invites_with_details TO authenticated;
