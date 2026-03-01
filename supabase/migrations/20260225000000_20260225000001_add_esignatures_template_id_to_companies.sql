-- ============================================
-- Add esignatures_template_id to companies
-- ============================================
-- Stores the eSignatures.com template ID used to generate
-- contracts for employees of this company. Nullable — added
-- after company creation when the template is configured.
-- ============================================

ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS esignatures_template_id text;

COMMENT ON COLUMN public.companies.esignatures_template_id IS
  'eSignatures.com template ID used to generate bike benefit contracts for employees of this company. Must be set before send-contract can be called.';
