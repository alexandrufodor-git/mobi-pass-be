-- 1. Allow HR/admin to subscribe to private broadcast channels for their company.
--    Required when the Angular client uses { config: { private: true } } on the channel.
--    Supabase Realtime checks realtime.messages RLS for private channels.
CREATE POLICY "hr_admin_can_receive_company_broadcasts"
  ON realtime.messages
  FOR SELECT
  TO authenticated
  USING (
    realtime.topic() = 'notifications:' || (public.auth_company_id())::text
    AND auth.jwt() ->> 'user_role' IN ('hr', 'admin')
  );

-- 2. Allow HR to read user_roles for employees in their company.
--    Required for Realtime Postgres Changes on user_roles (e.g. new employee registered).
CREATE POLICY "user_roles_hr_select"
  ON public.user_roles
  FOR SELECT
  TO authenticated
  USING (
    auth.jwt() ->> 'user_role' = 'hr'
    AND user_id IN (
      SELECT p.user_id FROM public.profiles p
      WHERE p.company_id = public.auth_company_id()
    )
  );
