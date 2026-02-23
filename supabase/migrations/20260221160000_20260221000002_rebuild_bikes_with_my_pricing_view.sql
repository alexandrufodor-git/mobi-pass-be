-- ============================================
-- Rebuild bikes_with_my_pricing to pick up the
-- new `images` JSONB column added in 20260221000001.
-- PostgreSQL expands b.* at view creation time so the view
-- must be recreated after schema changes to bikes.
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
