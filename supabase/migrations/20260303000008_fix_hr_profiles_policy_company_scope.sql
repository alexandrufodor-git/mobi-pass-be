-- Fix: HR profiles SELECT policy was not scoped to the HR's own company.
-- Any HR user could previously read profiles from all companies.
DROP POLICY IF EXISTS "HR can view profiles" ON public.profiles;

CREATE POLICY "hr_select_own_company_profiles"
  ON public.profiles
  FOR SELECT
  TO authenticated
  USING (
    auth.jwt() ->> 'user_role' = 'hr'
    AND company_id = public.auth_company_id()
  );
