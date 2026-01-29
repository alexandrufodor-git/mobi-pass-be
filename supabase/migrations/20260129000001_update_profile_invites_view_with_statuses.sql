-- ============================================
-- Update profile_invites_with_details view to include new status fields
-- ============================================
-- This migration updates the view to include benefit_status and contract_status
-- for the HR dashboard to display the new status tracking fields
-- ============================================

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
Includes benefit_status and contract_status for dashboard display.
Employees can see their own benefit status.';

-- ============================================
-- Example queries for frontend HR Dashboard
-- ============================================

-- Query 1: Get all employees with their benefit and contract status
-- SELECT 
--   email,
--   profile_status,
--   benefit_status,
--   contract_status,
--   current_step,
--   bike_name,
--   invited_at,
--   registered_at
-- FROM public.profile_invites_with_details 
-- WHERE company_id = (SELECT company_id FROM public.profiles WHERE user_id = auth.uid())
-- ORDER BY invited_at DESC;

-- Query 2: Get employees by benefit status (e.g., all in 'testing' phase)
-- SELECT 
--   email,
--   benefit_status,
--   current_step,
--   bike_name,
--   live_test_location_name,
--   live_test_whatsapp_sent_at
-- FROM public.profile_invites_with_details 
-- WHERE company_id = (SELECT company_id FROM public.profiles WHERE user_id = auth.uid())
--   AND benefit_status = 'testing'
-- ORDER BY live_test_whatsapp_sent_at DESC;

-- Query 3: Get employees by contract status (e.g., all waiting for employer signature)
-- SELECT 
--   email,
--   contract_status,
--   bike_name,
--   contract_employee_signed_at
-- FROM public.profile_invites_with_details 
-- WHERE company_id = (SELECT company_id FROM public.profiles WHERE user_id = auth.uid())
--   AND contract_status = 'signed_by_employee'
-- ORDER BY contract_employee_signed_at DESC;

-- Query 4: Get summary count by benefit status for HR dashboard
-- SELECT 
--   benefit_status,
--   COUNT(*) as count
-- FROM public.profile_invites_with_details 
-- WHERE company_id = (SELECT company_id FROM public.profiles WHERE user_id = auth.uid())
--   AND benefit_status IS NOT NULL
-- GROUP BY benefit_status
-- ORDER BY benefit_status;
