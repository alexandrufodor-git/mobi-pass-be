-- ============================================
-- v2 fix: HR RLS for bike_benefits / bike_orders
--
-- Previous fix (20260221190000) left the outer
--   SELECT user_id FROM profiles WHERE company_id = auth_company_id()
-- still running with the caller's RLS, meaning profiles RLS was still
-- evaluated in a nested context inside bike_benefits RLS, which can
-- silently return 0 rows when security_invoker is active.
--
-- This migration replaces that with a single SECURITY DEFINER function
-- get_my_company_user_ids() that performs the FULL company-member lookup
-- as postgres (bypassing ALL RLS on profiles), so no nested RLS is
-- ever triggered during policy evaluation.
--
-- Also matches the exact auth.jwt() comparison format used by every
-- other RLS policy in the project:
--   (auth.jwt() ->> 'user_role'::text) = ANY (ARRAY['hr'::text, 'admin'::text])
-- ============================================


-- ============================================
-- 1. Full SECURITY DEFINER lookup for company members
--    Runs as postgres — no RLS on profiles at all.
--    auth.uid() is a session-variable read and works even under SECURITY DEFINER.
-- ============================================

CREATE OR REPLACE FUNCTION public.get_my_company_user_ids()
RETURNS SETOF uuid
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT p.user_id
  FROM public.profiles p
  WHERE p.company_id = (
    SELECT company_id
    FROM public.profiles
    WHERE user_id = auth.uid()
  )
$$;

GRANT EXECUTE ON FUNCTION public.get_my_company_user_ids() TO authenticated;


-- ============================================
-- 2. bike_benefits — drop previous versions and recreate
-- ============================================

DROP POLICY IF EXISTS "bike_benefits_hr_select" ON public.bike_benefits;
DROP POLICY IF EXISTS "bike_benefits_hr_update" ON public.bike_benefits;

CREATE POLICY "bike_benefits_hr_select"
  ON public.bike_benefits
  FOR SELECT
  TO authenticated
  USING (
    (auth.jwt() ->> 'user_role'::text) = ANY (ARRAY['hr'::text, 'admin'::text])
    AND user_id IN (SELECT public.get_my_company_user_ids())
  );

CREATE POLICY "bike_benefits_hr_update"
  ON public.bike_benefits
  FOR UPDATE
  TO authenticated
  USING (
    (auth.jwt() ->> 'user_role'::text) = ANY (ARRAY['hr'::text, 'admin'::text])
    AND user_id IN (SELECT public.get_my_company_user_ids())
  );


-- ============================================
-- 3. bike_orders — drop previous versions and recreate
-- ============================================

DROP POLICY IF EXISTS "bike_orders_hr_select" ON public.bike_orders;
DROP POLICY IF EXISTS "bike_orders_hr_update" ON public.bike_orders;

CREATE POLICY "bike_orders_hr_select"
  ON public.bike_orders
  FOR SELECT
  TO authenticated
  USING (
    (auth.jwt() ->> 'user_role'::text) = ANY (ARRAY['hr'::text, 'admin'::text])
    AND user_id IN (SELECT public.get_my_company_user_ids())
  );

CREATE POLICY "bike_orders_hr_update"
  ON public.bike_orders
  FOR UPDATE
  TO authenticated
  USING (
    (auth.jwt() ->> 'user_role'::text) = ANY (ARRAY['hr'::text, 'admin'::text])
    AND user_id IN (SELECT public.get_my_company_user_ids())
  );


-- ============================================
-- 4. profiles — ensure HR can read company employees' profiles
--    The existing "HR can view profiles" policy (user_role = 'hr') is
--    broad (all profiles).  Add a tighter companion policy scoped to the
--    calling HR user's company so that even if the broad policy is ever
--    removed, the view JOIN still works.
--    Using DROP IF EXISTS + CREATE so this is idempotent.
-- ============================================

DROP POLICY IF EXISTS "profiles_hr_select" ON public.profiles;

CREATE POLICY "profiles_hr_select"
  ON public.profiles
  FOR SELECT
  TO authenticated
  USING (
    (auth.jwt() ->> 'user_role'::text) = ANY (ARRAY['hr'::text, 'admin'::text])
    AND user_id IN (SELECT public.get_my_company_user_ids())
  );


-- ============================================
-- 5. Rebuild view — keep security_invoker = on and GRANT
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
