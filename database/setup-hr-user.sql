-- ============================================
-- Setup Script: Create HR Test User
-- ============================================
-- This script creates a complete HR user setup for testing
-- Run this after database reset to quickly set up an HR admin
--
-- User Details:
--   Email: testfrontend@yopmail.com
--   Role: HR
--   Password: Set via Supabase Auth (use password reset or admin panel)
-- ============================================

-- First, ensure we have a test company
-- (Check if it exists, if not create it)
INSERT INTO public.companies (id, name, monthly_benefit_subsidy, contract_months)
VALUES (
  '11111111-1111-1111-1111-111111111111'::uuid,
  'BigTech3',
  100,  -- €100/month subsidy
  36    -- 36 months contract
)
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  monthly_benefit_subsidy = EXCLUDED.monthly_benefit_subsidy,
  contract_months = EXCLUDED.contract_months;

-- Create auth user (if not exists via Supabase Auth)
-- NOTE: You must create the auth user via Supabase Dashboard or Auth API first
-- This script assumes the auth user already exists
-- If you need to create it programmatically:
-- 1. Use Supabase Dashboard > Authentication > Users > "Add User"
-- 2. Or use: supabase auth admin create-user testfrontend@yopmail.com --password your-password

-- For this script, we'll use a placeholder UUID
-- Replace this with the actual user_id from auth.users after creating the user
DO $$
DECLARE
  v_user_id uuid;
BEGIN
  -- Try to find existing auth user by email
  SELECT id INTO v_user_id
  FROM auth.users
  WHERE email = 'testfrontend@yopmail.com'
  LIMIT 1;

  -- If user doesn't exist in auth, we can't proceed
  -- (Must be created via Supabase Auth first)
  IF v_user_id IS NULL THEN
    RAISE NOTICE 'Auth user not found. Please create user testfrontend@yopmail.com via Supabase Dashboard first.';
    RAISE NOTICE 'Then run this script again.';
    RETURN;
  END IF;

  -- Create profile for HR user
  INSERT INTO public.profiles (user_id, email, status, company_id, first_name, last_name)
  VALUES (
    v_user_id,
    'testfrontend@yopmail.com',
    'active',
    '11111111-1111-1111-1111-111111111111'::uuid,
    'Test',
    'HR Admin'
  )
  ON CONFLICT (user_id) DO UPDATE SET
    email = EXCLUDED.email,
    status = EXCLUDED.status,
    company_id = EXCLUDED.company_id,
    first_name = EXCLUDED.first_name,
    last_name = EXCLUDED.last_name;

  -- Assign HR role
  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_user_id, 'hr')
  ON CONFLICT (user_id, role) DO NOTHING;

  RAISE NOTICE 'HR user setup completed successfully!';
  RAISE NOTICE 'User ID: %', v_user_id;
  RAISE NOTICE 'Email: testfrontend@yopmail.com';
  RAISE NOTICE 'Role: HR';
  RAISE NOTICE 'Company: Test Company';
END $$;

-- Verify the setup
SELECT 
  p.user_id,
  p.email,
  p.first_name,
  p.last_name,
  p.status,
  c.name as company_name,
  ur.role
FROM public.profiles p
  JOIN public.companies c ON p.company_id = c.id
  LEFT JOIN public.user_roles ur ON p.user_id = ur.user_id
WHERE p.email = 'testfrontend@yopmail.com';
