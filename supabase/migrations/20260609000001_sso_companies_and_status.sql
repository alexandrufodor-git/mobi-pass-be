-- Google Workspace SSO — Migration 1 of 4: company SSO config + profile status.
--
-- Plan: llm-agent-assist/plans/google-sso-workspace-bridge.md (§Schema Changes).
-- Builds on the REGES bridge (companies.email_domain, already NOT NULL) and the
-- Canonical Identity ADR (profiles.profile_invite_id, shipped 20260608000001).
--
-- The sso_kind enum is generalized up front (ADR §5) so Microsoft / SAML become
-- a config value + a trigger branch later, NOT a schema re-model. Only
-- 'google_oidc' is implemented in this PR.
--
-- NOTE: 'pending_sso_claim' is added to user_profile_status here but first USED
-- in Migration 3 (a separate migration = separate transaction), satisfying
-- Postgres's "an enum value added by ALTER TYPE cannot be used in the same
-- transaction" rule.

-- 1. New profile status for an SSO user who authenticated but has no matching
--    invite yet (awaiting the name/DOB claim flow or HR review).
ALTER TYPE public.user_profile_status ADD VALUE IF NOT EXISTS 'pending_sso_claim';

-- 2. Per-tenant SSO configuration on companies. email_domain already exists
--    (REGES bridge) and routes a sign-in to its company.
ALTER TABLE public.companies
  ADD COLUMN sso_kind text NOT NULL DEFAULT 'none'
    CHECK (sso_kind IN ('none', 'google_oidc', 'microsoft_oidc', 'saml')),
  ADD COLUMN sso_hd_required boolean NOT NULL DEFAULT true,
  ADD COLUMN sso_config jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.companies.sso_kind IS
  'SSO method for this tenant. "none" = email+password only. "google_oidc" = Google Workspace via OAuth (implemented). "microsoft_oidc"/"saml" reserved (ADR §5) — config + trigger branch, no re-model.';
COMMENT ON COLUMN public.companies.sso_hd_required IS
  'When true, the Google ID token "hd" claim must be present and equal email_domain. Set false ONLY for testing / Workspace-less Google accounts. (Microsoft will use sso_config.tenant_id instead.)';
COMMENT ON COLUMN public.companies.sso_config IS
  'Provider-specific config. Microsoft-ready keys: { tenant_id?, issuer?, email_claim?, attribute_map?, client_id_override? }. Company resolution = tenant assertion first (tid/issuer), email_domain second. Empty {} = defaults.';

-- 3. Lookup index for the trigger's company-by-domain resolution, scoped to
--    SSO-enabled tenants only.
CREATE INDEX idx_companies_email_domain_sso
  ON public.companies (lower(email_domain), sso_kind)
  WHERE email_domain IS NOT NULL AND sso_kind != 'none';
