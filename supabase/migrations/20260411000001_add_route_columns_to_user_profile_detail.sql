-- Add home/company coordinates and days_in_office to user_profile_detail view
-- so the mobile app can load route data in a single API call.

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
  c.address_lat    AS company_address_lat,
  c.address_lon    AS company_address_lon,
  c.days_in_office,
  p.user_id,
  p.profile_image_path,
  p.home_lat,
  p.home_lon,
  COALESCE(p.first_name, pi.first_name)   AS first_name,
  COALESCE(p.last_name,  pi.last_name)    AS last_name,
  COALESCE(p.description, pi.description) AS description,
  COALESCE(p.department,  pi.department)  AS department,
  COALESCE(p.hire_date,   pi.hire_date)   AS hire_date,
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
  b.name                     AS bike_name,
  b.brand                    AS bike_brand,
  b.images                   AS bike_images,
  b.weight_kg,
  b.charge_time_hours,
  b.range_max_km,
  b.power_wh,
  ct.sign_page_url,
  bo.helmet,
  bo.insurance
FROM public.profile_invites pi
LEFT JOIN public.companies     c  ON pi.company_id = c.id
LEFT JOIN public.profiles      p  ON pi.email      = p.email
LEFT JOIN public.bike_benefits bb ON p.user_id     = bb.user_id
LEFT JOIN public.bikes         b  ON bb.bike_id    = b.id
LEFT JOIN public.contracts     ct ON bb.id         = ct.bike_benefit_id
LEFT JOIN public.bike_orders   bo ON bb.id         = bo.bike_benefit_id;

ALTER VIEW public.user_profile_detail OWNER TO postgres;
