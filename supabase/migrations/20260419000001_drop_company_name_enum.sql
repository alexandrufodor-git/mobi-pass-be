-- Drop the company_name enum and make companies.name a plain text column
-- with a UNIQUE constraint. Adding a new company becomes an INSERT instead
-- of a migration per company.

-- Dependent view must be dropped before altering the column type.
DROP VIEW IF EXISTS public.profile_invites_with_details;

ALTER TABLE public.companies
  ALTER COLUMN name TYPE text USING name::text;

DROP TYPE IF EXISTS public.company_name;

ALTER TABLE public.companies
  ADD CONSTRAINT companies_name_key UNIQUE (name);

-- Recreate profile_invites_with_details (matches schema.sql definition).
CREATE OR REPLACE VIEW public.profile_invites_with_details
WITH (security_invoker = on) AS
SELECT
  pi.id              AS invite_id,
  pi.email,
  pi.status          AS invite_status,
  pi.created_at      AS invited_at,
  pi.company_id,
  c.name             AS company_name,
  c.logo_image_path,
  p.user_id,
  p.status           AS profile_status,
  p.created_at       AS registered_at,
  p.profile_image_path,
  COALESCE(p.first_name,  pi.first_name)  AS first_name,
  COALESCE(p.last_name,   pi.last_name)   AS last_name,
  COALESCE(p.description, pi.description) AS description,
  COALESCE(p.department,  pi.department)  AS department,
  COALESCE(p.hire_date,   pi.hire_date)   AS hire_date,
  bb.id              AS bike_benefit_id,
  bb.benefit_status,
  bb.contract_status,
  COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) AS last_modified_at,
  bb.bike_id,
  bo.id              AS order_id
FROM public.profile_invites pi
LEFT JOIN public.companies     c  ON pi.company_id = c.id
LEFT JOIN public.profiles      p  ON pi.email      = p.email
LEFT JOIN public.bike_benefits bb ON p.user_id     = bb.user_id
LEFT JOIN public.bikes         b  ON bb.bike_id    = b.id
LEFT JOIN public.bike_orders   bo ON bb.id         = bo.bike_benefit_id
ORDER BY COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) DESC;

ALTER VIEW public.profile_invites_with_details OWNER TO postgres;
