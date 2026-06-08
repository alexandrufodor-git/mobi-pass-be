-- Canonical person link: profiles.profile_invite_id
--
-- Foundation ADR (llm-agent-assist/plans/canonical-identity-and-roles.md),
-- "Migration A". profile_invites.id is the canonical internal person id (SSOT):
-- it exists before any auth identity and persists across re-logins / provider
-- changes. Until now `profiles` linked to its invite ONLY by matching email
-- (the trigger resolved by lower(email), and profile_invites_with_details
-- joined on pi.email = p.email). Email is now optional (REGES rows stage with
-- email NULL) and mutable (SSO corp email ≠ OTP email), so the email join is no
-- longer a sound identity key.
--
-- This migration adds an explicit FK from the profile to its invite, backfills
-- it from the existing email match (behaviour-preserving), guards one-profile-
-- per-invite with a partial unique index (the §6 cross-provider fork safety
-- net), repoints the HR-dashboard view at the FK, and teaches the registration
-- trigger to (a) set the link and (b) also resolve invites via derived_email.

-- 1. Pre-flight: the new unique link assumes at most one invite per email.
--    profile_invites_email_unique already enforces this, but assert explicitly
--    so the invariant the backfill + unique index depend on fails loud if an
--    out-of-order environment ever lacks that index.
DO $$
DECLARE
  v_dupes int;
BEGIN
  SELECT count(*) INTO v_dupes
  FROM (
    SELECT lower(email)
    FROM public.profile_invites
    WHERE email IS NOT NULL
    GROUP BY lower(email)
    HAVING count(*) > 1
  ) d;

  IF v_dupes > 0 THEN
    RAISE EXCEPTION
      'Aborting: % duplicate lower(email) value(s) in profile_invites; resolve before adding profiles.profile_invite_id', v_dupes;
  END IF;
END $$;

-- 2. The canonical link. ON DELETE SET NULL: deleting an invite must never
--    cascade-delete a live profile/auth identity.
ALTER TABLE public.profiles
  ADD COLUMN profile_invite_id uuid REFERENCES public.profile_invites(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.profiles.profile_invite_id IS
  'Canonical link to the person''s profile_invites row (SSOT person id). Set by handle_user_registration on claim; backfilled here by email match. UNIQUE (one profile per invite) — the cross-provider fork safety net.';

-- 3. Backfill from the existing email match. This reproduces exactly the pairs
--    the old view's `pi.email = p.email` join produced, so the view rewrite in
--    step 5 is behaviour-preserving. profiles.email and profile_invites(email)
--    are both unique, so no two profiles can claim the same invite here.
UPDATE public.profiles p
SET    profile_invite_id = pi.id
FROM   public.profile_invites pi
WHERE  pi.email IS NOT NULL
  AND  lower(pi.email) = lower(p.email)
  AND  p.profile_invite_id IS NULL;

-- 4. One profile per invite (the divergent-email fork is a UNIQUE violation,
--    fail-loud, never a silent second profile under the same person).
CREATE UNIQUE INDEX profiles_profile_invite_unique
  ON public.profiles (profile_invite_id)
  WHERE profile_invite_id IS NOT NULL;

-- 5. HR-dashboard view: join profiles to its invite by the canonical FK instead
--    of by email. Column list / order / other joins are unchanged, so this is a
--    valid CREATE OR REPLACE and behaviour-preserving for every email-matched
--    pair (now backfilled).
CREATE OR REPLACE VIEW "public"."profile_invites_with_details" WITH ("security_invoker"='on') AS
 SELECT "pi"."id" AS "invite_id",
    "pi"."email",
    "pi"."status" AS "invite_status",
    "pi"."created_at" AS "invited_at",
    "pi"."company_id",
    "c"."name" AS "company_name",
    "c"."logo_image_path",
    "p"."user_id",
    "p"."status" AS "profile_status",
    "p"."created_at" AS "registered_at",
    "p"."profile_image_path",
    COALESCE("p"."first_name", "pi"."first_name") AS "first_name",
    COALESCE("p"."last_name", "pi"."last_name") AS "last_name",
    COALESCE("p"."description", "pi"."description") AS "description",
    COALESCE("p"."department", "pi"."department") AS "department",
    COALESCE("p"."hire_date", "pi"."hire_date") AS "hire_date",
    "bb"."id" AS "bike_benefit_id",
    "bb"."benefit_status",
    "bb"."contract_status",
    COALESCE("bb"."updated_at", "bo"."updated_at", "p"."created_at", "pi"."created_at") AS "last_modified_at",
    "bb"."bike_id",
    "bo"."id" AS "order_id",
    "pi"."source",
    "pi"."radiat",
    "pi"."derived_email"
   FROM ((((("public"."profile_invites" "pi"
     LEFT JOIN "public"."companies" "c" ON (("pi"."company_id" = "c"."id")))
     LEFT JOIN "public"."profiles" "p" ON (("p"."profile_invite_id" = "pi"."id")))
     LEFT JOIN "public"."bike_benefits" "bb" ON (("p"."user_id" = "bb"."user_id")))
     LEFT JOIN "public"."bikes" "b" ON (("bb"."bike_id" = "b"."id")))
     LEFT JOIN "public"."bike_orders" "bo" ON (("bb"."id" = "bo"."bike_benefit_id")))
  ORDER BY COALESCE("bb"."updated_at", "bo"."updated_at", "p"."created_at", "pi"."created_at") DESC;

-- 6. Registration trigger: set the canonical link, and resolve the invite via
--    derived_email as well as email (REGES/SSO rows whose verified email equals
--    the pattern-derived address). Exact email match is preferred so it always
--    wins over a derived-only match. Invite status is now flipped by id, so a
--    derived-email match (where pi.email may be NULL) is updated correctly.
CREATE OR REPLACE FUNCTION "public"."handle_user_registration"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_company_id  uuid;
  v_first_name  text;
  v_last_name   text;
  v_description text;
  v_department  text;
  v_hire_date   bigint;
  v_invite_id   uuid;
BEGIN
  IF NEW.email_confirmed_at IS NOT NULL THEN

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

  END IF;

  RETURN NEW;
END;
$$;
