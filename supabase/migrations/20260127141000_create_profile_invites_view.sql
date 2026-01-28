-- ============================================
-- Create view for profile invites with related data
-- ============================================

-- This view joins profile_invites with profiles and bike_benefits
-- Useful for HR dashboard to see invite status and benefit enrollment
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
  
  -- Benefit progress indicators
  bb.committed_at,
  bb.contract_requested_at,
  bb.delivered_at,
  
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

-- Grant permissions
GRANT SELECT ON public.profile_invites_with_details TO authenticated;

-- RLS Policy for the view
ALTER VIEW public.profile_invites_with_details SET (security_invoker = true);

COMMENT ON VIEW public.profile_invites_with_details IS 
'Combined view of profile invites, user profiles, and bike benefits. 
HR can use this to track the entire employee bike benefit journey from invite to delivery.
Employees can see their own benefit status.';

-- ============================================
-- Create indexes for better query performance
-- ============================================

CREATE INDEX IF NOT EXISTS idx_profile_invites_company_id ON public.profile_invites(company_id);
CREATE INDEX IF NOT EXISTS idx_profiles_company_id ON public.profiles(company_id);

-- ============================================
-- Example queries for frontend
-- ============================================

-- Query 1: Get all invites with their benefit status for HR dashboard
-- SELECT * FROM public.profile_invites_with_details 
-- WHERE company_id = (SELECT company_id FROM public.profiles WHERE user_id = auth.uid())
-- ORDER BY invited_at DESC;

-- Query 2: Get employee's own benefit details
-- SELECT * FROM public.profile_invites_with_details 
-- WHERE user_id = auth.uid();

-- Query 3: Get all pending invites (not yet registered)
-- SELECT * FROM public.profile_invites_with_details 
-- WHERE user_id IS NULL AND invite_status = 'inactive'
-- AND company_id = (SELECT company_id FROM public.profiles WHERE user_id = auth.uid());

-- Query 4: Get all employees with active bike benefits
-- SELECT * FROM public.profile_invites_with_details 
-- WHERE bike_benefit_id IS NOT NULL 
-- AND company_id = (SELECT company_id FROM public.profiles WHERE user_id = auth.uid())
-- ORDER BY current_step;
