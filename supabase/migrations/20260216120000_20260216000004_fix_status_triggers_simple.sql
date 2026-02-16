-- ============================================
-- Rewrite benefit_status and contract_status triggers - simple and reliable
-- ============================================
-- Both triggers now fire on EVERY INSERT/UPDATE of the row (no column
-- restriction). This guarantees they always recalculate from the current
-- full row state, regardless of which columns the caller touched.
--
-- benefit_status rules:
--   step IS NULL                                          → inactive
--   step = choose_bike                                    → searching  (+ reset later-step fields)
--   step = book_live_test + live_test_whatsapp_sent_at    → testing
--   step = book_live_test (no whatsapp yet)               → searching
--   step = commit_to_bike + committed_at                  → active
--   step = commit_to_bike (no committed_at yet)           → keep previous / searching
--   step = sign_contract / pickup_delivery                → keep previous / searching
--   benefit_status already insurance_claim or terminated  → do not touch (HR-set)
--
-- contract_status rules (timestamp-driven, no step dependency):
--   contract_requested_at set                             → pending
--   contract_viewed_at set                                → viewed_by_employee
--   contract_employee_signed_at set                       → signed_by_employee
--   contract_employer_signed_at set                       → signed_by_employer
--   all three signed + approved_at                        → approved
--   contract_status already terminated                    → do not touch (HR-set)
--   none of the above                                     → NULL
-- ============================================


-- ============================================
-- 1. Drop existing triggers
-- ============================================
DROP TRIGGER IF EXISTS update_benefit_status_on_change  ON public.bike_benefits;
DROP TRIGGER IF EXISTS update_contract_status_on_change ON public.bike_benefits;


-- ============================================
-- 2. Benefit status trigger function
-- ============================================
CREATE OR REPLACE FUNCTION public.update_bike_benefit_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- HR-set terminal states: never overwrite automatically
  IF TG_OP = 'UPDATE' AND OLD.benefit_status IN ('insurance_claim', 'terminated') THEN
    RETURN NEW;
  END IF;

  IF NEW.step IS NULL THEN
    NEW.benefit_status := 'inactive';

  ELSIF NEW.step = 'choose_bike' THEN
    -- Reset all later-step data when employee goes back to bike selection
    IF TG_OP = 'UPDATE' THEN
      NEW.live_test_whatsapp_sent_at := NULL;
      NEW.contract_requested_at     := NULL;
      NEW.committed_at              := NULL;
      NEW.contract_status           := NULL;
    END IF;
    NEW.benefit_status := 'searching';

  ELSIF NEW.step = 'book_live_test' THEN
    IF NEW.live_test_whatsapp_sent_at IS NOT NULL THEN
      NEW.benefit_status := 'testing';
    ELSE
      NEW.benefit_status := 'searching';
    END IF;

  ELSIF NEW.step = 'commit_to_bike' THEN
    IF NEW.committed_at IS NOT NULL THEN
      NEW.benefit_status := 'active';
    ELSE
      NEW.benefit_status := COALESCE(OLD.benefit_status, 'searching');
    END IF;

  ELSIF NEW.step IN ('sign_contract', 'pickup_delivery') THEN
    NEW.benefit_status := COALESCE(OLD.benefit_status, 'searching');

  END IF;

  RETURN NEW;
END;
$$;


-- ============================================
-- 3. Contract status trigger function
-- ============================================
CREATE OR REPLACE FUNCTION public.update_contract_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- HR-set terminated state: never overwrite automatically
  IF TG_OP = 'UPDATE' AND OLD.contract_status = 'terminated' THEN
    RETURN NEW;
  END IF;

  -- Evaluate from most-complete state down to least
  IF NEW.contract_employee_signed_at IS NOT NULL AND
     NEW.contract_employer_signed_at IS NOT NULL AND
     NEW.contract_approved_at        IS NOT NULL THEN
    NEW.contract_status := 'approved';

  ELSIF NEW.contract_employer_signed_at IS NOT NULL THEN
    NEW.contract_status := 'signed_by_employer';

  ELSIF NEW.contract_employee_signed_at IS NOT NULL THEN
    NEW.contract_status := 'signed_by_employee';

  ELSIF NEW.contract_viewed_at IS NOT NULL THEN
    NEW.contract_status := 'viewed_by_employee';

  ELSIF NEW.contract_requested_at IS NOT NULL THEN
    NEW.contract_status := 'pending';

  ELSE
    NEW.contract_status := NULL;
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================
-- 4. Recreate triggers — fire on every INSERT/UPDATE, no column restriction
-- ============================================

-- Benefit trigger runs first (alphabetically before contract trigger)
CREATE TRIGGER update_benefit_status_on_change
  BEFORE INSERT OR UPDATE ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_bike_benefit_status();

-- Contract trigger runs second — sees any choose_bike resets made by benefit trigger
CREATE TRIGGER update_contract_status_on_change
  BEFORE INSERT OR UPDATE ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_contract_status();
