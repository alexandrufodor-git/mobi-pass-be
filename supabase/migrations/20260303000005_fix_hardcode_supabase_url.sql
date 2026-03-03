-- Fix: replace current_setting('app.settings.supabase_url') with the hardcoded
-- project URL. The URL is public and not sensitive, so a GUC is unnecessary overhead.

CREATE OR REPLACE FUNCTION public.handle_user_registration()
RETURNS TRIGGER AS $$
DECLARE
  v_company_id uuid;
  v_first_name text;
  v_last_name text;
  v_description text;
  v_department text;
  v_hire_date bigint;
  v_webhook_secret text;
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

    -- 2. Create or update profile first (user_roles FK depends on this)
    INSERT INTO public.profiles (
      user_id,
      email,
      status,
      company_id,
      first_name,
      last_name,
      description,
      department,
      hire_date
    )
    VALUES (
      NEW.id,
      NEW.email,
      'active'::public.user_profile_status,
      v_company_id,
      v_first_name,
      v_last_name,
      v_description,
      v_department,
      v_hire_date
    )
    ON CONFLICT (user_id)
    DO UPDATE SET
      email       = EXCLUDED.email,
      status      = 'active'::public.user_profile_status,
      company_id  = EXCLUDED.company_id,
      first_name  = EXCLUDED.first_name,
      last_name   = EXCLUDED.last_name,
      description = EXCLUDED.description,
      department  = EXCLUDED.department,
      hire_date   = EXCLUDED.hire_date;

    -- 3. Assign employee role (profile must already exist)
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, 'employee'::public.user_role)
    ON CONFLICT (user_id, role) DO NOTHING;

    -- 4. Update profile_invites status to 'active'
    UPDATE public.profile_invites
    SET status = 'active'::public.user_profile_status
    WHERE LOWER(email) = LOWER(NEW.email);

    -- 5. Create a bike benefit for the user
    INSERT INTO public.bike_benefits (user_id)
    VALUES (NEW.id)
    ON CONFLICT DO NOTHING;

    -- 6. Broadcast user_update to HR dashboard via notify-user-registration edge function
    SELECT decrypted_secret INTO v_webhook_secret
    FROM vault.decrypted_secrets
    WHERE name = 'broadcast_webhook_secret'
    LIMIT 1;

    IF v_webhook_secret IS NOT NULL THEN
      PERFORM net.http_post(
        url     := 'https://xlfkdumbsflqxpezolhl.supabase.co/functions/v1/notify-user-registration',
        headers := jsonb_build_object(
          'Content-Type',     'application/json',
          'x-webhook-secret', v_webhook_secret
        ),
        body    := jsonb_build_object(
          'company_id',    v_company_id,
          'user_id',       NEW.id,
          'employee_name', v_first_name || ' ' || v_last_name
        )
      );
    ELSE
      RAISE WARNING '[handle_user_registration] Vault secret "broadcast_webhook_secret" not found — user_update broadcast skipped';
    END IF;

  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
