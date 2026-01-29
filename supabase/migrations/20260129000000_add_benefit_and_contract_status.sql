-- ============================================
-- Add Benefit Status and Contract Status to bike_benefits
-- ============================================
-- This migration adds two new status tracking fields:
-- 1. benefit_status - Tracks the overall status of the bike benefit for HR dashboard
-- 2. contract_status - Tracks the contract signing workflow
--
-- benefit_status is auto-updated via triggers based on step and timestamp fields
-- contract_status is primarily manually updated, with some automatic transitions
-- ============================================

-- ============================================
-- 1. Create benefit_status enum
-- ============================================
CREATE TYPE public.benefit_status AS ENUM (
  'inactive',           -- Default when benefit is created
  'searching',          -- When employee starts choosing a bike (step = 'choose_bike')
  'testing',            -- When live test is booked and WhatsApp sent (step = 'book_live_test' AND live_test_whatsapp_sent_at IS NOT NULL)
  'active',             -- When bike is delivered (step = 'pickup_delivery' AND delivered_at IS NOT NULL)
  'insurance_claim',    -- Manually set by HR when insurance claim is filed
  'terminated'          -- Manually set by HR when benefit is terminated
);

COMMENT ON TYPE public.benefit_status IS 'Benefit status for HR dashboard view. Auto-updated by triggers based on step and timestamps. NULL when step is NULL (benefit not yet started).';

-- ============================================
-- 2. Create contract_status enum
-- ============================================
CREATE TYPE public.contract_status AS ENUM (
  'not_started',            -- Default - contract not yet generated
  'viewed_by_employee',     -- Employee has opened/viewed the contract
  'signed_by_employee',     -- Employee has signed the contract
  'signed_by_employer',     -- Employer has signed the contract (after employee)
  'approved',               -- Both parties have signed - contract is fully executed
  'terminated'              -- Contract is terminated by HR
);

COMMENT ON TYPE public.contract_status IS 'Contract signing workflow status. Tracks progression from viewing to final approval.';

-- ============================================
-- 3. Add new status columns to bike_benefits table
-- ============================================
ALTER TABLE public.bike_benefits
  ADD COLUMN IF NOT EXISTS benefit_status public.benefit_status,
  ADD COLUMN IF NOT EXISTS contract_status public.contract_status DEFAULT 'not_started' NOT NULL,
  
  -- Add contract tracking timestamp fields
  ADD COLUMN IF NOT EXISTS contract_viewed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS contract_employee_signed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS contract_employer_signed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS contract_approved_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS contract_terminated_at TIMESTAMPTZ,
  
  -- Add benefit status change tracking
  ADD COLUMN IF NOT EXISTS benefit_terminated_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS benefit_insurance_claim_at TIMESTAMPTZ;

COMMENT ON COLUMN public.bike_benefits.benefit_status IS 'Overall benefit status for HR view. Auto-updated by triggers. NULL when employee has not started the benefit process yet.';
COMMENT ON COLUMN public.bike_benefits.contract_status IS 'Contract signing workflow status. Updated manually or via triggers.';
COMMENT ON COLUMN public.bike_benefits.contract_viewed_at IS 'Timestamp when employee first viewed the contract';
COMMENT ON COLUMN public.bike_benefits.contract_employee_signed_at IS 'Timestamp when employee signed the contract';
COMMENT ON COLUMN public.bike_benefits.contract_employer_signed_at IS 'Timestamp when employer signed the contract';
COMMENT ON COLUMN public.bike_benefits.contract_approved_at IS 'Timestamp when contract was fully approved (both parties signed)';
COMMENT ON COLUMN public.bike_benefits.contract_terminated_at IS 'Timestamp when contract was terminated';
COMMENT ON COLUMN public.bike_benefits.benefit_terminated_at IS 'Timestamp when benefit was terminated';
COMMENT ON COLUMN public.bike_benefits.benefit_insurance_claim_at IS 'Timestamp when insurance claim was filed';

-- ============================================
-- 4. Create trigger function to auto-update benefit_status
-- ============================================
CREATE OR REPLACE FUNCTION public.update_bike_benefit_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Don't auto-update if manually set to insurance_claim or terminated
  IF NEW.benefit_status IN ('insurance_claim', 'terminated') AND 
     OLD.benefit_status IN ('insurance_claim', 'terminated') THEN
    RETURN NEW;
  END IF;
  
  -- Auto-determine benefit_status based on step and timestamps
  IF NEW.step IS NULL THEN
    -- If step is reset/NULL, status should also be NULL
    NEW.benefit_status := NULL;
    
  ELSIF NEW.step = 'commit_to_bike' AND NEW.committed_at IS NOT NULL THEN
    NEW.benefit_status := 'active';
    
  ELSIF NEW.step = 'book_live_test' AND NEW.live_test_whatsapp_sent_at IS NOT NULL THEN
    NEW.benefit_status := 'testing';
    
  ELSIF NEW.step = 'choose_bike' THEN
    NEW.benefit_status := 'searching';
    
  -- If step is 'commit_to_bike' or 'sign_contract', keep current status or set to searching
  ELSIF NEW.step IN ('commit_to_bike', 'sign_contract') THEN
    IF OLD.benefit_status IS NOT NULL THEN
      NEW.benefit_status := OLD.benefit_status;
    ELSE
      NEW.benefit_status := 'searching';
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.update_bike_benefit_status IS 
'Trigger function that auto-updates benefit_status based on step and timestamp changes. 
Sets status to NULL when step is NULL (benefit not started).
Does not override manually set insurance_claim or terminated statuses.';

-- ============================================
-- 5. Create trigger function to auto-update contract_status
-- ============================================
CREATE OR REPLACE FUNCTION public.update_contract_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Don't auto-update if manually set to terminated
  IF NEW.contract_status = 'terminated' AND OLD.contract_status = 'terminated' THEN
    RETURN NEW;
  END IF;
  
  -- Auto-determine contract_status based on timestamps
  -- Check in reverse order (most complete state first)
  IF NEW.contract_employee_signed_at IS NOT NULL AND 
     NEW.contract_employer_signed_at IS NOT NULL AND
     NEW.contract_approved_at IS NOT NULL THEN
    NEW.contract_status := 'approved';
    
  ELSIF NEW.contract_employer_signed_at IS NOT NULL THEN
    NEW.contract_status := 'signed_by_employer';
    
  ELSIF NEW.contract_employee_signed_at IS NOT NULL THEN
    NEW.contract_status := 'signed_by_employee';
    
  ELSIF NEW.contract_viewed_at IS NOT NULL THEN
    NEW.contract_status := 'viewed_by_employee';
    
  ELSE
    -- Only reset to not_started if it wasn't manually set to terminated
    IF NEW.contract_status != 'terminated' THEN
      NEW.contract_status := 'not_started';
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.update_contract_status IS 
'Trigger function that auto-updates contract_status based on contract timestamp changes. 
Does not override manually set terminated status.';

-- ============================================
-- 6. Create triggers on bike_benefits table
-- ============================================
-- Note: These triggers run BEFORE UPDATE so they can modify NEW before it's saved

-- Trigger for benefit_status updates
CREATE TRIGGER update_benefit_status_on_change
  BEFORE INSERT OR UPDATE OF step, live_test_whatsapp_sent_at, delivered_at, benefit_status
  ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_bike_benefit_status();

-- Trigger for contract_status updates
CREATE TRIGGER update_contract_status_on_change
  BEFORE INSERT OR UPDATE OF contract_viewed_at, contract_employee_signed_at, 
                             contract_employer_signed_at, contract_approved_at, contract_status
  ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_contract_status();

-- ============================================
-- 7. Create indexes for better query performance
-- ============================================
CREATE INDEX IF NOT EXISTS idx_bike_benefits_benefit_status ON public.bike_benefits(benefit_status);
CREATE INDEX IF NOT EXISTS idx_bike_benefits_contract_status ON public.bike_benefits(contract_status);

-- ============================================
-- 8. Update existing bike_benefits records to set initial status
-- ============================================
-- This updates existing records based on their current step and timestamps
UPDATE public.bike_benefits
SET 
  benefit_status = CASE
    WHEN step = 'pickup_delivery' AND delivered_at IS NOT NULL THEN 'active'::public.benefit_status
    WHEN step = 'book_live_test' AND live_test_whatsapp_sent_at IS NOT NULL THEN 'testing'::public.benefit_status
    WHEN step = 'choose_bike' THEN 'searching'::public.benefit_status
    WHEN step IS NULL THEN NULL
    ELSE NULL
  END,
  contract_status = CASE
    WHEN contract_requested_at IS NOT NULL THEN 'viewed_by_employee'::public.contract_status
    ELSE 'not_started'::public.contract_status
  END
WHERE benefit_status IS NULL AND contract_status = 'not_started';

-- ============================================
-- 9. Grant permissions
-- ============================================
GRANT EXECUTE ON FUNCTION public.update_bike_benefit_status TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_bike_benefit_status TO service_role;
GRANT EXECUTE ON FUNCTION public.update_contract_status TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_contract_status TO service_role;

-- ============================================
-- 10. Example usage for frontend
-- ============================================
-- 
-- Example 1: HR Dashboard - Get all benefits with their statuses
-- SELECT 
--   p.email,
--   bb.benefit_status,
--   bb.contract_status,
--   bb.step,
--   bb.created_at
-- FROM bike_benefits bb
-- JOIN profiles p ON bb.user_id = p.user_id
-- WHERE p.company_id = (SELECT company_id FROM profiles WHERE user_id = auth.uid())
-- ORDER BY bb.created_at DESC;
--
-- Example 2: Update benefit to insurance claim (manually by HR)
-- UPDATE bike_benefits 
-- SET 
--   benefit_status = 'insurance_claim',
--   benefit_insurance_claim_at = NOW()
-- WHERE id = 'benefit-id';
--
-- Example 3: Employee views contract (auto-updates contract_status)
-- UPDATE bike_benefits 
-- SET contract_viewed_at = NOW()
-- WHERE id = 'benefit-id';
-- -- This automatically sets contract_status to 'viewed_by_employee'
--
-- Example 4: Employee signs contract (auto-updates contract_status)
-- UPDATE bike_benefits 
-- SET contract_employee_signed_at = NOW()
-- WHERE id = 'benefit-id';
-- -- This automatically sets contract_status to 'signed_by_employee'
--
-- Example 5: Employer signs contract (auto-updates contract_status)
-- UPDATE bike_benefits 
-- SET 
--   contract_employer_signed_at = NOW(),
--   contract_approved_at = NOW()
-- WHERE id = 'benefit-id';
-- -- This automatically sets contract_status to 'approved'
