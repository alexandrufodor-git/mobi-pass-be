-- ============================================================================
-- Location support: split text coords into lat/lon double precision columns
-- on dealers + bike_benefits, add home address to profiles, add work address
-- + contact_email to companies. Rebuild bikes_with_my_pricing view.
-- ============================================================================

-- ── 1. Profile: home address + coordinates ────────────────────────────────

ALTER TABLE public.profiles ADD COLUMN home_address text;
ALTER TABLE public.profiles ADD COLUMN home_lat     double precision;
ALTER TABLE public.profiles ADD COLUMN home_lon     double precision;

-- No RLS changes: profiles_self_select, profiles_self_update, and
-- hr_select_own_company_profiles have no column restrictions.

-- ── 2. Company: work address + coordinates + HR contact email ─────────────

ALTER TABLE public.companies ADD COLUMN address       text;
ALTER TABLE public.companies ADD COLUMN address_lat   double precision;
ALTER TABLE public.companies ADD COLUMN address_lon   double precision;
ALTER TABLE public.companies ADD COLUMN contact_email text;

-- No RLS changes: companies_employee_select and companies_hr_update
-- already cover all columns.

-- ── 3. Drop view that depends on dealers.location_coords ──────────────────

DROP VIEW IF EXISTS public.bikes_with_my_pricing;

-- ── 4. Dealers: split location_coords text → lat + lon columns ────────────

ALTER TABLE public.dealers ADD COLUMN lat double precision;
ALTER TABLE public.dealers ADD COLUMN lon double precision;

-- Migrate existing data: location_coords is "lon,lat" format
UPDATE public.dealers
SET lon = SPLIT_PART(location_coords, ',', 1)::double precision,
    lat = SPLIT_PART(location_coords, ',', 2)::double precision
WHERE location_coords IS NOT NULL;

ALTER TABLE public.dealers DROP COLUMN location_coords;

-- ── 5. Bike benefits: split live_test_location_coords → lat + lon ─────────

ALTER TABLE public.bike_benefits ADD COLUMN live_test_lat double precision;
ALTER TABLE public.bike_benefits ADD COLUMN live_test_lon double precision;

UPDATE public.bike_benefits
SET live_test_lon = SPLIT_PART(live_test_location_coords, ',', 1)::double precision,
    live_test_lat = SPLIT_PART(live_test_location_coords, ',', 2)::double precision
WHERE live_test_location_coords IS NOT NULL;

ALTER TABLE public.bike_benefits DROP COLUMN live_test_location_coords;

-- ── 6. Rebuild bikes_with_my_pricing view with lat/lon ────────────────────

CREATE OR REPLACE VIEW public.bikes_with_my_pricing
WITH (security_invoker = on) AS
SELECT
  b.id,
  b.name,
  b.created_at,
  b.updated_at,
  b.brand,
  b.description,
  b.image_url,
  b.full_price,
  b.employee_price,
  b.weight_kg,
  b.charge_time_hours,
  b.range_max_km,
  b.power_wh,
  b.engine,
  b.supported_features,
  b.frame_material,
  b.frame_size,
  b.wheel_size,
  b.wheel_bandwidth,
  b.lock_type,
  b.sku,
  d.name    AS dealer_name,
  d.address AS dealer_address,
  d.lat     AS dealer_lat,
  d.lon     AS dealer_lon,
  d.phone   AS dealer_phone,
  b.available_for_test,
  b.in_stock,
  b.type,
  b.images,
  c.monthly_benefit_subsidy,
  c.contract_months,
  c.contract_months AS employee_contract_month,
  c.currency,
  prices.employee_price        AS employee_full_price,
  prices.monthly_employee_price AS employee_monthly_price
FROM public.bikes b
  JOIN public.dealers d ON d.id = b.dealer_id
  LEFT JOIN public.profiles me ON me.user_id = auth.uid()
  LEFT JOIN public.companies c ON c.id = me.company_id
  LEFT JOIN LATERAL public.calc_employee_prices(
    b.full_price, c.monthly_benefit_subsidy, c.contract_months
  ) prices(employee_price, monthly_employee_price) ON true;

COMMENT ON VIEW public.bikes_with_my_pricing IS 'Bike catalog with employee-specific pricing and dealer info. Uses auth.uid() to resolve the calling user''s company subsidy and contract terms automatically. Returns all bikes; pricing columns are NULL when the user has no linked company.';
