-- ============================================
-- Fix bikes.type column - Re-add after CASCADE drop
-- ============================================
-- The bike_type enum was dropped with CASCADE in a previous migration,
-- which removed the bikes.type column. This migration re-adds it.
-- ============================================

-- ============================================
-- 1. Ensure bike_type enum exists with correct values
-- ============================================
-- Create the enum if it doesn't exist (it should exist from previous migration)
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
  NULL; -- Type already exists, which is good
END $$;

COMMENT ON TYPE public.bike_type IS 'Types of electric bikes available in the system';

-- ============================================
-- 2. Re-add type column to bikes table
-- ============================================
ALTER TABLE public.bikes
  ADD COLUMN IF NOT EXISTS type public.bike_type;

COMMENT ON COLUMN public.bikes.type IS 'Type/category of the bike (e.g., e-MTB, e-city, e-touring)';

-- ============================================
-- 3. Create index for better query performance
-- ============================================
CREATE INDEX IF NOT EXISTS idx_bikes_type ON public.bikes(type);

-- ============================================
-- 4. Update existing bikes based on name/description (best effort)
-- ============================================
-- Try to infer the type from bike names for existing records
-- This is a best-effort approach based on common naming patterns

UPDATE public.bikes
SET type = CASE
  -- Full suspension bikes
  WHEN LOWER(name) LIKE '%stereo%' OR LOWER(name) LIKE '%full suspension%' 
    THEN 'e_full_suspension_29'::public.bike_type
  WHEN LOWER(name) LIKE '%sam%' OR LOWER(name) LIKE '%rift zone%' 
    THEN 'e_full_suspension_29'::public.bike_type
  WHEN LOWER(name) LIKE '%amflow%' 
    THEN 'e_full_suspension_29'::public.bike_type
    
  -- Hardtail bikes
  WHEN LOWER(name) LIKE '%reaction%' AND LOWER(name) LIKE '%29%'
    THEN 'e_mtb_hardtail_29'::public.bike_type
  WHEN LOWER(name) LIKE '%reaction%' 
    THEN 'e_mtb_hardtail_29'::public.bike_type
    
  -- City bikes
  WHEN LOWER(name) LIKE '%nuride%' OR LOWER(name) LIKE '%city%'
    THEN 'e_city_bike'::public.bike_type
  WHEN LOWER(name) LIKE '%compact%'
    THEN 'e_city_bike'::public.bike_type
    
  -- Touring bikes
  WHEN LOWER(name) LIKE '%kathmandu%' OR LOWER(name) LIKE '%touring%'
    THEN 'e_touring'::public.bike_type
    
  -- Cargo bikes
  WHEN LOWER(name) LIKE '%trike%' OR LOWER(name) LIKE '%cargo%'
    THEN 'e_cargo_bike'::public.bike_type
    
  -- Kids bikes
  WHEN LOWER(name) LIKE '%acid 240%' OR LOWER(name) LIKE '%240%'
    THEN 'e_kids_24'::public.bike_type
    
  -- Default to hardtail 29 if unsure
  ELSE 'e_mtb_hardtail_29'::public.bike_type
END
WHERE type IS NULL;

-- ============================================
-- 5. Update profile_invites_with_details view to include bike_type
-- ============================================
-- Now that bikes.type column exists, we can add it to the view
CREATE OR REPLACE VIEW public.profile_invites_with_details AS
SELECT 
  pi.id AS invite_id,
  pi.email,
  pi.status AS invite_status,
  pi.created_at AS invited_at,
  pi.company_id,
  c.name AS company_name,
  c.monthly_benefit_subsidy,
  c.contract_months,
  
  -- Profile data (will be NULL if user hasn't registered yet)
  p.user_id,
  p.status AS profile_status,
  p.created_at AS registered_at,
  
  -- Bike benefit data (will be NULL if user hasn't started benefit process)
  bb.id AS bike_benefit_id,
  bb.step AS current_step,
  
  -- NEW: Status fields for HR dashboard
  bb.benefit_status,
  bb.contract_status,
  
  -- Bike data
  bb.bike_id,
  b.name AS bike_name,
  b.brand AS bike_brand,
  b.type AS bike_type,  -- NOW WORKS because bikes.type column exists
  b.full_price AS bike_full_price,
  
  -- Calculate employee price based on company benefit
  CASE 
    WHEN b.full_price IS NOT NULL THEN
      GREATEST(0, b.full_price - (c.monthly_benefit_subsidy * c.contract_months))
    ELSE NULL
  END AS bike_employee_price,
  
  -- Calculate monthly benefit price (what company pays)
  c.monthly_benefit_subsidy AS monthly_benefit_price,
  
  -- Benefit progress timestamps
  bb.committed_at,
  bb.delivered_at,
  bb.benefit_terminated_at,
  bb.benefit_insurance_claim_at,
  
  -- Contract timestamps
  bb.contract_requested_at,
  bb.contract_viewed_at,
  bb.contract_employee_signed_at,
  bb.contract_employer_signed_at,
  bb.contract_approved_at,
  bb.contract_terminated_at,
  
  -- Test location
  bb.live_test_location_coords,
  bb.live_test_location_name,
  bb.live_test_whatsapp_sent_at,
  bb.live_test_checked_in_at,
  
  -- Order details
  bo.id AS order_id,
  bo.helmet AS ordered_helmet,
  bo.insurance AS ordered_insurance
  
FROM public.profile_invites pi
  LEFT JOIN public.companies c ON pi.company_id = c.id
  LEFT JOIN public.profiles p ON pi.user_id = p.user_id
  LEFT JOIN public.bike_benefits bb ON p.user_id = bb.user_id
  LEFT JOIN public.bikes b ON bb.bike_id = b.id
  LEFT JOIN public.bike_orders bo ON bb.id = bo.bike_benefit_id;

COMMENT ON VIEW public.profile_invites_with_details IS 
'Combined view of profile invites, user profiles, and bike benefits with status tracking. 
HR can use this to track the entire employee bike benefit journey from invite to delivery.
Includes benefit_status, contract_status, and bike_type for dashboard display.';

-- ============================================
-- 6. Grant permissions
-- ============================================
-- Ensure authenticated users can query the updated view
GRANT SELECT ON public.profile_invites_with_details TO authenticated;
ALTER VIEW public.profile_invites_with_details SET (security_invoker = true);
