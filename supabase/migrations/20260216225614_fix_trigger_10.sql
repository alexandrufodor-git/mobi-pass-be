-- ============================================
-- Fix benefit_status trigger: correct trailing-step logic
-- ============================================
-- The status at each step is driven by the timestamp set on the PREVIOUS step:
--
--   step = choose_bike     → searching   (reset all later-step fields)
--   step = book_live_test  → searching   (waiting for WhatsApp confirmation)
--   step = commit_to_bike  → testing     (live_test_whatsapp_sent_at was set)
--   step = sign_contract   → active      (committed_at was set)
--   step = pickup_delivery → active      (contract_requested_at drives contract_status only)
--   step = NULL            → inactive
-- ============================================

DROP TRIGGER IF EXISTS update_benefit_status_on_change  ON public.bike_benefits;
DROP TRIGGER IF EXISTS update_contract_status_on_change ON public.bike_benefits;


-- ============================================
-- Benefit status trigger
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

  IF NEW.step IS NULL THEN
    NEW.benefit_status := 'inactive'::public.benefit_status;

  ELSIF NEW.step = 'choose_bike'::public.bike_benefit_step THEN
    -- Only reset when TRANSITIONING to choose_bike (user reconsidered)
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
      NEW.delivered_at                := NULL;
      NEW.contract_status             := NULL;
    END IF;
    NEW.benefit_status := 'searching'::public.benefit_status;

  ELSIF NEW.step = 'book_live_test'::public.bike_benefit_step THEN
    -- Searching until WhatsApp is confirmed (timestamp set while on this step)
    NEW.benefit_status := 'searching'::public.benefit_status;

  ELSIF NEW.step = 'commit_to_bike'::public.bike_benefit_step THEN
    -- WhatsApp was sent during book_live_test → now testing
    IF NEW.live_test_whatsapp_sent_at IS NOT NULL THEN
      NEW.benefit_status := 'testing'::public.benefit_status;
    ELSE
      NEW.benefit_status := 'searching'::public.benefit_status;
    END IF;

  ELSIF NEW.step = 'sign_contract'::public.bike_benefit_step THEN
    -- Employee committed during commit_to_bike → now active
    IF NEW.committed_at IS NOT NULL THEN
      NEW.benefit_status := 'active'::public.benefit_status;
    ELSE
      NEW.benefit_status := COALESCE(OLD.benefit_status, 'searching'::public.benefit_status);
    END IF;

  ELSIF NEW.step = 'pickup_delivery'::public.bike_benefit_step THEN
    -- Contract was requested during sign_contract; benefit stays active
    NEW.benefit_status := COALESCE(OLD.benefit_status, 'active'::public.benefit_status);

  END IF;

  RETURN NEW;
END;
$$;


-- ============================================
-- Contract status trigger (timestamp-driven, unchanged logic)
-- ============================================
CREATE OR REPLACE FUNCTION public.update_contract_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND OLD.contract_status = 'terminated'::public.contract_status THEN
    RETURN NEW;
  END IF;

  IF NEW.contract_employee_signed_at IS NOT NULL
     AND NEW.contract_employer_signed_at IS NOT NULL
     AND NEW.contract_approved_at IS NOT NULL THEN
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
-- Recreate both triggers — fire on every INSERT/UPDATE
-- ============================================
CREATE TRIGGER update_benefit_status_on_change
  BEFORE INSERT OR UPDATE ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_bike_benefit_status();

CREATE TRIGGER update_contract_status_on_change
  BEFORE INSERT OR UPDATE ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_contract_status();
