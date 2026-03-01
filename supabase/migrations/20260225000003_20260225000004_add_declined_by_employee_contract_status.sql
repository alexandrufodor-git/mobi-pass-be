-- ============================================
-- Add declined_by_employee to contract_status enum
-- ============================================
-- PostgreSQL enums cannot be modified in place — drop and recreate.
-- Pattern: drop dependent view + triggers, cast column to text,
-- drop type, create new type, cast back, recreate everything.
--
-- terminated          → manual only (HR sets directly)
-- declined_by_employee → driven by contract_declined_at timestamp (webhook: signer-declined)
-- ============================================


-- ============================================
-- 1. Drop dependents
-- ============================================
DROP VIEW IF EXISTS public.profile_invites_with_details;
DROP TRIGGER IF EXISTS update_benefit_status_on_change  ON public.bike_benefits;
DROP TRIGGER IF EXISTS update_contract_status_on_change ON public.bike_benefits;


-- ============================================
-- 2. Add contract_declined_at column
-- ============================================
ALTER TABLE public.bike_benefits
  ADD COLUMN IF NOT EXISTS contract_declined_at timestamptz;

COMMENT ON COLUMN public.bike_benefits.contract_declined_at IS
  'Set by webhook when the employee declines the contract (signer-declined event). Drives contract_status → declined_by_employee via trigger.';


-- ============================================
-- 3. Rebuild contract_status enum
-- ============================================
ALTER TABLE public.bike_benefits
  ALTER COLUMN contract_status TYPE text
  USING contract_status::text;

DROP TYPE IF EXISTS public.contract_status;

CREATE TYPE public.contract_status AS ENUM (
  'pending',
  'viewed_by_employee',
  'signed_by_employee',
  'signed_by_employer',
  'approved',
  'terminated',
  'declined_by_employee'
);

COMMENT ON TYPE public.contract_status IS
  'Contract signing workflow status. terminated is set manually by HR. declined_by_employee is set via eSignatures webhook.';

ALTER TABLE public.bike_benefits
  ALTER COLUMN contract_status TYPE public.contract_status
  USING contract_status::public.contract_status;


-- ============================================
-- 4. Update update_contract_status()
--    Add declined_by_employee to priority chain
-- ============================================
CREATE OR REPLACE FUNCTION public.update_contract_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Terminal guard: only terminated is permanent (manual HR action).
  -- declined_by_employee is NOT guarded — a new contract can be re-sent.
  IF TG_OP = 'UPDATE'
     AND OLD.contract_status = 'terminated'::public.contract_status THEN
    RETURN NEW;
  END IF;

  -- Priority chain (highest → lowest)
  IF NEW.contract_declined_at IS NOT NULL THEN
    NEW.contract_status := 'declined_by_employee'::public.contract_status;
  ELSIF NEW.contract_employee_signed_at IS NOT NULL
     AND NEW.contract_employer_signed_at IS NOT NULL
     AND NEW.contract_approved_at        IS NOT NULL THEN
    NEW.contract_status := 'approved'::public.contract_status;
  ELSIF NEW.contract_employer_signed_at IS NOT NULL THEN
    NEW.contract_status := 'signed_by_employer'::public.contract_status;
  ELSIF NEW.contract_employee_signed_at IS NOT NULL THEN
    NEW.contract_status := 'signed_by_employee'::public.contract_status;
  ELSIF NEW.contract_viewed_at IS NOT NULL THEN
    NEW.contract_status := 'viewed_by_employee'::public.contract_status;
  ELSIF NEW.contract_requested_at IS NOT NULL THEN
    NEW.contract_status := 'pending'::public.contract_status;
  ELSE
    NEW.contract_status := NULL;
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================
-- 5. Update update_bike_benefit_status()
--    Final version from 20260220000002 + contract_declined_at added to reset
-- ============================================
CREATE OR REPLACE FUNCTION public.update_bike_benefit_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- HR terminal states: never overwrite automatically
  IF TG_OP = 'UPDATE'
     AND OLD.benefit_status IN (
       'insurance_claim'::public.benefit_status,
       'terminated'::public.benefit_status
     ) THEN
    RETURN NEW;
  END IF;

  -- Snap currency + contract_months only on new benefit creation
  IF TG_OP = 'INSERT' THEN
    SELECT t.currency, t.contract_months
    INTO   NEW.employee_currency, NEW.employee_contract_months
    FROM   public.get_company_terms_for_user(NEW.user_id) t;
  END IF;

  IF NEW.step IS NULL THEN
    NEW.benefit_status := 'inactive'::public.benefit_status;

  ELSIF NEW.step = 'choose_bike'::public.bike_benefit_step THEN
    IF TG_OP = 'UPDATE'
       AND (OLD.step IS NULL OR OLD.step <> 'choose_bike'::public.bike_benefit_step) THEN
      NEW.live_test_whatsapp_sent_at  := NULL;
      NEW.live_test_checked_in_at     := NULL;
      NEW.committed_at                := NULL;
      NEW.contract_requested_at       := NULL;
      NEW.contract_viewed_at          := NULL;
      NEW.contract_employee_signed_at := NULL;
      NEW.contract_employer_signed_at := NULL;
      NEW.contract_approved_at        := NULL;
      NEW.contract_declined_at        := NULL;
      NEW.delivered_at                := NULL;
      NEW.contract_status             := NULL;
      NEW.employee_full_price         := NULL;
      NEW.employee_monthly_price      := NULL;
      NEW.employee_contract_months    := NULL;
      DELETE FROM public.bike_orders WHERE bike_benefit_id = NEW.id;
    END IF;
    NEW.benefit_status := 'searching'::public.benefit_status;

  ELSIF NEW.step = 'book_live_test'::public.bike_benefit_step THEN
    NEW.benefit_status := 'searching'::public.benefit_status;

  ELSIF NEW.step = 'commit_to_bike'::public.bike_benefit_step THEN
    -- Look up current company terms + bike full_price, compute and store prices
    IF NEW.bike_id IS NOT NULL THEN
      SELECT p.employee_price, p.monthly_employee_price, t.contract_months
      INTO   NEW.employee_full_price, NEW.employee_monthly_price, NEW.employee_contract_months
      FROM         public.bikes b
      JOIN         public.get_company_terms_for_user(NEW.user_id) t ON true
      CROSS JOIN LATERAL public.calc_employee_prices(
                   b.full_price, t.monthly_benefit_subsidy, t.contract_months
                 ) p
      WHERE  b.id = NEW.bike_id;
    END IF;

    IF NEW.live_test_whatsapp_sent_at IS NOT NULL THEN
      NEW.benefit_status := 'testing'::public.benefit_status;
    ELSE
      NEW.benefit_status := 'searching'::public.benefit_status;
    END IF;

  ELSIF NEW.step = 'sign_contract'::public.bike_benefit_step THEN
    IF NEW.committed_at IS NOT NULL THEN
      NEW.benefit_status := 'active'::public.benefit_status;
    ELSE
      NEW.benefit_status := COALESCE(OLD.benefit_status, 'searching'::public.benefit_status);
    END IF;

  ELSIF NEW.step = 'pickup_delivery'::public.bike_benefit_step THEN
    NEW.benefit_status := COALESCE(OLD.benefit_status, 'active'::public.benefit_status);

  END IF;

  RETURN NEW;
END;
$$;


-- ============================================
-- 6. Recreate triggers
-- ============================================
CREATE TRIGGER update_benefit_status_on_change
  BEFORE INSERT OR UPDATE ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_bike_benefit_status();

CREATE TRIGGER update_contract_status_on_change
  BEFORE INSERT OR UPDATE ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_contract_status();


-- ============================================
-- 7. Recreate profile_invites_with_details view
--    Current definition from schema.sql
-- ============================================
CREATE OR REPLACE VIEW public.profile_invites_with_details WITH (security_invoker = on) AS
SELECT
  pi.id         AS invite_id,
  pi.email,
  pi.status     AS invite_status,
  pi.created_at AS invited_at,
  pi.company_id,
  c.name        AS company_name,
  p.user_id,
  p.status      AS profile_status,
  p.created_at  AS registered_at,
  COALESCE(p.first_name,  pi.first_name)  AS first_name,
  COALESCE(p.last_name,   pi.last_name)   AS last_name,
  COALESCE(p.description, pi.description) AS description,
  COALESCE(p.department,  pi.department)  AS department,
  COALESCE(p.hire_date,   pi.hire_date)   AS hire_date,
  bb.id              AS bike_benefit_id,
  bb.benefit_status,
  bb.contract_status,
  COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) AS last_modified_at,
  bb.bike_id,
  bo.id AS order_id
FROM public.profile_invites pi
  LEFT JOIN public.companies    c  ON pi.company_id = c.id
  LEFT JOIN public.profiles     p  ON pi.email      = p.email
  LEFT JOIN public.bike_benefits bb ON p.user_id    = bb.user_id
  LEFT JOIN public.bikes         b  ON bb.bike_id   = b.id
  LEFT JOIN public.bike_orders   bo ON bb.id        = bo.bike_benefit_id
ORDER BY COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) DESC;
