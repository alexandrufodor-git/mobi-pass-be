-- ============================================
-- Update benefit_status trigger - commit_to_bike makes benefit active
-- ============================================
-- Changes the logic so that benefit becomes 'active' when:
-- step = 'commit_to_bike' AND committed_at IS NOT NULL
-- (instead of waiting for pickup_delivery + delivered_at)
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
    NEW.benefit_status := NULL;
    
  ELSIF NEW.step = 'commit_to_bike' AND NEW.committed_at IS NOT NULL THEN
    NEW.benefit_status := 'active';
    
  ELSIF NEW.step = 'book_live_test' AND NEW.live_test_whatsapp_sent_at IS NOT NULL THEN
    NEW.benefit_status := 'testing';
    
  ELSIF NEW.step = 'choose_bike' THEN
    NEW.benefit_status := 'searching';
    
  ELSIF NEW.step IN ('sign_contract', 'pickup_delivery') THEN
    IF OLD.benefit_status IS NOT NULL THEN
      NEW.benefit_status := OLD.benefit_status;
    ELSE
      NEW.benefit_status := 'searching';
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;
