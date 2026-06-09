SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: Google Workspace SSO bridge (migrations 20260609000001-04)
--
-- Trigger Google branch (handle_user_registration):
--   G01: email-matched invite      → active, employee role, benefit, link set
--   G02: derived_email-matched      → active + invite.email backfilled to NEW.email
--   G03: no match                   → pending_sso_claim, claim row, NO role/benefit/link
--   G04: domain not google_oidc     → RAISE SSO_DOMAIN_NOT_AUTHORIZED
--   G05: hd required + hd missing    → RAISE SSO_HD_REQUIRED
--   G06: hd present but ≠ email dom   → RAISE SSO_HD_EMAIL_MISMATCH
--   G07: password user (regression)  → still active + profile_invite_id set
--
-- promote_sso_claim:
--   P01: HR approves a pending claim → active, role, benefit, claim approved, link
--   P02: service_role auto-promote    → approved (the gate fix)
--   P03: employee caller              → FORBIDDEN
--   P04: re-promote resolved claim    → CLAIM_ALREADY_RESOLVED
--   P05: invite from another company  → INVITE_COMPANY_MISMATCH
--
-- Fixed domains (rolled back, no seed collision):
--   ssoco.test (google_oidc, hd_required), nonessoco.test (sso_kind none),
--   otherdom.test (no company).
-- ============================================================

BEGIN;

-- Helper: simulate a Google OAuth signup. Mirrors how GoTrue inserts an OAuth
-- user — email pre-confirmed, NO password, provider=google in app metadata,
-- hd in user metadata. The INSERT fires on_auth_user_created.
CREATE OR REPLACE FUNCTION _sso_google_user(p_uid uuid, p_email text, p_hd text)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token,
    raw_user_meta_data, raw_app_meta_data
  ) VALUES (
    p_uid, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated', p_email, NULL,
    now(), now(), now(), '', '', '', '',
    jsonb_strip_nulls(jsonb_build_object(
      'hd', p_hd, 'email', p_email,
      'given_name', 'Goog', 'family_name', 'User', 'name', 'Goog User')),
    '{"provider":"google","providers":["google"]}'::jsonb
  );
END $fn$;

CREATE TEMP TABLE _fix16 (k text PRIMARY KEY, v uuid) ON COMMIT DROP;

DO $$
DECLARE
  v_co_sso  uuid;
  v_co_none uuid;
  v_inv_email  uuid;
  v_inv_deriv  uuid;
  v_inv_pw     uuid;
  v_inv_a      uuid;
  v_inv_b      uuid;
  v_inv_other  uuid;
  v_hr_uid     uuid := gen_random_uuid();
  v_u_cla      uuid := gen_random_uuid();
  v_u_clb      uuid := gen_random_uuid();
BEGIN
  -- Companies
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain, sso_kind, sso_hd_required)
  VALUES ('sso-co', 50.00, 24, 'EUR', 'ssoco.test', 'google_oidc', true)
  RETURNING id INTO v_co_sso;

  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain, sso_kind)
  VALUES ('none-co', 50.00, 24, 'EUR', 'nonessoco.test', 'none')
  RETURNING id INTO v_co_none;

  -- Invites in the SSO company
  INSERT INTO public.profile_invites (email, company_id, first_name, last_name)
  VALUES ('ematch@ssoco.test', v_co_sso, 'Ema', 'Match') RETURNING id INTO v_inv_email;

  INSERT INTO public.profile_invites (email, derived_email, company_id, source, first_name, last_name, status)
  VALUES (NULL, 'ederiv@ssoco.test', v_co_sso, 'reges', 'Della', 'Rived', 'inactive') RETURNING id INTO v_inv_deriv;

  INSERT INTO public.profile_invites (email, company_id, first_name, last_name)
  VALUES ('pwuser@ssoco.test', v_co_sso, 'Pass', 'Word') RETURNING id INTO v_inv_pw;

  -- Bindable invites for promote (email NULL — HR-created stub the claim binds to)
  INSERT INTO public.profile_invites (email, company_id, first_name, last_name)
  VALUES (NULL, v_co_sso, 'Claim', 'Aaa') RETURNING id INTO v_inv_a;
  INSERT INTO public.profile_invites (email, company_id, first_name, last_name)
  VALUES (NULL, v_co_sso, 'Claim', 'Bbb') RETURNING id INTO v_inv_b;

  -- Invite in the OTHER company (for the company-mismatch test)
  INSERT INTO public.profile_invites (email, company_id, first_name, last_name)
  VALUES (NULL, v_co_none, 'Other', 'Co') RETURNING id INTO v_inv_other;

  -- HR user: provider=email + encrypted_password NULL → trigger skips. Profile
  -- + hr role built by hand (reviewed_by FK target).
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token,
    raw_user_meta_data, raw_app_meta_data
  ) VALUES (
    v_hr_uid, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated', 'hr@ssoco.test', NULL,
    now(), now(), now(), '', '', '', '',
    '{}', '{"provider":"email","providers":["email"]}'
  );
  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES (v_hr_uid, 'hr@ssoco.test', v_co_sso, 'active', 'Hen', 'Ree');
  INSERT INTO public.user_roles (user_id, role) VALUES (v_hr_uid, 'hr');

  -- Google signups that SUCCEED (fire the trigger now, asserted after plan):
  PERFORM _sso_google_user(gen_random_uuid(), 'ematch@ssoco.test', 'ssoco.test'); -- G01
  PERFORM _sso_google_user(gen_random_uuid(), 'ederiv@ssoco.test', 'ssoco.test'); -- G02
  PERFORM _sso_google_user(gen_random_uuid(), 'nomatch@ssoco.test', 'ssoco.test');-- G03
  PERFORM _sso_google_user(v_u_cla, 'cla@ssoco.test', 'ssoco.test');              -- → pending claim (P01/P04)
  PERFORM _sso_google_user(v_u_clb, 'clb@ssoco.test', 'ssoco.test');              -- → pending claim (P02/P03/P05)

  -- G07: password/email user with a matching invite (regression).
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token,
    raw_user_meta_data, raw_app_meta_data
  ) VALUES (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated', 'pwuser@ssoco.test', 'hashed',
    now(), now(), now(), '', '', '', '',
    '{}', '{"provider":"email","providers":["email"]}'
  );

  INSERT INTO _fix16 VALUES
    ('co_sso', v_co_sso), ('co_none', v_co_none),
    ('inv_email', v_inv_email), ('inv_deriv', v_inv_deriv), ('inv_pw', v_inv_pw),
    ('inv_a', v_inv_a), ('inv_b', v_inv_b), ('inv_other', v_inv_other),
    ('hr_uid', v_hr_uid), ('u_cla', v_u_cla), ('u_clb', v_u_clb);
END $$;

SELECT plan(27);

-- ── G01: email-matched Google user ───────────────────────────────────────────
SELECT is((SELECT status::text FROM profiles WHERE email='ematch@ssoco.test'),
          'active', 'G01: email match → profile active');
SELECT is((SELECT profile_invite_id FROM profiles WHERE email='ematch@ssoco.test'),
          (SELECT v FROM _fix16 WHERE k='inv_email'), 'G01: canonical profile_invite_id set');
SELECT ok(EXISTS(SELECT 1 FROM user_roles ur JOIN profiles p ON p.user_id=ur.user_id
                 WHERE p.email='ematch@ssoco.test' AND ur.role='employee'),
          'G01: employee role assigned');
SELECT ok(EXISTS(SELECT 1 FROM bike_benefits bb JOIN profiles p ON p.user_id=bb.user_id
                 WHERE p.email='ematch@ssoco.test'),
          'G01: bike_benefit created');

-- ── G02: derived_email-matched Google user ───────────────────────────────────
SELECT is((SELECT status::text FROM profiles WHERE email='ederiv@ssoco.test'),
          'active', 'G02: derived_email match → profile active');
SELECT is((SELECT profile_invite_id FROM profiles WHERE email='ederiv@ssoco.test'),
          (SELECT v FROM _fix16 WHERE k='inv_deriv'), 'G02: profile_invite_id set');
SELECT is((SELECT email FROM profile_invites WHERE id=(SELECT v FROM _fix16 WHERE k='inv_deriv')),
          'ederiv@ssoco.test', 'G02: invite.email backfilled to verified Google email');

-- ── G03: no-match Google user → pending claim ────────────────────────────────
SELECT is((SELECT status::text FROM profiles WHERE email='nomatch@ssoco.test'),
          'pending_sso_claim', 'G03: no match → pending_sso_claim');
SELECT ok(EXISTS(SELECT 1 FROM sso_pending_claims c JOIN profiles p ON p.user_id=c.user_id
                 WHERE p.email='nomatch@ssoco.test' AND c.status='awaiting_user_info'),
          'G03: sso_pending_claims row created');
SELECT ok(NOT EXISTS(SELECT 1 FROM user_roles ur JOIN profiles p ON p.user_id=ur.user_id
                     WHERE p.email='nomatch@ssoco.test'),
          'G03: no role assigned');
SELECT is((SELECT profile_invite_id FROM profiles WHERE email='nomatch@ssoco.test'),
          NULL, 'G03: no canonical link');
SELECT is((SELECT first_name FROM profiles WHERE email='nomatch@ssoco.test'),
          'Goog', 'G03: pending profile takes given_name from Google claims');

-- ── G07: password user (regression) ──────────────────────────────────────────
SELECT is((SELECT status::text FROM profiles WHERE email='pwuser@ssoco.test'),
          'active', 'G07: password user still onboards');
SELECT isnt((SELECT profile_invite_id FROM profiles WHERE email='pwuser@ssoco.test'),
            NULL, 'G07: password user profile_invite_id set');

-- ── G04-G06: failure modes raise ─────────────────────────────────────────────
SELECT throws_like(
  $$ SELECT _sso_google_user(gen_random_uuid(), 'x@nonessoco.test', 'nonessoco.test') $$,
  '%SSO_DOMAIN_NOT_AUTHORIZED%', 'G04: non-google_oidc domain → SSO_DOMAIN_NOT_AUTHORIZED');
SELECT throws_like(
  $$ SELECT _sso_google_user(gen_random_uuid(), 'x@ssoco.test', NULL) $$,
  '%SSO_HD_REQUIRED%', 'G05: hd required but missing → SSO_HD_REQUIRED');
SELECT throws_like(
  $$ SELECT _sso_google_user(gen_random_uuid(), 'x@otherdom.test', 'ssoco.test') $$,
  '%SSO_HD_EMAIL_MISMATCH%', 'G06: hd ≠ email domain → SSO_HD_EMAIL_MISMATCH');

-- ── P01 + P04: HR approves, then re-approve is rejected ──────────────────────
SELECT set_config('request.jwt.claims',
  json_build_object('sub', (SELECT v FROM _fix16 WHERE k='hr_uid'),
                    'role', 'authenticated', 'user_role', 'hr')::text, true);

SELECT lives_ok(
  $$ SELECT promote_sso_claim(
       (SELECT id FROM sso_pending_claims WHERE user_id=(SELECT v FROM _fix16 WHERE k='u_cla')),
       (SELECT v FROM _fix16 WHERE k='inv_a')) $$,
  'P01: HR promotes pending claim → lives');
SELECT is((SELECT status::text FROM profiles WHERE user_id=(SELECT v FROM _fix16 WHERE k='u_cla')),
          'active', 'P01: profile promoted to active');
SELECT ok(EXISTS(SELECT 1 FROM user_roles WHERE user_id=(SELECT v FROM _fix16 WHERE k='u_cla') AND role='employee'),
          'P01: employee role assigned');
SELECT is((SELECT status FROM sso_pending_claims WHERE user_id=(SELECT v FROM _fix16 WHERE k='u_cla')),
          'approved', 'P01: claim marked approved');
SELECT is((SELECT profile_invite_id FROM profiles WHERE user_id=(SELECT v FROM _fix16 WHERE k='u_cla')),
          (SELECT v FROM _fix16 WHERE k='inv_a'), 'P01: canonical link set to invite');

SELECT throws_like(
  $$ SELECT promote_sso_claim(
       (SELECT id FROM sso_pending_claims WHERE user_id=(SELECT v FROM _fix16 WHERE k='u_cla')),
       (SELECT v FROM _fix16 WHERE k='inv_a')) $$,
  '%CLAIM_ALREADY_RESOLVED%', 'P04: re-promoting a resolved claim → rejected');

-- ── P03: employee caller is forbidden ────────────────────────────────────────
SELECT set_config('request.jwt.claims',
  json_build_object('sub', (SELECT v FROM _fix16 WHERE k='hr_uid'),
                    'role', 'authenticated', 'user_role', 'employee')::text, true);
SELECT throws_like(
  $$ SELECT promote_sso_claim(
       (SELECT id FROM sso_pending_claims WHERE user_id=(SELECT v FROM _fix16 WHERE k='u_clb')),
       (SELECT v FROM _fix16 WHERE k='inv_b')) $$,
  '%FORBIDDEN%', 'P03: employee caller → FORBIDDEN');

-- ── P05: invite from another company is rejected ─────────────────────────────
SELECT set_config('request.jwt.claims',
  json_build_object('sub', (SELECT v FROM _fix16 WHERE k='hr_uid'),
                    'role', 'authenticated', 'user_role', 'hr')::text, true);
SELECT throws_like(
  $$ SELECT promote_sso_claim(
       (SELECT id FROM sso_pending_claims WHERE user_id=(SELECT v FROM _fix16 WHERE k='u_clb')),
       (SELECT v FROM _fix16 WHERE k='inv_other')) $$,
  '%INVITE_COMPANY_MISMATCH%', 'P05: invite from another company → rejected');

-- ── P02: service_role auto-promote (the gate fix) ────────────────────────────
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SELECT lives_ok(
  $$ SELECT promote_sso_claim(
       (SELECT id FROM sso_pending_claims WHERE user_id=(SELECT v FROM _fix16 WHERE k='u_clb')),
       (SELECT v FROM _fix16 WHERE k='inv_b')) $$,
  'P02: service_role promotes claim → lives');
SELECT is((SELECT status FROM sso_pending_claims WHERE user_id=(SELECT v FROM _fix16 WHERE k='u_clb')),
          'approved', 'P02: claim marked approved by service_role');

SELECT * FROM finish();
ROLLBACK;
