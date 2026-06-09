-- Google Workspace SSO — Migration 3 of 4: handle_user_registration + Google branch.
--
-- Adds a provider='google' branch to the registration trigger. The email/OTP/
-- password logic is copied VERBATIM from the shipped body (schema.sql, shipped
-- by 20260608000001) and is the fall-through default — any non-google provider
-- behaves exactly as today. Only the Google path is new.
--
-- ⚠️ Trigger re-arm (NOT in the plan, deliberate): the shipped INSERT trigger
-- on_auth_user_created fires WHEN (email_confirmed_at IS NOT NULL AND
-- encrypted_password IS NOT NULL). A Google OAuth user has NO password, so
-- GoTrue may insert them with encrypted_password NULL — which would make the
-- INSERT trigger never fire and the user never onboard (the #1 SSO path). We
-- re-arm it to ALSO fire for provider='google', while preserving the seed
-- escape hatch (seed sets encrypted_password NULL + provider='email' to skip).
-- The UPDATE trigger already covers the insert-then-confirm OAuth variant
-- (email_confirmed_at NULL→non-NULL), so it is left unchanged.

CREATE OR REPLACE FUNCTION public.handle_user_registration()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_provider        text;
  v_hd              text;
  v_email_domain    text;
  v_company_id      uuid;
  v_sso_kind        text;
  v_sso_hd_required boolean;
  v_matched_via     text;
  v_first_name      text;
  v_last_name       text;
  v_description     text;
  v_department      text;
  v_hire_date       bigint;
  v_invite_id       uuid;
BEGIN
  IF NEW.email_confirmed_at IS NULL THEN
    RETURN NEW;
  END IF;

  v_provider := COALESCE(NEW.raw_app_meta_data->>'provider', 'email');

  -- ============================================================
  -- Google OIDC user (NEW). Everything else falls through to the
  -- existing email/OTP/password logic below, unchanged.
  -- ============================================================
  IF v_provider = 'google' THEN
    v_hd           := NEW.raw_user_meta_data->>'hd';
    v_email_domain := lower(split_part(NEW.email, '@', 2));

    -- Resolve the SSO-enabled company. Prefer the hd claim (the true Workspace
    -- domain); fall back to the email domain only when hd is absent.
    SELECT id, sso_kind, sso_hd_required
      INTO v_company_id, v_sso_kind, v_sso_hd_required
      FROM public.companies
     WHERE lower(email_domain) = COALESCE(lower(v_hd), v_email_domain)
       AND sso_kind = 'google_oidc'
     LIMIT 1;

    IF v_company_id IS NULL THEN
      RAISE EXCEPTION 'SSO_DOMAIN_NOT_AUTHORIZED: % / hd=%', NEW.email, COALESCE(v_hd, '<none>');
    END IF;

    IF v_sso_hd_required AND v_hd IS NULL THEN
      RAISE EXCEPTION 'SSO_HD_REQUIRED: % missing hd claim (personal Google account?)', NEW.email;
    END IF;

    IF v_sso_hd_required AND lower(v_hd) <> v_email_domain THEN
      RAISE EXCEPTION 'SSO_HD_EMAIL_MISMATCH: email domain % does not match hd %', v_email_domain, v_hd;
    END IF;

    -- Match an invite by email OR derived_email, scoped to this company.
    -- Prefer the exact-email invite (deterministic). REGES-staged rows have
    -- email NULL but derived_email set — this is how SSO auto-links them.
    SELECT pi.id, pi.first_name, pi.last_name, pi.description, pi.department, pi.hire_date,
           CASE WHEN LOWER(pi.email) = LOWER(NEW.email) THEN 'email' ELSE 'derived_email' END
      INTO v_invite_id, v_first_name, v_last_name, v_description, v_department, v_hire_date,
           v_matched_via
      FROM public.profile_invites pi
     WHERE pi.company_id = v_company_id
       AND (LOWER(pi.email) = LOWER(NEW.email) OR LOWER(pi.derived_email) = LOWER(NEW.email))
     ORDER BY (LOWER(pi.email) = LOWER(NEW.email)) DESC NULLS LAST
     LIMIT 1;

    IF v_invite_id IS NOT NULL THEN
      -- Matched → full onboarding, mirroring the email branch.
      INSERT INTO public.profiles (
        user_id, email, status, company_id,
        first_name, last_name, description, department, hire_date,
        profile_invite_id
      )
      VALUES (
        NEW.id, NEW.email, 'active'::public.user_profile_status, v_company_id,
        v_first_name, v_last_name, v_description, v_department, v_hire_date,
        v_invite_id
      )
      ON CONFLICT (user_id) DO UPDATE SET
        email             = EXCLUDED.email,
        status            = 'active'::public.user_profile_status,
        company_id        = EXCLUDED.company_id,
        first_name        = EXCLUDED.first_name,
        last_name         = EXCLUDED.last_name,
        description       = EXCLUDED.description,
        department        = EXCLUDED.department,
        hire_date         = EXCLUDED.hire_date,
        profile_invite_id = EXCLUDED.profile_invite_id;

      INSERT INTO public.user_roles (user_id, role)
      VALUES (NEW.id, 'employee'::public.user_role)
      ON CONFLICT (user_id, role) DO NOTHING;

      -- Flip invite to active; if matched via derived_email, bind its email to
      -- the verified Google email so the invite is no longer "pending" and
      -- downstream joins are stable.
      UPDATE public.profile_invites
         SET status = 'active'::public.user_profile_status,
             email  = CASE WHEN v_matched_via = 'derived_email' THEN NEW.email ELSE email END
       WHERE id = v_invite_id;

      -- Step 4.5: backfill staged REGES PII (mirrors the email branch).
      UPDATE public.employee_pii
         SET user_id    = NEW.id,
             updated_at = now()
       WHERE profile_invite_id = v_invite_id
         AND user_id IS NULL;

      INSERT INTO public.bike_benefits (user_id)
      VALUES (NEW.id)
      ON CONFLICT DO NOTHING;

      INSERT INTO public.company_notifications (company_id, event, event_type, payload)
      VALUES (
        v_company_id, 'user_update', 'created',
        jsonb_build_object(
          'user_id',       NEW.id,
          'employee_name', v_first_name || ' ' || v_last_name,
          'auth_provider', 'google',
          'matched_via',   v_matched_via
        )
      );

      RETURN NEW;
    END IF;

    -- No invite match → pending claim. NO role, NO benefit, NO PII link.
    -- profiles.first_name/last_name are NOT NULL; a Google user carries their
    -- name in the ID token (given_name/family_name, stored in raw_user_meta_data),
    -- so use that, falling back to the name claim then the email local-part.
    -- These are placeholders only — promote_sso_claim overwrites them from the
    -- matched invite once the claim is approved.
    INSERT INTO public.profiles (user_id, email, status, company_id, first_name, last_name)
    VALUES (
      NEW.id, NEW.email, 'pending_sso_claim'::public.user_profile_status, v_company_id,
      COALESCE(NULLIF(NEW.raw_user_meta_data->>'given_name', ''),
               NULLIF(NEW.raw_user_meta_data->>'name', ''),
               split_part(NEW.email, '@', 1)),
      COALESCE(NULLIF(NEW.raw_user_meta_data->>'family_name', ''), '')
    )
    ON CONFLICT (user_id) DO UPDATE SET
      email      = EXCLUDED.email,
      status     = 'pending_sso_claim'::public.user_profile_status,
      company_id = EXCLUDED.company_id;

    INSERT INTO public.sso_pending_claims (user_id, company_id, email, hd, status)
    VALUES (NEW.id, v_company_id, NEW.email, v_hd, 'awaiting_user_info')
    ON CONFLICT DO NOTHING;

    INSERT INTO public.company_notifications (company_id, event, event_type, payload)
    VALUES (
      v_company_id, 'user_update', 'sso_claim_pending',
      jsonb_build_object('user_id', NEW.id, 'email', NEW.email, 'hd', v_hd)
    );

    RETURN NEW;
  END IF;

  -- ============================================================
  -- email / OTP / password user — VERBATIM from the shipped body.
  -- ============================================================

  -- 1. Resolve company_id and employee fields from profile_invites.
  --    Match on email OR derived_email; prefer the exact-email invite.
  SELECT
    pi.id,
    pi.company_id,
    pi.first_name,
    pi.last_name,
    pi.description,
    pi.department,
    pi.hire_date
  INTO
    v_invite_id,
    v_company_id,
    v_first_name,
    v_last_name,
    v_description,
    v_department,
    v_hire_date
  FROM public.profile_invites pi
  WHERE LOWER(pi.email) = LOWER(NEW.email)
     OR LOWER(pi.derived_email) = LOWER(NEW.email)
  ORDER BY (LOWER(pi.email) = LOWER(NEW.email)) DESC NULLS LAST
  LIMIT 1;

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'No active invite found for email %', NEW.email;
  END IF;

  -- 2. Create or update profile (must exist before user_roles FK insert).
  --    profile_invite_id stamps the canonical person link.
  INSERT INTO public.profiles (
    user_id, email, status, company_id,
    first_name, last_name, description, department, hire_date,
    profile_invite_id
  )
  VALUES (
    NEW.id, NEW.email, 'active'::public.user_profile_status, v_company_id,
    v_first_name, v_last_name, v_description, v_department, v_hire_date,
    v_invite_id
  )
  ON CONFLICT (user_id) DO UPDATE SET
    email             = EXCLUDED.email,
    status            = 'active'::public.user_profile_status,
    company_id        = EXCLUDED.company_id,
    first_name        = EXCLUDED.first_name,
    last_name         = EXCLUDED.last_name,
    description       = EXCLUDED.description,
    department        = EXCLUDED.department,
    hire_date         = EXCLUDED.hire_date,
    profile_invite_id = EXCLUDED.profile_invite_id;

  -- 3. Assign 'employee' role
  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, 'employee'::public.user_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  -- 4. Update profile_invites status (by id — covers derived-email matches
  --    where email may be NULL on the invite).
  UPDATE public.profile_invites
  SET status = 'active'::public.user_profile_status
  WHERE id = v_invite_id;

  -- 4.5. Link any pending REGES PII to this user
  UPDATE public.employee_pii
     SET user_id    = NEW.id,
         updated_at = now()
   WHERE profile_invite_id = v_invite_id
     AND user_id IS NULL;

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

  RETURN NEW;
END;
$$;

ALTER FUNCTION public.handle_user_registration() OWNER TO postgres;

-- Re-arm the INSERT trigger so passwordless Google OAuth users fire it.
-- (See header note. Seed rows — provider='email' + encrypted_password NULL —
-- still skip, preserving the seed escape hatch.)
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW
WHEN (
  NEW.email_confirmed_at IS NOT NULL
  AND (
    NEW.encrypted_password IS NOT NULL
    OR NEW.raw_app_meta_data->>'provider' = 'google'
  )
)
EXECUTE FUNCTION public.handle_user_registration();
