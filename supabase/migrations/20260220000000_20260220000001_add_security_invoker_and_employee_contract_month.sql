-- ============================================
-- Migration: Add security_invoker + employee_contract_month to views
-- ============================================
-- Changes to bikes_with_my_pricing:
--   - security_invoker = on (view executes with calling user's permissions)
--   - employee_contract_month: alias for c.contract_months
--   - currency remains explicit
-- Changes to profile_invites_with_details:
--   - security_invoker = on
-- ============================================


-- ============================================
-- 1. Rebuild bikes_with_my_pricing
-- ============================================

DROP VIEW IF EXISTS public.bikes_with_my_pricing;

CREATE VIEW public.bikes_with_my_pricing
  WITH (security_invoker = on)
AS
SELECT
  b.*,
  c.monthly_benefit_subsidy,
  c.contract_months,
  c.contract_months                                           AS employee_contract_month,
  c.currency,
  prices.employee_price         AS employee_full_price,
  prices.monthly_employee_price AS employee_monthly_price
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
  'employee_monthly_price = employee_full_price / contract_months. '
  'employee_contract_month = companies.contract_months for the calling user''s company.';


-- ============================================
-- 2. Rebuild profile_invites_with_details
-- ============================================

DROP VIEW IF EXISTS public.profile_invites_with_details;

CREATE VIEW public.profile_invites_with_details
  WITH (security_invoker = on)
AS
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
