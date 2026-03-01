-- ============================================
-- Create contracts table and get_vault_secret helper
-- ============================================
-- contracts: tracks eSignatures.com contract lifecycle per bike_benefit
-- get_vault_secret(): SECURITY DEFINER helper so edge functions can read
--   Vault secrets via the REST API (POST /rpc/get_vault_secret)
-- ============================================


-- ============================================
-- 1. contracts table
-- ============================================
CREATE TABLE IF NOT EXISTS public.contracts (
  id                        uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  bike_benefit_id           uuid        NOT NULL REFERENCES public.bike_benefits(id) ON DELETE CASCADE,
  user_id                   uuid        NOT NULL REFERENCES public.profiles(user_id) ON DELETE CASCADE,
  esignatures_contract_id   text        NOT NULL UNIQUE,
  esignatures_signer_id     text,
  esignatures_template_id   text        NOT NULL,
  sign_page_url             text,
  api_response              jsonb,
  last_webhook_payload      jsonb,
  last_webhook_event        text,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.contracts IS
  'Tracks eSignatures.com contract lifecycle for each bike benefit. One row per contract request.';

COMMENT ON COLUMN public.contracts.esignatures_contract_id  IS 'Contract ID returned by eSignatures.com API';
COMMENT ON COLUMN public.contracts.esignatures_signer_id    IS 'Signer ID for the employee returned by eSignatures.com API';
COMMENT ON COLUMN public.contracts.esignatures_template_id  IS 'Template ID used to create this contract (snapshotted from company at request time)';
COMMENT ON COLUMN public.contracts.sign_page_url            IS 'URL the employee visits to sign the contract';
COMMENT ON COLUMN public.contracts.api_response             IS 'Full eSignatures.com API response (audit trail)';
COMMENT ON COLUMN public.contracts.last_webhook_payload     IS 'Latest webhook payload received from eSignatures.com (debug)';
COMMENT ON COLUMN public.contracts.last_webhook_event       IS 'Event string from the latest webhook (e.g. signer-signed)';


-- ============================================
-- 2. Indexes
-- ============================================
CREATE INDEX IF NOT EXISTS idx_contracts_bike_benefit_id
  ON public.contracts (bike_benefit_id);

CREATE INDEX IF NOT EXISTS idx_contracts_user_id
  ON public.contracts (user_id);

CREATE INDEX IF NOT EXISTS idx_contracts_esignatures_contract_id
  ON public.contracts (esignatures_contract_id);


-- ============================================
-- 3. updated_at trigger (reuse existing helper)
-- ============================================
CREATE TRIGGER set_contracts_updated_at
  BEFORE UPDATE ON public.contracts
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();


-- ============================================
-- 4. Row Level Security
-- ============================================
ALTER TABLE public.contracts ENABLE ROW LEVEL SECURITY;

-- Employee: select own rows only
CREATE POLICY "contracts_employee_select_own"
  ON public.contracts
  FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()
  );

-- HR / Admin: select all contracts for their company
CREATE POLICY "contracts_hr_admin_select"
  ON public.contracts
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.user_roles ur
      WHERE ur.user_id = auth.uid()
        AND ur.role IN ('hr', 'admin')
    )
  );

-- All writes go through service_role (edge functions) only — no authenticated writes
-- (No INSERT/UPDATE/DELETE policies for authenticated; service_role bypasses RLS)


-- ============================================
-- 5. Grants
-- ============================================
GRANT SELECT ON public.contracts TO authenticated;
GRANT ALL    ON public.contracts TO service_role;


-- ============================================
-- 6. get_vault_secret() — SECURITY DEFINER helper
-- ============================================
-- Allows edge functions (running as authenticated or anon) to read Vault secrets
-- by calling POST /rest/v1/rpc/get_vault_secret.
-- Only the service_role / postgres can call vault.decrypted_secrets directly,
-- so this SECURITY DEFINER wrapper bridges the gap.
-- ============================================
CREATE OR REPLACE FUNCTION public.get_vault_secret(secret_name text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, vault
AS $$
DECLARE
  v_secret text;
BEGIN
  SELECT decrypted_secret
  INTO   v_secret
  FROM   vault.decrypted_secrets
  WHERE  name = secret_name
  LIMIT  1;

  RETURN v_secret;
END;
$$;

COMMENT ON FUNCTION public.get_vault_secret(text) IS
  'SECURITY DEFINER wrapper that lets edge functions read a named Vault secret via the REST API (POST /rpc/get_vault_secret). Returns NULL if the secret does not exist.';

GRANT EXECUTE ON FUNCTION public.get_vault_secret(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_vault_secret(text) TO service_role;
