-- ============================================
-- Migration: Effective contract terms snapshot + employee catalog view
-- ============================================
-- Problem: companies.monthly_benefit_subsidy and contract_months are looked up
-- at query time, meaning price calculations drift if a company changes its terms.
--
-- Solution:
--   1. Add effective_monthly_subsidy / effective_contract_months to bike_benefits.
--      These are snapped from the company when the employee first commits to a bike
--      (committed_at is set). Uncommitted benefits fall back to current company values.
--
--   2. bikes_with_my_pricing view — employee-facing catalog. Single query, no
--      client-side joins. Prices always reflect the calling user's company terms.
--
--   3. Update profile_invites_with_details to use effective values when available,
--      falling back to current company values for uncommitted/legacy records.
-- ============================================


-- ============================================
-- 1. Add effective columns to bike_benefits
-- ============================================

ALTER TABLE public.bike_benefits
  ADD COLUMN IF NOT EXISTS effective_monthly_subsidy DECIMAL(10, 2),
  ADD COLUMN IF NOT EXISTS effective_contract_months INTEGER;

COMMENT ON COLUMN public.bike_benefits.effective_monthly_subsidy IS
  'Company monthly subsidy locked at the time the employee committed to a bike (committed_at set). '
  'NULL for benefits not yet committed — falls back to companies.monthly_benefit_subsidy in views.';

COMMENT ON COLUMN public.bike_benefits.effective_contract_months IS
  'Contract duration (months) locked at the time the employee committed to a bike (committed_at set). '
  'NULL for benefits not yet committed — falls back to companies.contract_months in views.';


-- ============================================
-- 2. Update update_bike_benefit_status trigger
--    — snapshot terms when committed_at is first set
--    — clear snapshot if employee resets back to choose_bike
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

  -- Snapshot company contract terms the first time committed_at is set.
  -- This locks in the pricing so future company term changes don't affect
  -- this benefit's historical price.
  IF TG_OP = 'UPDATE'
     AND NEW.committed_at IS NOT NULL
     AND OLD.committed_at IS NULL
     AND NEW.effective_monthly_subsidy IS NULL THEN
    SELECT c.monthly_benefit_subsidy, c.contract_months
    INTO   NEW.effective_monthly_subsidy, NEW.effective_contract_months
    FROM   public.profiles pr
    JOIN   public.companies c ON c.id = pr.company_id
    WHERE  pr.user_id = NEW.user_id;
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
      -- Clear snapshot: employee restarted, terms will be re-snapped at next commit
      NEW.effective_monthly_subsidy   := NULL;
      NEW.effective_contract_months   := NULL;
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
-- 3. Employee-facing bike catalog view
--    Single query from the client — no joins needed.
--    Prices auto-adapt to the calling user's company terms.
-- ============================================

CREATE OR REPLACE VIEW public.bikes_with_my_pricing AS
SELECT
  b.*,
  c.monthly_benefit_subsidy,
  c.contract_months,
  GREATEST(
    0::numeric,
    b.full_price - (c.monthly_benefit_subsidy * c.contract_months::numeric)
  ) AS company_employee_price
FROM  public.bikes b
JOIN  public.profiles me ON me.user_id = auth.uid()
JOIN  public.companies c  ON c.id = me.company_id;

GRANT SELECT ON public.bikes_with_my_pricing TO authenticated;

COMMENT ON VIEW public.bikes_with_my_pricing IS
  'Bike catalog with employee-specific pricing. Uses auth.uid() to resolve the '
  'calling user''s company subsidy and contract terms automatically. '
  'Always reflects current company terms (live pricing for catalog browsing). '
  'company_employee_price is the computed value; bikes.employee_price is the static per-bike field.';


-- ============================================
-- 4. Update profile_invites_with_details
--    — bike_employee_price and monthly_benefit_price now use effective values
--      when available (committed benefits), falling back to live company values
--      for uncommitted or legacy records.
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

  -- Live company terms (for HR reference / catalog context)
  c.monthly_benefit_subsidy,
  c.contract_months,

  p.user_id,
  p.status                                                    AS profile_status,
  p.created_at                                                AS registered_at,
  COALESCE(p.first_name,   pi.first_name)                    AS first_name,
  COALESCE(p.last_name,    pi.last_name)                     AS last_name,
  COALESCE(p.description,  pi.description)                   AS description,
  COALESCE(p.department,   pi.department)                    AS department,
  COALESCE(p.hire_date,    pi.hire_date)                     AS hire_date,

  bb.id                                                       AS bike_benefit_id,
  bb.step                                                     AS current_step,
  bb.benefit_status,
  bb.contract_status,
  COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) AS last_modified_at,

  bb.bike_id,
  b.name                                                      AS bike_name,
  b.brand                                                     AS bike_brand,
  b.type                                                      AS bike_type,
  b.full_price                                                AS bike_full_price,

  -- Employee price: use locked terms for committed benefits, live terms otherwise
  CASE
    WHEN b.full_price IS NOT NULL THEN
      GREATEST(
        0::numeric,
        b.full_price - (
          COALESCE(bb.effective_monthly_subsidy, c.monthly_benefit_subsidy)
          * COALESCE(bb.effective_contract_months, c.contract_months)::numeric
        )
      )
    ELSE NULL::numeric
  END                                                         AS bike_employee_price,

  -- Monthly benefit price: locked value for committed benefits, live value otherwise
  COALESCE(bb.effective_monthly_subsidy, c.monthly_benefit_subsidy) AS monthly_benefit_price,

  -- Effective contract length for this specific benefit
  COALESCE(bb.effective_contract_months, c.contract_months)  AS effective_contract_months,

  -- Raw snapshot values (NULL until employee commits)
  bb.effective_monthly_subsidy,

  bb.committed_at,
  bb.delivered_at,
  bb.benefit_terminated_at,
  bb.benefit_insurance_claim_at,
  bb.contract_requested_at,
  bb.contract_viewed_at,
  bb.contract_employee_signed_at,
  bb.contract_employer_signed_at,
  bb.contract_approved_at,
  bb.contract_terminated_at,
  bb.live_test_location_coords,
  bb.live_test_location_name,
  bb.live_test_whatsapp_sent_at,
  bb.live_test_checked_in_at,

  bo.id                                                       AS order_id,
  bo.helmet                                                   AS ordered_helmet,
  bo.insurance                                                AS ordered_insurance

FROM       public.profile_invites pi
LEFT JOIN  public.companies       c  ON  pi.company_id = c.id
LEFT JOIN  public.profiles        p  ON  pi.email      = p.email
LEFT JOIN  public.bike_benefits   bb ON  p.user_id     = bb.user_id
LEFT JOIN  public.bikes           b  ON  bb.bike_id    = b.id
LEFT JOIN  public.bike_orders     bo ON  bb.id         = bo.bike_benefit_id
ORDER BY COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) DESC;
