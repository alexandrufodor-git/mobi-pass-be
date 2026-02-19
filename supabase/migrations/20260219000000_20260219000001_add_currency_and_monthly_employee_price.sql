-- ============================================
-- Migration: Currency type + monthly employee price
-- ============================================
-- Adds:
--   1. currency_type enum (EUR: €, RON: RON). Companies default to RON.
--   2. effective_currency to bike_benefits — snapped alongside the other
--      effective terms.
--   3. Helper get_company_terms_for_user() — resolves company terms for a
--      user (profiles → companies). Used by the trigger on INSERT.
--   4. Helper calc_employee_prices() — pure price calculation reused by
--      both views. Accepts full_price + contract terms, returns
--      employee_price and monthly_employee_price.
--   5. Trigger updated: snapshot on INSERT only (via get_company_terms_for_user).
--   6. bikes_with_my_pricing rebuilt — LEFT JOINs + calc helper.
--   7. profile_invites_with_details rebuilt — calc helper with effective
--      values (COALESCE fallback to live company terms).
-- ============================================


-- ============================================
-- 1. Currency enum + companies.currency
-- ============================================

CREATE TYPE public.currency_type AS ENUM ('EUR', 'RON');

COMMENT ON TYPE public.currency_type IS
  'Supported currencies. EUR: symbol €  |  RON: symbol RON';

ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS currency public.currency_type NOT NULL DEFAULT 'RON';

COMMENT ON COLUMN public.companies.currency IS
  'Currency used for bike benefit pricing. Defaults to RON.';


-- ============================================
-- 2. Add effective_currency to bike_benefits
-- ============================================

ALTER TABLE public.bike_benefits
  ADD COLUMN IF NOT EXISTS effective_currency public.currency_type;

COMMENT ON COLUMN public.bike_benefits.effective_currency IS
  'Currency locked when the benefit was first created (INSERT). '
  'NULL for legacy records — falls back to companies.currency in views.';


-- ============================================
-- 3. Helper: resolve company terms for a user
--    Used by the trigger to snap terms on INSERT.
-- ============================================

CREATE OR REPLACE FUNCTION public.get_company_terms_for_user(p_user_id UUID)
RETURNS TABLE (
  monthly_benefit_subsidy  DECIMAL(10, 2),
  contract_months          INTEGER,
  currency                 public.currency_type
)
LANGUAGE sql
STABLE
AS $$
  SELECT c.monthly_benefit_subsidy,
         c.contract_months,
         c.currency
  FROM   public.profiles pr
  JOIN   public.companies c ON c.id = pr.company_id
  WHERE  pr.user_id = p_user_id;
$$;


-- ============================================
-- 4. Helper: compute employee prices
--    Pure calculation — no DB lookups.
--    employee_price         = GREATEST(0, full_price - (contract_months × monthly_subsidy))
--    monthly_employee_price = employee_price / contract_months
--    Returns NULL for both columns when any input is NULL.
-- ============================================

CREATE OR REPLACE FUNCTION public.calc_employee_prices(
  p_full_price      DECIMAL(10, 2),
  p_monthly_subsidy DECIMAL(10, 2),
  p_contract_months INTEGER
)
RETURNS TABLE (
  employee_price         DECIMAL(10, 2),
  monthly_employee_price DECIMAL(10, 2)
)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    CASE
      WHEN p_full_price IS NOT NULL
           AND p_monthly_subsidy IS NOT NULL
           AND p_contract_months IS NOT NULL THEN
        GREATEST(0::numeric,
                 p_full_price - (p_monthly_subsidy * p_contract_months::numeric))
      ELSE NULL::numeric
    END                                                        AS employee_price,
    CASE
      WHEN p_full_price IS NOT NULL
           AND p_monthly_subsidy IS NOT NULL
           AND p_contract_months IS NOT NULL
           AND p_contract_months > 0 THEN
        GREATEST(0::numeric,
                 p_full_price - (p_monthly_subsidy * p_contract_months::numeric))
        / p_contract_months::numeric
      ELSE NULL::numeric
    END                                                        AS monthly_employee_price;
$$;


-- ============================================
-- 5. Update update_bike_benefit_status trigger
--    Snap company terms on INSERT via get_company_terms_for_user.
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
      -- Delete any existing order — employee is starting over with a new bike choice
      DELETE FROM public.bike_orders WHERE bike_benefit_id = NEW.id;
    END IF;
    NEW.benefit_status := 'searching'::public.benefit_status;

  ELSIF NEW.step = 'book_live_test'::public.bike_benefit_step THEN
    NEW.benefit_status := 'searching'::public.benefit_status;

  ELSIF NEW.step = 'commit_to_bike'::public.bike_benefit_step THEN
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
-- 6. Rebuild bikes_with_my_pricing
--    LEFT JOINs so all bikes are returned even when the calling user has no
--    linked company (pricing columns will be NULL in that case).
--    Price calculation delegated to calc_employee_prices().
-- ============================================

DROP VIEW IF EXISTS public.bikes_with_my_pricing;

CREATE VIEW public.bikes_with_my_pricing AS
SELECT
  b.*,
  c.monthly_benefit_subsidy,
  c.contract_months,
  c.currency,
  prices.employee_price                                       AS company_employee_price,
  prices.monthly_employee_price
FROM       public.bikes     b
LEFT JOIN  public.profiles  me     ON  me.user_id  = auth.uid()
LEFT JOIN  public.companies c      ON  c.id        = me.company_id
LEFT JOIN LATERAL public.calc_employee_prices(
            b.full_price, c.monthly_benefit_subsidy, c.contract_months
          ) prices ON true;

GRANT SELECT ON public.bikes_with_my_pricing TO authenticated;

COMMENT ON VIEW public.bikes_with_my_pricing IS
  'Bike catalog with employee-specific pricing. Uses auth.uid() to resolve the '
  'calling user''s company subsidy and contract terms automatically. '
  'Returns all bikes; pricing columns are NULL when the user has no linked company. '
  'company_employee_price = GREATEST(0, full_price - (contract_months x monthly_benefit_subsidy)). '
  'monthly_employee_price = company_employee_price / contract_months.';


-- ============================================
-- 7. Rebuild profile_invites_with_details
--    calc_employee_prices called with effective terms (COALESCE to live
--    company values for uncommitted / legacy records).
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
  prices.employee_price                                       AS bike_employee_price,
  prices.monthly_employee_price,
  bo.id                                                       AS order_id
FROM       public.profile_invites pi
LEFT JOIN  public.companies       c      ON  pi.company_id = c.id
LEFT JOIN  public.profiles        p      ON  pi.email      = p.email
LEFT JOIN  public.bike_benefits   bb     ON  p.user_id     = bb.user_id
LEFT JOIN  public.bikes           b      ON  bb.bike_id    = b.id
LEFT JOIN  public.bike_orders     bo     ON  bb.id         = bo.bike_benefit_id
LEFT JOIN LATERAL public.calc_employee_prices(
            b.full_price,
            COALESCE(bb.effective_monthly_subsidy, c.monthly_benefit_subsidy),
            COALESCE(bb.effective_contract_months, c.contract_months)
          ) prices ON true
ORDER BY COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) DESC;
