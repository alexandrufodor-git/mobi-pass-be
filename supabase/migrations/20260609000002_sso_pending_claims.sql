-- Google Workspace SSO — Migration 2 of 4: sso_pending_claims review queue.
--
-- An SSO user who authenticates but matches no profile_invites row lands here
-- (status 'pending_sso_claim' on profiles). A dedicated table keeps
-- profile_invites focused on HR-provisioned identities and gives HR a clean
-- review queue. Encrypted DOB lives here, not on profiles, so it never widens
-- the profile read surface. Rows are populated server-side (the trigger in
-- Migration 3, then the sso-claim-record edge function in a later phase).

CREATE TABLE public.sso_pending_claims (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                  uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  company_id               uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  email                    text NOT NULL,                 -- Google email exactly as returned
  hd                       text,                          -- Google hd claim, captured for audit
  first_name               text,                          -- filled when the user submits the claim form
  last_name                text,
  date_of_birth_encrypted  text,                          -- 'enc:v1:...' (piiCrypto.encrypt)
  birth_date_hash          text,                          -- HMAC blind index, matches REGES rows
  suggested_invite_ids     uuid[] NOT NULL DEFAULT '{}',  -- match_pending_invite output, ordered by score
  suggested_scores         jsonb NOT NULL DEFAULT '[]'::jsonb,
  status                   text NOT NULL DEFAULT 'awaiting_user_info'
                              CHECK (status IN ('awaiting_user_info','pending_review','approved','rejected','expired')),
  reviewed_by              uuid REFERENCES public.profiles(user_id),
  reviewed_at              timestamptz,
  approved_invite_id       uuid REFERENCES public.profile_invites(id),
  rejected_reason          text,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.sso_pending_claims IS
  'Review queue for SSO users with no matching profile_invites row. One active row per user (partial unique). Resolved by promote_sso_claim (Migration 4).';

-- At most one active claim per user.
CREATE UNIQUE INDEX sso_pending_claims_user_active
  ON public.sso_pending_claims (user_id)
  WHERE status IN ('awaiting_user_info','pending_review');

-- HR dashboard queue lookup.
CREATE INDEX idx_sso_pending_claims_company_status
  ON public.sso_pending_claims (company_id, status)
  WHERE status IN ('awaiting_user_info','pending_review');

ALTER TABLE public.sso_pending_claims ENABLE ROW LEVEL SECURITY;

-- A user can read their own claim row (mobile polls it / get-employee-details surfaces it).
CREATE POLICY "user reads own sso_pending_claim"
  ON public.sso_pending_claims FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- HR/admin manage claims in their own company. get_my_role() returns the
-- highest-privilege role (multi-role hook), so an HR-who-is-also-employee
-- still passes here.
CREATE POLICY "hr manages sso_pending_claims in own company"
  ON public.sso_pending_claims FOR ALL TO authenticated
  USING (public.get_my_role() IN ('hr','admin')
         AND company_id = public.auth_company_id())
  WITH CHECK (public.get_my_role() IN ('hr','admin')
              AND company_id = public.auth_company_id());

-- Inserts come from service_role (the registration trigger / edge functions),
-- which bypasses RLS — no INSERT policy for authenticated users by design.
