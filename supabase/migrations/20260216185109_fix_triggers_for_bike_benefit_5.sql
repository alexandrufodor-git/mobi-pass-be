-- 1. Ensure the Enum and Default are correct first
ALTER TYPE public.contract_status ADD VALUE IF NOT EXISTS 'pending' BEFORE 'viewed_by_employee';
ALTER TABLE public.bike_benefits ALTER COLUMN contract_status SET DEFAULT NULL;

-- 2. Consolidated Trigger Function
CREATE OR REPLACE FUNCTION public.sync_bike_benefit_state()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- GUARD: HR-set terminal states (don't automate if already terminated/claimed)
  IF TG_OP = 'UPDATE' AND (
     OLD.benefit_status IN ('insurance_claim', 'terminated') OR 
     OLD.contract_status = 'terminated'
  ) THEN
    RETURN NEW;
  END IF;

  -- STEP 1: RESET LOGIC (The "Chose Another Bike" Guard)
  -- We check if they moved back to 'choose_bike'
  IF NEW.step = 'choose_bike'::public.bike_benefit_step THEN
    -- If it's a new row OR the step just changed to choose_bike
    IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.step IS DISTINCT FROM 'choose_bike') THEN
      NEW.live_test_whatsapp_sent_at := NULL; -- Ensure this matches your ACTUAL column name
      NEW.contract_requested_at := NULL;        -- Match the prompt: request_contract_at
      NEW.committed_at := NULL;               -- Match the prompt: commited_at
      NEW.contract_status := NULL;
    END IF;
    NEW.benefit_status := 'searching'::public.benefit_status;
  
  -- STEP 2: BENEFIT STATUS UPDATES
  ELSIF NEW.step = 'book_live_test'::public.bike_benefit_step THEN
    NEW.benefit_status := CASE 
      WHEN NEW.live_test_whatsapp_sent_at IS NOT NULL THEN 'testing'::public.benefit_status 
    END;
  ELSIF NEW.step = 'commit_to_bike'::public.bike_benefit_step THEN
    NEW.benefit_status := CASE 
      WHEN NEW.committed_at IS NOT NULL THEN 'active'::public.benefit_status
    END;
  ELSIF NEW.step IS NULL THEN
    NEW.benefit_status := 'inactive'::public.benefit_status;
  END IF;

  -- STEP 3: CONTRACT STATUS UPDATES (Driven by timestamps)
  -- Priority: Approved -> Employer Signed -> Employee Signed -> Viewed -> Pending
  IF NEW.contract_approved_at IS NOT NULL AND NEW.contract_employer_signed_at IS NOT NULL THEN
    NEW.contract_status := 'approved'::public.contract_status;
  ELSIF NEW.contract_employer_signed_at IS NOT NULL THEN
    NEW.contract_status := 'signed_by_employer'::public.contract_status;
  ELSIF NEW.contract_employee_signed_at IS NOT NULL THEN
    NEW.contract_status := 'signed_by_employee'::public.contract_status;
  ELSIF NEW.contract_viewed_at IS NOT NULL THEN
    NEW.contract_status := 'viewed_by_employee'::public.contract_status;
  ELSIF NEW.contract_requested_at IS NOT NULL THEN
    NEW.contract_status := 'pending'::public.contract_status; -- This replaces 'not_started'
  ELSE
    -- If no timestamps exist, it stays NULL
    NEW.contract_status := NULL;
  END IF;

  RETURN NEW;
END;
$$;

-- 3. Apply the single trigger
DROP TRIGGER IF EXISTS update_benefit_status_on_change ON public.bike_benefits;
DROP TRIGGER IF EXISTS update_contract_status_on_change ON public.bike_benefits;
DROP TRIGGER IF EXISTS master_bike_benefit_sync ON public.bike_benefits;

CREATE TRIGGER master_bike_benefit_sync
  BEFORE INSERT OR UPDATE ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_bike_benefit_state();