-- ============================================================================
-- company_notifications: persistent notification history for HR dashboard.
-- Replaces fire-and-forget Realtime broadcast + notify-user-registration edge fn.
-- Realtime postgres_changes on this table delivers INSERTs to subscribed clients.
-- ============================================================================

-- ── 1. Table ─────────────────────────────────────────────────────────────────

CREATE TABLE public.company_notifications (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  event       text NOT NULL,      -- 'user_update', 'contract_update'
  event_type  text NOT NULL,      -- 'created', 'signed_by_employee', etc.
  payload     jsonb DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_company_notifications_company_id ON public.company_notifications(company_id);
CREATE INDEX idx_company_notifications_created_at ON public.company_notifications(created_at DESC);

ALTER TABLE public.company_notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "hr_admin_select_own_company_notifications"
  ON public.company_notifications FOR SELECT TO authenticated
  USING (
    company_id = public.auth_company_id()
    AND auth.jwt() ->> 'user_role' IN ('hr', 'admin')
  );

ALTER PUBLICATION supabase_realtime ADD TABLE public.company_notifications;

-- ── 2. Registration trigger — direct INSERT replaces pg_net webhook relay ─────

CREATE OR REPLACE FUNCTION public.handle_user_registration()
RETURNS TRIGGER AS $$
DECLARE
  v_company_id  uuid;
  v_first_name  text;
  v_last_name   text;
  v_description text;
  v_department  text;
  v_hire_date   bigint;
BEGIN
  IF NEW.email_confirmed_at IS NOT NULL THEN

    -- 1. Resolve company_id and employee fields from profile_invites
    SELECT
      pi.company_id,
      pi.first_name,
      pi.last_name,
      pi.description,
      pi.department,
      pi.hire_date
    INTO
      v_company_id,
      v_first_name,
      v_last_name,
      v_description,
      v_department,
      v_hire_date
    FROM public.profile_invites pi
    WHERE LOWER(pi.email) = LOWER(NEW.email)
    LIMIT 1;

    IF v_company_id IS NULL THEN
      RAISE EXCEPTION 'No active invite found for email %', NEW.email;
    END IF;

    -- 2. Create or update profile (must exist before user_roles FK insert)
    INSERT INTO public.profiles (
      user_id, email, status, company_id,
      first_name, last_name, description, department, hire_date
    )
    VALUES (
      NEW.id, NEW.email, 'active'::public.user_profile_status, v_company_id,
      v_first_name, v_last_name, v_description, v_department, v_hire_date
    )
    ON CONFLICT (user_id) DO UPDATE SET
      email       = EXCLUDED.email,
      status      = 'active'::public.user_profile_status,
      company_id  = EXCLUDED.company_id,
      first_name  = EXCLUDED.first_name,
      last_name   = EXCLUDED.last_name,
      description = EXCLUDED.description,
      department  = EXCLUDED.department,
      hire_date   = EXCLUDED.hire_date;

    -- 3. Assign 'employee' role
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, 'employee'::public.user_role)
    ON CONFLICT (user_id, role) DO NOTHING;

    -- 4. Update profile_invites status
    UPDATE public.profile_invites
    SET status = 'active'::public.user_profile_status
    WHERE LOWER(email) = LOWER(NEW.email);

    -- 5. Create bike benefit
    INSERT INTO public.bike_benefits (user_id)
    VALUES (NEW.id)
    ON CONFLICT DO NOTHING;

    -- 6. Insert notification — Realtime postgres_changes delivers it to HR dashboard
    INSERT INTO public.company_notifications (company_id, event, event_type, payload)
    VALUES (
      v_company_id,
      'user_update',
      'created',
      jsonb_build_object(
        'user_id',       NEW.id,
        'employee_name', v_first_name || ' ' || v_last_name
      )
    );

  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 3. Cleanup: drop old broadcast policy (replaced by company_notifications) ─

DROP POLICY IF EXISTS "hr_admin_can_receive_company_broadcasts" ON realtime.messages;
