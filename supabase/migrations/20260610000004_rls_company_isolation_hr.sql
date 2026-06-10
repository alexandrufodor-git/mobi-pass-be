-- RLS company isolation — close cross-tenant HR/admin leaks.
--
-- Several HR/admin policies gated only on the JWT `user_role` claim and never
-- compared `company_id`, so any HR user could read/write rows belonging to
-- EVERY company. This migration tightens each of those policies to the caller's
-- own company via public.auth_company_id() (a SECURITY DEFINER helper that
-- returns profiles.company_id for auth.uid()).
--
-- Two scoping shapes:
--   * Tables that carry company_id (profile_invites): add
--     `company_id = (select auth_company_id())`.
--   * Tables keyed by user_id only (bike_benefits, bike_orders, contracts,
--     user_roles): scope through a profiles join, matching the existing
--     tbi_loan_hr_select pattern.
--
-- Role semantics are preserved exactly as before (e.g. profile_invites stays
-- hr-only, the bike tables stay hr/admin); only the company predicate is added.
-- UPDATE policies also gain a WITH CHECK so a row cannot be reassigned out of
-- the caller's company (an UPDATE USING-only policy permits the post-image to
-- leave the tenant).
--
-- auth_company_id() is wrapped in `(select ...)` so the planner evaluates it
-- once per query (initplan) instead of per row.

-- ---------------------------------------------------------------------------
-- profile_invites — table has company_id
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "HR can view profile invites" ON "public"."profile_invites";
CREATE POLICY "HR can view profile invites" ON "public"."profile_invites"
  FOR SELECT TO "authenticated"
  USING (
    ((auth.jwt() ->> 'user_role') = 'hr')
    AND (company_id = (select public.auth_company_id()))
  );

DROP POLICY IF EXISTS "HR can update profile invites" ON "public"."profile_invites";
CREATE POLICY "HR can update profile invites" ON "public"."profile_invites"
  FOR UPDATE TO "authenticated"
  USING (
    ((auth.jwt() ->> 'user_role') = 'hr')
    AND (company_id = (select public.auth_company_id()))
  )
  WITH CHECK (
    ((auth.jwt() ->> 'user_role') = 'hr')
    AND (company_id = (select public.auth_company_id()))
  );

DROP POLICY IF EXISTS "HR can delete profile invites" ON "public"."profile_invites";
CREATE POLICY "HR can delete profile invites" ON "public"."profile_invites"
  FOR DELETE TO "authenticated"
  USING (
    ((auth.jwt() ->> 'user_role') = 'hr')
    AND (company_id = (select public.auth_company_id()))
  );

DROP POLICY IF EXISTS "Hr can only add profile invites" ON "public"."profile_invites";
CREATE POLICY "Hr can only add profile invites" ON "public"."profile_invites"
  FOR INSERT TO "authenticated"
  WITH CHECK (
    ((auth.jwt() ->> 'user_role') = 'hr')
    AND (company_id = (select public.auth_company_id()))
  );

-- ---------------------------------------------------------------------------
-- bike_benefits — keyed by user_id; scope through profiles
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "bike_benefits_hr_select" ON "public"."bike_benefits";
CREATE POLICY "bike_benefits_hr_select" ON "public"."bike_benefits"
  FOR SELECT TO "authenticated"
  USING (
    ((auth.jwt() ->> 'user_role') = ANY (ARRAY['hr', 'admin']))
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.user_id = bike_benefits.user_id
        AND p.company_id = (select public.auth_company_id())
    )
  );

DROP POLICY IF EXISTS "bike_benefits_hr_update" ON "public"."bike_benefits";
CREATE POLICY "bike_benefits_hr_update" ON "public"."bike_benefits"
  FOR UPDATE TO "authenticated"
  USING (
    ((auth.jwt() ->> 'user_role') = ANY (ARRAY['hr', 'admin']))
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.user_id = bike_benefits.user_id
        AND p.company_id = (select public.auth_company_id())
    )
  )
  WITH CHECK (
    ((auth.jwt() ->> 'user_role') = ANY (ARRAY['hr', 'admin']))
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.user_id = bike_benefits.user_id
        AND p.company_id = (select public.auth_company_id())
    )
  );

-- ---------------------------------------------------------------------------
-- bike_orders — keyed by user_id; scope through profiles
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "bike_orders_hr_select" ON "public"."bike_orders";
CREATE POLICY "bike_orders_hr_select" ON "public"."bike_orders"
  FOR SELECT TO "authenticated"
  USING (
    ((auth.jwt() ->> 'user_role') = ANY (ARRAY['hr', 'admin']))
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.user_id = bike_orders.user_id
        AND p.company_id = (select public.auth_company_id())
    )
  );

DROP POLICY IF EXISTS "bike_orders_hr_update" ON "public"."bike_orders";
CREATE POLICY "bike_orders_hr_update" ON "public"."bike_orders"
  FOR UPDATE TO "authenticated"
  USING (
    ((auth.jwt() ->> 'user_role') = ANY (ARRAY['hr', 'admin']))
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.user_id = bike_orders.user_id
        AND p.company_id = (select public.auth_company_id())
    )
  )
  WITH CHECK (
    ((auth.jwt() ->> 'user_role') = ANY (ARRAY['hr', 'admin']))
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.user_id = bike_orders.user_id
        AND p.company_id = (select public.auth_company_id())
    )
  );

-- ---------------------------------------------------------------------------
-- contracts — keyed by user_id; scope through profiles.
-- Keeps the existing user_roles-based role check, adds the company predicate.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "contracts_hr_admin_select" ON "public"."contracts";
CREATE POLICY "contracts_hr_admin_select" ON "public"."contracts"
  FOR SELECT TO "authenticated"
  USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur
      WHERE ur.user_id = auth.uid()
        AND ur.role = ANY (ARRAY['hr'::public.user_role, 'admin'::public.user_role])
    )
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.user_id = contracts.user_id
        AND p.company_id = (select public.auth_company_id())
    )
  );

-- ---------------------------------------------------------------------------
-- user_roles — HR may only assign roles to users in their own company
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "HR can assign roles" ON "public"."user_roles";
CREATE POLICY "HR can assign roles" ON "public"."user_roles"
  FOR INSERT TO "authenticated"
  WITH CHECK (
    ((auth.jwt() ->> 'user_role') = ANY (ARRAY['hr', 'admin']))
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.user_id = user_roles.user_id
        AND p.company_id = (select public.auth_company_id())
    )
  );
