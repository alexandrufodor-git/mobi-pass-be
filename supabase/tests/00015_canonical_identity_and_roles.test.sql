SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: canonical identity (Migration A) + multi-role JWT hook (Migration B)
--
-- Migration A — profiles.profile_invite_id:
--   A01: column exists
--   A02: FK profiles_profile_invite_id_fkey exists
--   A03: partial unique index profiles_profile_invite_unique exists
--   A04: trigger sets profile_invite_id on registration (email match)
--   A05: trigger resolves the invite via derived_email (email NULL)
--   A05b: derived-email registration still creates the employee role
--   A06: profile_invites_with_details FK-joins the profile (email path)
--   A06b: view surfaces the profile for an email-NULL (derived) invite —
--         the improvement over the old pi.email = p.email join
--
-- Migration B — custom_access_token_hook:
--   B01/B01b: single-role employee → user_role 'employee', user_roles ["employee"]
--   B02/B03:  hr+employee → highest-priv user_role 'hr', user_roles ["hr","employee"]
--   B04:      admin+employee → user_role 'admin'
--   B05/B06:  no role → user_role JSON null, user_roles []
-- ============================================================

BEGIN;

CREATE TEMP TABLE _fix15 (k text PRIMARY KEY, v uuid) ON COMMIT DROP;

DO $$
DECLARE
  v_co         uuid;
  v_uid_email  uuid := gen_random_uuid();
  v_inv_email  uuid;
  v_email      text := 'pgtap-00015-email@test.local';
  v_uid_deriv  uuid := gen_random_uuid();
  v_inv_deriv  uuid;
  v_deriv      text := 'pgtap-00015-derived@test.local';
  v_uid_multi  uuid := gen_random_uuid();
  v_uid_admin  uuid := gen_random_uuid();
  v_uid_single uuid := gen_random_uuid();
  v_uid_norole uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('canon-co-' || gen_random_uuid()::text, 50.00, 24, 'EUR', 'canon-' || gen_random_uuid()::text || '.test')
  RETURNING id INTO v_co;

  -- ── Email-matched invite + auth user (trigger fired by the UPDATE below) ──
  INSERT INTO public.profile_invites (email, company_id, first_name, last_name)
  VALUES (v_email, v_co, 'Ema', 'Match')
  RETURNING id INTO v_inv_email;

  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    created_at, updated_at, confirmation_token, email_change,
    email_change_token_new, recovery_token
  ) VALUES (
    v_uid_email, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated', v_email, '',
    now(), now(), '', '', '', ''
  );

  -- ── Derived-email invite (email NULL, REGES-style) + auth user ──
  INSERT INTO public.profile_invites (email, derived_email, company_id, source, source_ref_id, first_name, last_name, status)
  VALUES (NULL, v_deriv, v_co, 'reges', 'rf-' || gen_random_uuid()::text, 'Della', 'Rived', 'inactive')
  RETURNING id INTO v_inv_deriv;

  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    created_at, updated_at, confirmation_token, email_change,
    email_change_token_new, recovery_token
  ) VALUES (
    v_uid_deriv, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated', v_deriv, '',
    now(), now(), '', '', '', ''
  );

  -- ── Hook users: email_confirmed_at NULL keeps the registration trigger from
  --    firing, so profiles + user_roles are built manually below. ──
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    created_at, updated_at, confirmation_token, email_change,
    email_change_token_new, recovery_token
  ) VALUES
    (v_uid_multi,  '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'pgtap-00015-multi@test.local',  NULL, now(), now(), '', '', '', ''),
    (v_uid_admin,  '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'pgtap-00015-admin@test.local',  NULL, now(), now(), '', '', '', ''),
    (v_uid_single, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'pgtap-00015-single@test.local', NULL, now(), now(), '', '', '', ''),
    (v_uid_norole, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'pgtap-00015-norole@test.local', NULL, now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name) VALUES
    (v_uid_multi,  'pgtap-00015-multi@test.local',  v_co, 'active', 'Multi', 'Role'),
    (v_uid_admin,  'pgtap-00015-admin@test.local',  v_co, 'active', 'Adam',  'Min'),
    (v_uid_single, 'pgtap-00015-single@test.local', v_co, 'active', 'Sin',   'Gle'),
    (v_uid_norole, 'pgtap-00015-norole@test.local', v_co, 'active', 'No',    'Role');

  -- Two roles per multi/admin user (UNIQUE(user_id, role) permits it).
  INSERT INTO public.user_roles (user_id, role) VALUES
    (v_uid_multi,  'employee'),
    (v_uid_multi,  'hr'),
    (v_uid_admin,  'employee'),
    (v_uid_admin,  'admin'),
    (v_uid_single, 'employee');
  -- v_uid_norole: intentionally no role

  INSERT INTO _fix15 VALUES
    ('co', v_co),
    ('uid_email', v_uid_email),  ('inv_email', v_inv_email),
    ('uid_deriv', v_uid_deriv),  ('inv_deriv', v_inv_deriv),
    ('uid_multi', v_uid_multi),  ('uid_admin', v_uid_admin),
    ('uid_single', v_uid_single),('uid_norole', v_uid_norole);
END $$;

SELECT plan(15);

-- Fire the registration trigger (email_confirmed_at NULL → non-NULL) for the
-- two invite-based users.
UPDATE auth.users
SET email_confirmed_at = now(), encrypted_password = 'hashed'
WHERE id IN ((SELECT v FROM _fix15 WHERE k = 'uid_email'),
             (SELECT v FROM _fix15 WHERE k = 'uid_deriv'));

-- ── A01: column exists ────────────────────────────────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'profiles'
      AND column_name = 'profile_invite_id'
  ),
  'A01: profiles.profile_invite_id column exists'
);

-- ── A02: FK exists ────────────────────────────────────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM pg_constraint
    WHERE conname = 'profiles_profile_invite_id_fkey' AND contype = 'f'
  ),
  'A02: profiles_profile_invite_id_fkey FK exists'
);

-- ── A03: partial unique index exists ──────────────────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'profiles_profile_invite_unique'
  ),
  'A03: profiles_profile_invite_unique partial unique index exists'
);

-- ── A04: trigger set profile_invite_id (email path) ───────────────────────────
SELECT is(
  (SELECT profile_invite_id FROM public.profiles
   WHERE user_id = (SELECT v FROM _fix15 WHERE k = 'uid_email')),
  (SELECT v FROM _fix15 WHERE k = 'inv_email'),
  'A04: trigger set profiles.profile_invite_id to the matched invite (email path)'
);

-- ── A05: trigger resolved the invite via derived_email (email NULL) ───────────
SELECT is(
  (SELECT profile_invite_id FROM public.profiles
   WHERE user_id = (SELECT v FROM _fix15 WHERE k = 'uid_deriv')),
  (SELECT v FROM _fix15 WHERE k = 'inv_deriv'),
  'A05: trigger resolved invite via derived_email and linked profile_invite_id'
);

-- ── A05b: derived-email registration still created the employee role ──────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM public.user_roles
    WHERE user_id = (SELECT v FROM _fix15 WHERE k = 'uid_deriv')
      AND role = 'employee'
  ),
  'A05b: derived-email registration created the employee role'
);

-- ── A06: view FK-joins the profile (email path) ───────────────────────────────
SELECT is(
  (SELECT user_id FROM public.profile_invites_with_details
   WHERE invite_id = (SELECT v FROM _fix15 WHERE k = 'inv_email')),
  (SELECT v FROM _fix15 WHERE k = 'uid_email'),
  'A06: profile_invites_with_details FK-joins profile to invite (email path)'
);

-- ── A06b: view surfaces the profile for an email-NULL (derived) invite ────────
SELECT is(
  (SELECT user_id FROM public.profile_invites_with_details
   WHERE invite_id = (SELECT v FROM _fix15 WHERE k = 'inv_deriv')),
  (SELECT v FROM _fix15 WHERE k = 'uid_deriv'),
  'A06b: view FK-joins profile to an email-NULL (derived) invite'
);

-- ── B01: single-role user → user_role employee ────────────────────────────────
SELECT is(
  (public.custom_access_token_hook(
     jsonb_build_object('user_id', (SELECT v FROM _fix15 WHERE k = 'uid_single'), 'claims', '{}'::jsonb)
   ) -> 'claims' ->> 'user_role'),
  'employee',
  'B01: single-role user → user_role employee'
);

-- ── B01b: single-role user → user_roles ["employee"] ──────────────────────────
SELECT is(
  (public.custom_access_token_hook(
     jsonb_build_object('user_id', (SELECT v FROM _fix15 WHERE k = 'uid_single'), 'claims', '{}'::jsonb)
   ) -> 'claims' -> 'user_roles'),
  '["employee"]'::jsonb,
  'B01b: single-role user → user_roles ["employee"]'
);

-- ── B02: hr+employee → highest-priv user_role hr ──────────────────────────────
SELECT is(
  (public.custom_access_token_hook(
     jsonb_build_object('user_id', (SELECT v FROM _fix15 WHERE k = 'uid_multi'), 'claims', '{}'::jsonb)
   ) -> 'claims' ->> 'user_role'),
  'hr',
  'B02: hr+employee → highest-privilege user_role hr'
);

-- ── B03: hr+employee → user_roles ["hr","employee"] (priv-ordered) ────────────
SELECT is(
  (public.custom_access_token_hook(
     jsonb_build_object('user_id', (SELECT v FROM _fix15 WHERE k = 'uid_multi'), 'claims', '{}'::jsonb)
   ) -> 'claims' -> 'user_roles'),
  '["hr","employee"]'::jsonb,
  'B03: hr+employee → user_roles ["hr","employee"] (priv-ordered)'
);

-- ── B04: admin+employee → highest-priv user_role admin ────────────────────────
SELECT is(
  (public.custom_access_token_hook(
     jsonb_build_object('user_id', (SELECT v FROM _fix15 WHERE k = 'uid_admin'), 'claims', '{}'::jsonb)
   ) -> 'claims' ->> 'user_role'),
  'admin',
  'B04: admin+employee → highest-privilege user_role admin'
);

-- ── B05: no-role user → user_role JSON null ───────────────────────────────────
SELECT is(
  (public.custom_access_token_hook(
     jsonb_build_object('user_id', (SELECT v FROM _fix15 WHERE k = 'uid_norole'), 'claims', '{}'::jsonb)
   ) -> 'claims' -> 'user_role'),
  'null'::jsonb,
  'B05: no-role user → user_role JSON null'
);

-- ── B06: no-role user → user_roles [] ─────────────────────────────────────────
SELECT is(
  (public.custom_access_token_hook(
     jsonb_build_object('user_id', (SELECT v FROM _fix15 WHERE k = 'uid_norole'), 'claims', '{}'::jsonb)
   ) -> 'claims' -> 'user_roles'),
  '[]'::jsonb,
  'B06: no-role user → user_roles []'
);

SELECT * FROM finish();
ROLLBACK;
