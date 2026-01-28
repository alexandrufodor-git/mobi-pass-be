-- ============================================
-- Enhance bikes table with detailed fields
-- ============================================

-- Add bike type enum (only if it doesn't exist)
DO $$ BEGIN
  CREATE TYPE public.bike_type AS ENUM (
    'e_mtb_hardtail_29',
    'e_mtb_hardtail_27_5',
    'e_full_suspension_29',
    'e_full_suspension_27_5',
    'e_city_bike',
    'e_touring',
    'e_road_race',
    'e_cargo_bike',
    'e_kids_24'
  );
EXCEPTION WHEN duplicate_object THEN
  NULL; -- Type already exists, ignore
END $$;

-- Add new columns to bikes table
ALTER TABLE public.bikes
  ADD COLUMN IF NOT EXISTS type public.bike_type,
  ADD COLUMN IF NOT EXISTS brand TEXT,
  ADD COLUMN IF NOT EXISTS description TEXT,
  ADD COLUMN IF NOT EXISTS image_url TEXT,
  
  -- Price fields
  ADD COLUMN IF NOT EXISTS full_price DECIMAL(10, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS employee_price DECIMAL(10, 2),
  
  -- General details
  ADD COLUMN IF NOT EXISTS weight_kg DECIMAL(5, 2),
  ADD COLUMN IF NOT EXISTS charge_time_hours DECIMAL(4, 2),
  ADD COLUMN IF NOT EXISTS range_max_km INTEGER,
  ADD COLUMN IF NOT EXISTS power_wh INTEGER,
  
  -- Specifications
  ADD COLUMN IF NOT EXISTS engine TEXT,
  ADD COLUMN IF NOT EXISTS supported_features TEXT,
  ADD COLUMN IF NOT EXISTS frame_material TEXT,
  ADD COLUMN IF NOT EXISTS frame_size TEXT,
  ADD COLUMN IF NOT EXISTS wheel_size TEXT,
  ADD COLUMN IF NOT EXISTS wheel_bandwidth TEXT,
  ADD COLUMN IF NOT EXISTS lock_type TEXT,
  ADD COLUMN IF NOT EXISTS sku TEXT,
  
  -- Dealer information
  ADD COLUMN IF NOT EXISTS dealer_name TEXT DEFAULT 'Maros Bike',
  ADD COLUMN IF NOT EXISTS dealer_address TEXT DEFAULT 'Cluj Napoca str. Aurel Vlaicu Nr. 25',
  ADD COLUMN IF NOT EXISTS dealer_location_coords TEXT DEFAULT '23.62565635434891,46.780762423563985',
  
  -- Availability
  ADD COLUMN IF NOT EXISTS available_for_test BOOLEAN DEFAULT true,
  ADD COLUMN IF NOT EXISTS in_stock BOOLEAN DEFAULT true;

COMMENT ON COLUMN public.bikes.dealer_location_coords IS 'Dealer location in "lon,lat" format for test rides and pickup';

-- ============================================
-- Add benefit pricing to companies table
-- ============================================

ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS monthly_benefit_subsidy DECIMAL(10, 2) DEFAULT 72.00,
  ADD COLUMN IF NOT EXISTS contract_months INTEGER DEFAULT 36;

COMMENT ON COLUMN public.companies.monthly_benefit_subsidy IS 'Monthly subsidy amount the company provides for bike benefits (e.g., €72/month)';
COMMENT ON COLUMN public.companies.contract_months IS 'Standard contract duration in months for bike benefits (e.g., 36 months)';

-- ============================================
-- Fix location fields in bike_benefits
-- ============================================

-- Keep location as TEXT in "lon,lat" format for simplicity
ALTER TABLE public.bike_benefits
  ADD COLUMN IF NOT EXISTS live_test_location_coords TEXT,
  ADD COLUMN IF NOT EXISTS live_test_location_name TEXT;

COMMENT ON COLUMN public.bike_benefits.live_test_location_coords IS 'Location coordinates in "lon,lat" format (e.g., "23.5880556,46.7712101")';
COMMENT ON COLUMN public.bike_benefits.live_test_location_name IS 'Human-readable name of the test location (e.g., "Maros Bike Cluj")';

-- ============================================
-- Add relationship between profile_invites and profiles
-- ============================================

-- Add user_id to profile_invites to link with profiles after registration
ALTER TABLE public.profile_invites
  ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES public.profiles(user_id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_profile_invites_user_id ON public.profile_invites(user_id);

COMMENT ON COLUMN public.profile_invites.user_id IS 'Links to the user profile after they complete registration';

-- ============================================
-- Update trigger to link profile_invites with profiles
-- ============================================

CREATE OR REPLACE FUNCTION public.handle_user_registration()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_company_id uuid;
BEGIN
  -- Only proceed if user has confirmed their email (via OTP verification)
  IF NEW.email_confirmed_at IS NOT NULL THEN

    -- 1. Resolve company_id from profile_invites
    SELECT pi.company_id
    INTO v_company_id
    FROM public.profile_invites pi
    WHERE LOWER(pi.email) = LOWER(NEW.email)
    LIMIT 1;

    -- Safety check
    IF v_company_id IS NULL THEN
      RAISE EXCEPTION 'No active invite found for email %', NEW.email;
    END IF;
    
    -- 2. Automatically assign 'employee' role to new users
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, 'employee'::public.user_role)
    ON CONFLICT (user_id, role) DO NOTHING;
    
    -- 3. Create or update profile
    INSERT INTO public.profiles (user_id, email, status, company_id)
    VALUES (NEW.id, NEW.email, 'active'::public.user_profile_status, v_company_id)
    ON CONFLICT (user_id) 
    DO UPDATE SET 
      email = EXCLUDED.email,
      status = 'active'::public.user_profile_status,
      company_id = EXCLUDED.company_id;
    
    -- 4. Update profile_invites status to 'active' and link to user
    UPDATE public.profile_invites
    SET 
      status = 'active'::public.user_profile_status,
      user_id = NEW.id
    WHERE LOWER(email) = LOWER(NEW.email);
    
    -- 5. Create a bike benefit for the user
    INSERT INTO public.bike_benefits (user_id)
    VALUES (NEW.id)
    ON CONFLICT DO NOTHING;
    
  END IF;
  
  RETURN NEW;
END;
$function$;

-- ============================================
-- Insert sample bikes from Maros Bike
-- ============================================

-- Cube Reaction Hybrid Performance 600 - E-MTB Hardtail 29" (Multiple size variants)
INSERT INTO public.bikes (
  name, type, brand, description, image_url,
  full_price, weight_kg, charge_time_hours, range_max_km, power_wh,
  engine, supported_features, frame_material, frame_size,
  wheel_size, wheel_bandwidth, lock_type, sku,
  available_for_test, in_stock
) VALUES 
(
  'Cube REACTION HYBRID PERFORMANCE 600',
  'e_mtb_hardtail_29',
  'Cube',
  'High-performance electric mountain bike with Bosch motor and 29" wheels. Perfect for both trail and city riding.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/105/rea-hyb-perf-600-electricblue_dazzle_23.png',
  13199.00, 23.5, 4.5, 120, 600,
  'Bosch Performance CX Generation 4 (85Nm)',
  'Eco, Tour, eMTB, Turbo',
  'Aluminium Superlite',
  'M (18")',
  '29 inches', '30mm', 'Frame lock compatible', 'CUBE-RHP600-29-M',
  true, true
),
(
  'Cube REACTION HYBRID PERFORMANCE 600',
  'e_mtb_hardtail_29',
  'Cube',
  'High-performance electric mountain bike with Bosch motor and 29" wheels. Perfect for both trail and city riding.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/105/rea-hyb-perf-600-electricblue_dazzle_23.png',
  13199.00, 23.5, 4.5, 120, 600,
  'Bosch Performance CX Generation 4 (85Nm)',
  'Eco, Tour, eMTB, Turbo',
  'Aluminium Superlite',
  'L (20")',
  '29 inches', '30mm', 'Frame lock compatible', 'CUBE-RHP600-29-L',
  true, true
),
(
  'Cube REACTION HYBRID PERFORMANCE 600',
  'e_mtb_hardtail_29',
  'Cube',
  'High-performance electric mountain bike with Bosch motor and 29" wheels. Perfect for both trail and city riding.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/105/rea-hyb-perf-600-electricblue_dazzle_23.png',
  13199.00, 23.5, 4.5, 120, 600,
  'Bosch Performance CX Generation 4 (85Nm)',
  'Eco, Tour, eMTB, Turbo',
  'Aluminium Superlite',
  'XL (22")',
  '29 inches', '30mm', 'Frame lock compatible', 'CUBE-RHP600-29-XL',
  true, true
),
(
  'Cube REACTION HYBRID PERFORMANCE 600',
  'e_mtb_hardtail_29',
  'Cube',
  'High-performance electric mountain bike with Bosch motor and 29" wheels. Perfect for both trail and city riding.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/105/rea-hyb-perf-600-electricblue_dazzle_23.png',
  13199.00, 23.5, 4.5, 120, 600,
  'Bosch Performance CX Generation 4 (85Nm)',
  'Eco, Tour, eMTB, Turbo',
  'Aluminium Superlite',
  'XXL (23")',
  '29 inches', '30mm', 'Frame lock compatible', 'CUBE-RHP600-29-XXL',
  true, true
);

-- Cube Stereo Hybrid ONE77 - E-Full Suspension 29" (Size variants)
INSERT INTO public.bikes (
  name, type, brand, description, image_url,
  full_price, weight_kg, charge_time_hours, range_max_km, power_wh,
  engine, supported_features, frame_material, frame_size,
  wheel_size, wheel_bandwidth, lock_type, sku,
  available_for_test, in_stock
) VALUES 
(
  'Cube STEREO HYBRID ONE77 HPC SLX 800',
  'e_full_suspension_29',
  'Cube',
  'Premium full suspension eBike with 800Wh battery for maximum range and performance on demanding trails.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/105/ste-hyb-one77-hpc-slx-800-blackline_23.png',
  26099.00, 24.9, 6.0, 150, 800,
  'Bosch Performance CX Generation 4 (85Nm)',
  'Eco, Tour, eMTB, Turbo',
  'Aluminium Superlite',
  'M',
  '29 inches', '30mm', 'Integrated frame lock', 'CUBE-SHONE77-29-M',
  true, true
),
(
  'Cube STEREO HYBRID ONE77 HPC SLX 800',
  'e_full_suspension_29',
  'Cube',
  'Premium full suspension eBike with 800Wh battery for maximum range and performance on demanding trails.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/105/ste-hyb-one77-hpc-slx-800-blackline_23.png',
  26099.00, 24.9, 6.0, 150, 800,
  'Bosch Performance CX Generation 4 (85Nm)',
  'Eco, Tour, eMTB, Turbo',
  'Aluminium Superlite',
  'L',
  '29 inches', '30mm', 'Integrated frame lock', 'CUBE-SHONE77-29-L',
  true, true
),
(
  'Cube STEREO HYBRID ONE77 HPC SLX 800',
  'e_full_suspension_29',
  'Cube',
  'Premium full suspension eBike with 800Wh battery for maximum range and performance on demanding trails.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/105/ste-hyb-one77-hpc-slx-800-blackline_23.png',
  26099.00, 24.9, 6.0, 150, 800,
  'Bosch Performance CX Generation 4 (85Nm)',
  'Eco, Tour, eMTB, Turbo',
  'Aluminium Superlite',
  'XL',
  '29 inches', '30mm', 'Integrated frame lock', 'CUBE-SHONE77-29-XL',
  true, true
);

-- Cube Nuride Hybrid Performance - E-City Bike (Sample size)
INSERT INTO public.bikes (
  name, type, brand, description, image_url,
  full_price, weight_kg, charge_time_hours, range_max_km, power_wh,
  engine, supported_features, frame_material, frame_size,
  wheel_size, wheel_bandwidth, lock_type, sku,
  available_for_test, in_stock
) VALUES (
  'Cube NURIDE HYBRID PERFORMANCE 600',
  'e_city_bike',
  'Cube',
  'Comfortable city eBike with easy entry frame, perfect for daily commuting and urban adventures.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/105/nur-hyb-perf-600-ee-desertstone_grey_23.png',
  13799.00, 22.6, 4.5, 110, 600,
  'Bosch Performance Generation 3 (75Nm)',
  'Eco, Tour, Sport, Turbo',
  'Aluminium',
  '54cm',
  '28 inches', '40mm', 'Ring and cable lock', 'CUBE-NHP600-28-54',
  true, true
);

-- Cube Kathmandu Hybrid - E-Touring
INSERT INTO public.bikes (
  name, type, brand, description, image_url,
  full_price, weight_kg, charge_time_hours, range_max_km, power_wh,
  engine, supported_features, frame_material, frame_size,
  wheel_size, wheel_bandwidth, lock_type, sku,
  available_for_test, in_stock
) VALUES (
  'Cube KATHMANDU HYBRID PRO 800',
  'e_touring',
  'Cube',
  'Long-range touring eBike with 800Wh battery, equipped with racks and fenders for extended adventures.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/105/kat-hyb-pro-800-ee-electric_red_23.png',
  18994.99, 25.6, 6.0, 140, 800,
  'Bosch Performance CX Generation 4 (85Nm)',
  'Eco, Tour, eMTB, Turbo',
  'Aluminium',
  '54cm',
  '28 inches', '47mm', 'AXA Defender frame lock', 'CUBE-KHP800-28-54',
  true, true
);

-- Additional sample bikes (single size examples - add more variants as needed)
INSERT INTO public.bikes (
  name, type, brand, description, image_url,
  full_price, weight_kg, charge_time_hours, range_max_km, power_wh,
  engine, supported_features, frame_material, frame_size,
  wheel_size, wheel_bandwidth, lock_type, sku,
  available_for_test, in_stock
) VALUES 
(
  'Focus SAM 2 6.8',
  'e_full_suspension_29',
  'Focus',
  'Aggressive trail eBike with powerful motor and exceptional suspension for technical terrain.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/98/focus-sam-2-6.8-grey.jpg',
  29745.75, 23.9, 5.5, 130, 625,
  'Shimano Steps E8000',
  'Eco, Trail, Boost',
  'Carbon',
  'L',
  '29 inches', '30mm', 'Frame lock compatible', 'FOCUS-SAM268-29-L',
  true, true
),
(
  'Amflow PL CARBON PRO',
  'e_full_suspension_29',
  'Amflow',
  'Premium carbon eBike with cutting-edge technology and exceptional build quality.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/105/amflow-pl-carbon-pro-cosmic_black.png',
  50199.00, 21.5, 5.0, 160, 800,
  'DJI Avinox Drive System',
  'Eco, Normal, Sport, Turbo',
  'Carbon',
  'L',
  '29 inches', '30mm', 'Smart lock system', 'AMFLOW-PLCP-29-L',
  true, true
),
(
  'Cube COMPACT HYBRID 545',
  'e_city_bike',
  'Cube',
  'Compact folding eBike perfect for commuters with limited storage space.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/105/com-hyb-545-royalgreen_black_23.png',
  13750.00, 22.0, 4.0, 90, 545,
  'Bosch Active Line Plus',
  'Eco, Tour, Sport, Turbo',
  'Aluminium',
  'One Size',
  '20 inches', '47mm', 'Folding lock included', 'CUBE-CH545-20-OS',
  true, true
),
(
  'Cube ACID 240 HYBRID ROOKIE SLX 400X',
  'e_kids_24',
  'Cube',
  'Junior eBike designed for young riders, with appropriate power and safety features.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/105/aci-240-hyb-roo-slx-400x-reedgreen_matrix_23.png',
  13750.00, 18.5, 3.5, 70, 400,
  'Shimano Steps E5000',
  'Eco, Normal, High',
  'Aluminium',
  '24"',
  '24 inches', '28mm', 'Cable lock included', 'CUBE-A240-24-OS',
  true, true
),
(
  'Marin RIFT ZONE E2 SM',
  'e_full_suspension_29',
  'Marin',
  'Trail-ready eMTB with balanced geometry and reliable Shimano drive system.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/98/marin-rift-zone-e2-sand_black.jpg',
  19499.90, 24.2, 5.0, 125, 630,
  'Shimano Steps E7000',
  'Eco, Trail, Boost',
  'Aluminium',
  'M',
  '29 inches', '30mm', 'Frame lock compatible', 'MARIN-RZE2-29-M',
  true, true
),
(
  'Cube TRIKE HYBRID CARGO 750',
  'e_cargo_bike',
  'Cube',
  'Three-wheel cargo eBike with massive loading capacity for family trips or deliveries.',
  'https://www.marosbike.ro/images/thumbnails/700/1050/detailed/105/tri-hyb-car-750-grey_reflex_23.png',
  33799.99, 70.0, 7.5, 100, 750,
  'Bosch Cargo Line Generation 4 (85Nm)',
  'Eco, Tour, Sport, Turbo',
  'Aluminium',
  'One Size',
  '20"/26" mixed', '65mm', 'Integrated AXA lock', 'CUBE-THC750-OS',
  true, true
);

-- NOTE: Add more size variants by duplicating entries with different frame_size and sku values

-- ============================================
-- Update existing companies with benefit pricing
-- ============================================

UPDATE public.companies
SET 
  monthly_benefit_subsidy = 72.00,
  contract_months = 36
WHERE monthly_benefit_subsidy IS NULL;

-- ============================================
-- Create helper function to calculate employee price
-- ============================================

CREATE OR REPLACE FUNCTION public.calculate_employee_bike_price(
  p_full_price DECIMAL,
  p_company_id UUID
)
RETURNS DECIMAL
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_monthly_subsidy DECIMAL;
  v_contract_months INTEGER;
  v_total_subsidy DECIMAL;
  v_employee_price DECIMAL;
BEGIN
  -- Get company benefit details
  SELECT monthly_benefit_subsidy, contract_months
  INTO v_monthly_subsidy, v_contract_months
  FROM public.companies
  WHERE id = p_company_id;
  
  -- Calculate total subsidy over contract period
  v_total_subsidy := v_monthly_subsidy * v_contract_months;
  
  -- Calculate employee price (full price minus company subsidy)
  v_employee_price := p_full_price - v_total_subsidy;
  
  -- Ensure price doesn't go below 0
  IF v_employee_price < 0 THEN
    v_employee_price := 0;
  END IF;
  
  RETURN v_employee_price;
END;
$$;

COMMENT ON FUNCTION public.calculate_employee_bike_price IS 
'Calculates the employee price for a bike based on company subsidy. Formula: full_price - (monthly_subsidy * contract_months)';

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.calculate_employee_bike_price TO authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_employee_bike_price TO service_role;
