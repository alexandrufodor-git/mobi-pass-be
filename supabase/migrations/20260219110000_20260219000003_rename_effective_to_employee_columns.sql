-- ============================================
-- Migration: Simplify bike_benefits to 3 employee columns
-- ============================================
-- Drops the subsidy/months snapshots — not needed, terms are looked up
-- fresh at commit_to_bike to compute the prices.
--
-- Final 3 columns:
--   employee_full_price    (was employee_price)
--   employee_monthly_price (was monthly_employee_price)
--   employee_currency      (was effective_currency)
--
-- Also drops effective_monthly_subsidy and effective_contract_months.
-- ============================================


-- ============================================
-- 1. Drop snapshot columns no longer needed
-- ============================================

ALTER TABLE public.bike_benefits
  DROP COLUMN IF EXISTS effective_monthly_subsidy,
  DROP COLUMN IF EXISTS effective_contract_months;


-- ============================================
-- 2. Rename remaining columns
-- ============================================

ALTER TABLE public.bike_benefits
  RENAME COLUMN effective_currency     TO employee_currency;

ALTER TABLE public.bike_benefits
  RENAME COLUMN employee_price         TO employee_full_price;

ALTER TABLE public.bike_benefits
  RENAME COLUMN monthly_employee_price TO employee_monthly_price;


-- ============================================
-- 3. Update comments
-- ============================================

COMMENT ON COLUMN public.bike_benefits.employee_currency IS
  'Currency locked for this employee at benefit creation. '
  'NULL for legacy records — falls back to companies.currency in views.';

COMMENT ON COLUMN public.bike_benefits.employee_full_price IS
  'Total discounted price: GREATEST(0, full_price - (monthly_subsidy x contract_months)). '
  'Computed and stored when step transitions to commit_to_bike. Cleared on choose_bike reset.';

COMMENT ON COLUMN public.bike_benefits.employee_monthly_price IS
  'Monthly employee payment: employee_full_price / contract_months. '
  'Computed and stored when step transitions to commit_to_bike. Cleared on choose_bike reset.';


-- ============================================
-- 4. Update trigger
--    INSERT         — snap employee_currency only.
--    commit_to_bike — look up company terms fresh + bike full_price,
--                     compute and store employee_full_price / employee_monthly_price.
--    choose_bike    — clear all three price/currency fields.
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

  -- Snap currency only on new benefit creation.
  IF TG_OP = 'INSERT' THEN
    SELECT t.currency
    INTO   NEW.employee_currency
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
      DELETE FROM public.bike_orders WHERE bike_benefit_id = NEW.id;
    END IF;
    NEW.benefit_status := 'searching'::public.benefit_status;

  ELSIF NEW.step = 'book_live_test'::public.bike_benefit_step THEN
    NEW.benefit_status := 'searching'::public.benefit_status;

  ELSIF NEW.step = 'commit_to_bike'::public.bike_benefit_step THEN
    -- Look up current company terms + bike full_price, compute and store prices.
    IF NEW.bike_id IS NOT NULL THEN
      SELECT p.employee_price, p.monthly_employee_price
      INTO   NEW.employee_full_price, NEW.employee_monthly_price
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
-- 5. Rebuild bikes_with_my_pricing
-- ============================================

DROP VIEW IF EXISTS public.bikes_with_my_pricing;

CREATE VIEW public.bikes_with_my_pricing AS
SELECT
  b.*,
  c.monthly_benefit_subsidy,
  c.contract_months,
  c.currency,
  prices.employee_price          AS employee_full_price,
  prices.monthly_employee_price  AS employee_monthly_price
FROM       public.bikes     b
LEFT JOIN  public.profiles  me ON  me.user_id = auth.uid()
LEFT JOIN  public.companies c  ON  c.id       = me.company_id
LEFT JOIN LATERAL public.calc_employee_prices(
            b.full_price, c.monthly_benefit_subsidy, c.contract_months
          ) prices ON true;

GRANT SELECT ON public.bikes_with_my_pricing TO authenticated;

COMMENT ON VIEW public.bikes_with_my_pricing IS
  'Bike catalog with employee-specific pricing. Uses auth.uid() to resolve the '
  'calling user''s company subsidy and contract terms automatically. '
  'Returns all bikes; pricing columns are NULL when the user has no linked company. '
  'employee_full_price    = GREATEST(0, full_price - (contract_months x monthly_benefit_subsidy)). '
  'employee_monthly_price = employee_full_price / contract_months.';


-- ============================================
-- 6. Rebuild profile_invites_with_details
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
  bo.id                                                       AS order_id
FROM       public.profile_invites pi
LEFT JOIN  public.companies       c   ON  pi.company_id = c.id
LEFT JOIN  public.profiles        p   ON  pi.email      = p.email
LEFT JOIN  public.bike_benefits   bb  ON  p.user_id     = bb.user_id
LEFT JOIN  public.bikes           b   ON  bb.bike_id    = b.id
LEFT JOIN  public.bike_orders     bo  ON  bb.id         = bo.bike_benefit_id
ORDER BY COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) DESC;
