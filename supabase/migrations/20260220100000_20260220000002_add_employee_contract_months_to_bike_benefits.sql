-- ============================================
-- Migration: Add employee_contract_months to bike_benefits
-- ============================================
-- Snapshots companies.contract_months onto bike_benefits so the agreed
-- term is preserved even if the company later changes it.
--
-- Snapped on INSERT  — same as employee_currency.
-- Snapped on commit_to_bike — locked alongside the computed prices.
-- Cleared on choose_bike reset — same as prices.
-- ============================================


-- ============================================
-- 1. Add column
-- ============================================

ALTER TABLE public.bike_benefits
  ADD COLUMN IF NOT EXISTS employee_contract_months INTEGER;

COMMENT ON COLUMN public.bike_benefits.employee_contract_months IS
  'Contract duration (months) locked for this employee at benefit creation. '
  'Re-confirmed and stored when step transitions to commit_to_bike. '
  'Cleared on choose_bike reset. NULL for legacy records.';


-- ============================================
-- 2. Update trigger: snap on INSERT + commit_to_bike, clear on choose_bike
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

  -- Snap currency + contract_months only on new benefit creation.
  IF TG_OP = 'INSERT' THEN
    SELECT t.currency, t.contract_months
    INTO   NEW.employee_currency, NEW.employee_contract_months
    FROM   public.get_company_terms_for_user(NEW.user_id) t;
  END IF;

  -- Step-driven status logic
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
    -- Look up current company terms + bike full_price, compute and store prices.
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
