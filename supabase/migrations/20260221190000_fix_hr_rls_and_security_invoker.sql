-- ============================================
-- Fix HR RLS policies for bike_benefits / bike_orders
-- and rebuild profile_invites_with_details with security_invoker = on.
--
-- Root cause:
--   bike_benefits_hr_select / bike_orders_hr_select contained a
--   self-join subquery on `profiles` to determine the caller's company:
--
--     user_id IN (
--       SELECT p.user_id
--       FROM profiles p
--       JOIN profiles my_profile ON my_profile.user_id = auth.uid()
--       WHERE p.company_id = my_profile.company_id
--     )
--
--   When security_invoker = on is active on the view, PostgreSQL enforces
--   profiles RLS *inside* this subquery.  The nested RLS evaluation of a
--   different table from within another table's RLS policy is unreliable
--   in security-invoker context — auth.jwt() claims may not resolve, causing
--   the subquery to return 0 rows and the policy to deny access.
--
--   Profile / invite data works because those HR policies only check
--   auth.jwt() ->> 'user_role' with no nested table lookups.
--
-- Fix:
--   1. Add auth_company_id() — a SECURITY DEFINER helper that reads the
--      caller's company_id directly from profiles, bypassing RLS entirely.
--   2. Rewrite HR policies to use the simple pattern:
--        user_id IN (SELECT user_id FROM profiles WHERE company_id = auth_company_id())
--      The outer profiles subquery is still subject to RLS, but "HR can view
--      profiles" is a simple JWT check with no further nesting, so it works.
--   3. Rebuild the view with security_invoker = on and GRANT SELECT.
-- ============================================


-- ============================================
-- 1. SECURITY DEFINER helper: caller's company_id
-- ============================================

CREATE OR REPLACE FUNCTION public.auth_company_id()
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT company_id
  FROM public.profiles
  WHERE user_id = auth.uid()
$$;

GRANT EXECUTE ON FUNCTION public.auth_company_id() TO authenticated;


-- ============================================
-- 2. Fix bike_benefits HR policies
-- ============================================

DROP POLICY IF EXISTS "bike_benefits_hr_select" ON public.bike_benefits;
DROP POLICY IF EXISTS "bike_benefits_hr_update" ON public.bike_benefits;

CREATE POLICY "bike_benefits_hr_select"
  ON public.bike_benefits
  FOR SELECT
  TO authenticated
  USING (
    (auth.jwt() ->> 'user_role') IN ('hr', 'admin')
    AND user_id IN (
      SELECT user_id FROM public.profiles
      WHERE company_id = public.auth_company_id()
    )
  );

CREATE POLICY "bike_benefits_hr_update"
  ON public.bike_benefits
  FOR UPDATE
  TO authenticated
  USING (
    (auth.jwt() ->> 'user_role') IN ('hr', 'admin')
    AND user_id IN (
      SELECT user_id FROM public.profiles
      WHERE company_id = public.auth_company_id()
    )
  );


-- ============================================
-- 3. Fix bike_orders HR policies
-- ============================================

DROP POLICY IF EXISTS "bike_orders_hr_select" ON public.bike_orders;
DROP POLICY IF EXISTS "bike_orders_hr_update" ON public.bike_orders;

CREATE POLICY "bike_orders_hr_select"
  ON public.bike_orders
  FOR SELECT
  TO authenticated
  USING (
    (auth.jwt() ->> 'user_role') IN ('hr', 'admin')
    AND user_id IN (
      SELECT user_id FROM public.profiles
      WHERE company_id = public.auth_company_id()
    )
  );

CREATE POLICY "bike_orders_hr_update"
  ON public.bike_orders
  FOR UPDATE
  TO authenticated
  USING (
    (auth.jwt() ->> 'user_role') IN ('hr', 'admin')
    AND user_id IN (
      SELECT user_id FROM public.profiles
      WHERE company_id = public.auth_company_id()
    )
  );


-- ============================================
-- 4. Rebuild profile_invites_with_details
--    with security_invoker = on + GRANT SELECT
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
