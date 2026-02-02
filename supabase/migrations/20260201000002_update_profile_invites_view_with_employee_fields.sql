-- ============================================
-- Update profile_invites_with_details view to include employee fields
-- ============================================
-- This migration updates the view to include the new employee fields:
-- first_name, last_name, description, department, hire_date
-- Note: We must DROP and recreate the view because PostgreSQL doesn't allow
-- changing column order with CREATE OR REPLACE VIEW
-- ============================================

DROP VIEW IF EXISTS public.profile_invites_with_details;

CREATE VIEW public.profile_invites_with_details AS
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
  
  -- Employee data (from profile if registered, otherwise from invite)
  COALESCE(p.first_name, pi.first_name) AS first_name,
  COALESCE(p.last_name, pi.last_name) AS last_name,
  COALESCE(p.description, pi.description) AS description,
  COALESCE(p.department, pi.department) AS department,
  COALESCE(p.hire_date, pi.hire_date) AS hire_date,
  
  -- Bike benefit data (will be NULL if user hasn't started benefit process)
  bb.id AS bike_benefit_id,
  bb.step AS current_step,
  
  -- Status fields for HR dashboard
  bb.benefit_status,
  bb.contract_status,
  
  -- Bike data
  bb.bike_id,
  b.name AS bike_name,
  b.brand AS bike_brand,
  b.type AS bike_type,
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
'Combined view of profile invites, user profiles, and bike benefits with status tracking and employee information. 
HR can use this to track the entire employee bike benefit journey from invite to delivery.
Includes benefit_status, contract_status, and employee details (name, department, hire date, etc.) for dashboard display.
Employee data is taken from the profile table if registered, otherwise from the invite table.';

-- ============================================
-- Example queries for frontend HR Dashboard
-- ============================================

-- Query 1: Get all employees with their benefit, contract status, and employee details
-- SELECT 
--   email,
--   first_name,
--   last_name,
--   department,
--   hire_date,
--   profile_status,
--   benefit_status,
--   contract_status,
--   current_step,
--   bike_name,
--   invited_at,
--   registered_at
-- FROM public.profile_invites_with_details 
-- WHERE company_id = (SELECT company_id FROM public.profiles WHERE user_id = auth.uid())
-- ORDER BY last_name, first_name;

-- Query 2: Get employees by department
-- SELECT 
--   department,
--   first_name,
--   last_name,
--   email,
--   benefit_status,
--   contract_status
-- FROM public.profile_invites_with_details 
-- WHERE company_id = (SELECT company_id FROM public.profiles WHERE user_id = auth.uid())
--   AND department IS NOT NULL
-- ORDER BY department, last_name, first_name;

-- Query 3: Get employees by hire date (newest first)
-- SELECT 
--   first_name,
--   last_name,
--   email,
--   department,
--   hire_date,
--   benefit_status
-- FROM public.profile_invites_with_details 
-- WHERE company_id = (SELECT company_id FROM public.profiles WHERE user_id = auth.uid())
--   AND hire_date IS NOT NULL
-- ORDER BY hire_date DESC;
