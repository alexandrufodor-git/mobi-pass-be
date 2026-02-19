-- ============================================
-- Migration: Store employee prices on bike_benefits at commit_to_bike
-- ============================================
-- Adds employee_price and monthly_employee_price columns to bike_benefits.
-- These are computed using calc_employee_prices() (defined in previous
-- migration) and stored when step transitions to commit_to_bike — the first
-- moment a specific bike + snapped company terms are both available.
-- Cleared on choose_bike reset when the employee picks a new bike.
--
-- Formula (via calc_employee_prices):
--   employee_price         = GREATEST(0, full_price - (effective_monthly_subsidy × effective_contract_months))
--   monthly_employee_price = employee_price / effective_contract_months
-- ============================================


-- ============================================
-- 1. Add price columns to bike_benefits
-- ============================================

ALTER TABLE public.bike_benefits
  ADD COLUMN IF NOT EXISTS employee_price          DECIMAL(10, 2),
  ADD COLUMN IF NOT EXISTS monthly_employee_price  DECIMAL(10, 2);

COMMENT ON COLUMN public.bike_benefits.employee_price IS
  'Total discounted price the employee pays: GREATEST(0, full_price - (effective_monthly_subsidy x effective_contract_months)). '
  'Computed and stored when step transitions to commit_to_bike. Cleared on choose_bike reset.';

COMMENT ON COLUMN public.bike_benefits.monthly_employee_price IS
  'Monthly employee payment: employee_price / effective_contract_months. '
  'Computed and stored when step transitions to commit_to_bike. Cleared on choose_bike reset.';


-- ============================================
-- 2. Update trigger
--    commit_to_bike — compute and store prices using the selected bike's
--      full_price and the snapped effective company terms.
--    choose_bike reset — clear stored prices (employee is picking a new bike).
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

  -- Snap company terms on new benefit creation.
  IF TG_OP = 'INSERT' THEN
    SELECT t.monthly_benefit_subsidy, t.contract_months, t.currency
    INTO   NEW.effective_monthly_subsidy, NEW.effective_contract_months, NEW.effective_currency
    FROM   public.get_company_terms_for_user(NEW.user_id) t;
  END IF;

  -- Step-driven status logic
  IF NEW.step IS NULL THEN
    NEW.benefit_status := 'inactive'::public.benefit_status;

  ELSIF NEW.step = 'choose_bike'::public.bike_benefit_step THEN
    -- Transitioning (back) to choose_bike: reset all downstream fields
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
      -- Clear stored prices — employee is picking a new bike
      NEW.employee_price              := NULL;
      NEW.monthly_employee_price      := NULL;
      -- Delete any existing order — employee is starting over with a new bike choice
      DELETE FROM public.bike_orders WHERE bike_benefit_id = NEW.id;
    END IF;
    NEW.benefit_status := 'searching'::public.benefit_status;

  ELSIF NEW.step = 'book_live_test'::public.bike_benefit_step THEN
    NEW.benefit_status := 'searching'::public.benefit_status;

  ELSIF NEW.step = 'commit_to_bike'::public.bike_benefit_step THEN
    -- Employee has committed to a specific bike: compute and store prices.
    -- Uses snapped effective terms (set at INSERT) + the bike's full_price.
    IF NEW.bike_id IS NOT NULL THEN
      SELECT p.employee_price, p.monthly_employee_price
      INTO   NEW.employee_price, NEW.monthly_employee_price
      FROM   public.bikes b
      CROSS JOIN LATERAL public.calc_employee_prices(
        b.full_price,
        NEW.effective_monthly_subsidy,
        NEW.effective_contract_months
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
-- 3. Rebuild profile_invites_with_details
--    bike_employee_price and monthly_employee_price now read directly from
--    the stored columns on bike_benefits (populated at commit_to_bike).
-- ============================================

DROP VIEW IF EXISTS public.profile_invites_with_details;

CREATE VIEW public.profile_invites_with_details AS
SELECT
  pi.id                                                       AS invite_id,
  pi.email,
  pi.status                                                   AS invite_status,
  pi.created_at                                               AS invited_at,
  pi.company_id,
  c.name                                                      AS company_name,
  p.user_id,
  p.status                                                    AS profile_status,
  p.created_at                                                AS registered_at,
  COALESCE(p.first_name,   pi.first_name)                    AS first_name,
  COALESCE(p.last_name,    pi.last_name)                     AS last_name,
  COALESCE(p.description,  pi.description)                   AS description,
  COALESCE(p.department,   pi.department)                    AS department,
  COALESCE(p.hire_date,    pi.hire_date)                     AS hire_date,
  bb.id                                                       AS bike_benefit_id,
  bb.benefit_status,
  bb.contract_status,
  COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) AS last_modified_at,
  bb.bike_id,
  bb.employee_price                                           AS bike_employee_price,
  bb.monthly_employee_price,
  bo.id                                                       AS order_id
FROM       public.profile_invites pi
LEFT JOIN  public.companies       c   ON  pi.company_id = c.id
LEFT JOIN  public.profiles        p   ON  pi.email      = p.email
LEFT JOIN  public.bike_benefits   bb  ON  p.user_id     = bb.user_id
LEFT JOIN  public.bikes           b   ON  bb.bike_id    = b.id
LEFT JOIN  public.bike_orders     bo  ON  bb.id         = bo.bike_benefit_id
ORDER BY COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) DESC;
