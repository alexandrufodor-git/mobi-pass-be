-- Recreate user_profile_detail view with missing columns:
-- bb.delivered_at, c.contact_email, bo.helmet, bo.insurance

DROP VIEW IF EXISTS public.user_profile_detail;

CREATE OR REPLACE VIEW public.user_profile_detail
WITH (security_invoker = on) AS
SELECT
  pi.id            AS invite_id,
  pi.email,
  pi.status        AS invite_status,
  pi.company_id,
  c.name           AS company_name,
  c.logo_image_path,
  c.contact_email  AS company_contact_email,
  p.user_id,
  p.profile_image_path,
  COALESCE(p.first_name, pi.first_name)   AS first_name,
  COALESCE(p.last_name,  pi.last_name)    AS last_name,
  COALESCE(p.description, pi.description) AS description,
  COALESCE(p.department,  pi.department)  AS department,
  COALESCE(p.hire_date,   pi.hire_date)   AS hire_date,
  -- bike_benefits
  bb.id                      AS bike_benefit_id,
  bb.benefit_status,
  bb.contract_status,
  bb.bike_id,
  bb.employee_monthly_price,
  bb.employee_full_price,
  bb.employee_contract_months,
  bb.employee_currency,
  bb.contract_approved_at,
  bb.delivered_at,
  -- bikes
  b.name                     AS bike_name,
  b.brand                    AS bike_brand,
  b.images                   AS bike_images,
  b.weight_kg,
  b.charge_time_hours,
  b.range_max_km,
  b.power_wh,
  -- contracts
  ct.sign_page_url,
  -- bike_orders
  bo.helmet,
  bo.insurance
FROM public.profile_invites pi
LEFT JOIN public.companies     c  ON pi.company_id = c.id
LEFT JOIN public.profiles      p  ON pi.email      = p.email
LEFT JOIN public.bike_benefits bb ON p.user_id     = bb.user_id
LEFT JOIN public.bikes         b  ON bb.bike_id    = b.id
LEFT JOIN public.contracts     ct ON bb.id         = ct.bike_benefit_id
LEFT JOIN public.bike_orders   bo ON bb.id         = bo.bike_benefit_id;
