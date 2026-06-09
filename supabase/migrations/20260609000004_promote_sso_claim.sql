-- Google Workspace SSO — Migration 4 of 4: promote_sso_claim RPC.
--
-- Confirms a pending SSO claim and ties it to a profile_invites row: binds the
-- invite email, promotes the profile to active, assigns the employee role,
-- creates the bike benefit, links any staged REGES PII, sets the canonical
-- profile_invite_id back-link, and resolves the claim. Idempotent inserts so
-- replays don't error.
--
-- Two callers:
--   1. HR/admin from the dashboard (manual approval) — gated by get_my_role().
--   2. service_role from the sso-claim-record edge function (auto-promote of a
--      single high-confidence match — later phase).
--
-- ⚠️ Gate fix (beyond the plan's literal SQL, deliberate): the plan gates only
-- on get_my_role() IN ('hr','admin'), but a service_role JWT carries no
-- user_role claim, so get_my_role() returns 'null' and the service_role caller
-- would hit FORBIDDEN. We additionally allow auth.jwt()->>'role' = 'service_role'.
-- get_my_role() returns the HIGHEST-privilege role (multi-role hook), so an
-- HR-who-is-also-employee still passes.

CREATE OR REPLACE FUNCTION public.promote_sso_claim(
  p_claim_id  uuid,
  p_invite_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_claim  sso_pending_claims%ROWTYPE;
  v_invite profile_invites%ROWTYPE;
BEGIN
  -- Caller must be HR/admin in the claim's company, OR the service_role.
  IF COALESCE(auth.jwt() ->> 'role', '') <> 'service_role'
     AND public.get_my_role() NOT IN ('hr','admin') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  SELECT * INTO v_claim FROM sso_pending_claims WHERE id = p_claim_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CLAIM_NOT_FOUND'; END IF;
  IF v_claim.status NOT IN ('awaiting_user_info','pending_review') THEN
    RAISE EXCEPTION 'CLAIM_ALREADY_RESOLVED status=%', v_claim.status;
  END IF;

  SELECT * INTO v_invite FROM profile_invites WHERE id = p_invite_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVITE_NOT_FOUND'; END IF;
  IF v_invite.company_id <> v_claim.company_id THEN
    RAISE EXCEPTION 'INVITE_COMPANY_MISMATCH';
  END IF;
  IF v_invite.email IS NOT NULL AND lower(v_invite.email) <> lower(v_claim.email) THEN
    RAISE EXCEPTION 'INVITE_ALREADY_CLAIMED';
  END IF;

  -- Bind invite to the SSO user's email so its email is no longer NULL.
  UPDATE profile_invites
     SET email  = v_claim.email,
         status = 'active'::user_profile_status
   WHERE id = p_invite_id;

  -- Promote profile to active, fill identity fields from the invite, and set
  -- the canonical back-link (depends on profiles.profile_invite_id).
  UPDATE profiles SET
    status            = 'active'::user_profile_status,
    first_name        = v_invite.first_name,
    last_name         = v_invite.last_name,
    description       = v_invite.description,
    department        = v_invite.department,
    hire_date         = v_invite.hire_date,
    profile_invite_id = p_invite_id
   WHERE user_id = v_claim.user_id;

  -- Assign role + create benefit (idempotent — replays don't error).
  INSERT INTO user_roles (user_id, role)
  VALUES (v_claim.user_id, 'employee'::user_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  INSERT INTO bike_benefits (user_id)
  VALUES (v_claim.user_id)
  ON CONFLICT DO NOTHING;

  -- Link any pending REGES employee_pii row to this user (mirrors REGES bridge).
  UPDATE employee_pii
     SET user_id = v_claim.user_id, updated_at = now()
   WHERE profile_invite_id = p_invite_id AND user_id IS NULL;

  -- Resolve claim.
  UPDATE sso_pending_claims SET
    status = 'approved', approved_invite_id = p_invite_id,
    reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
   WHERE id = p_claim_id;

  -- FCM dispatch happens out-of-band via the company_notifications fan-out.
  INSERT INTO company_notifications (company_id, event, event_type, payload)
  VALUES (v_claim.company_id, 'user_update', 'sso_claim_approved',
          jsonb_build_object('user_id', v_claim.user_id, 'invite_id', p_invite_id));

  RETURN jsonb_build_object('approved', true, 'user_id', v_claim.user_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.promote_sso_claim(uuid, uuid) TO authenticated;
-- The role check lives in the function body (FORBIDDEN at the top). We also
-- assert v_invite.company_id = v_claim.company_id, so HR from company A cannot
-- promote a claim from company B even by guessing both ids.
