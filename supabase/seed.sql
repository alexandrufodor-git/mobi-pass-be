-- ============================================================================
-- Seed Data for Local Development
-- ============================================================================
-- This file contains test data for local development and testing.
-- It will be automatically loaded when you run: supabase db reset
-- ============================================================================

-- Clear existing data (in correct order to respect foreign keys)
TRUNCATE TABLE public.bike_orders CASCADE;
TRUNCATE TABLE public.bike_benefits CASCADE;
TRUNCATE TABLE public.bikes CASCADE;
TRUNCATE TABLE public.user_roles CASCADE;
TRUNCATE TABLE public.profiles CASCADE;
TRUNCATE TABLE public.profile_invites CASCADE;
TRUNCATE TABLE public.companies CASCADE;

-- ============================================================================
-- Companies with benefit pricing
-- ============================================================================
INSERT INTO public.companies (id, name, description, monthly_benefit_subsidy, contract_months) VALUES
  ('11111111-1111-1111-1111-111111111111'::uuid, '8x8', 'Communications company offering bike benefits', 72.00, 36),
  ('22222222-2222-2222-2222-222222222222'::uuid, 'BigTech1', 'Large tech company with generous bike subsidy', 100.00, 36),
  ('33333333-3333-3333-3333-333333333333'::uuid, 'SmallTech2', 'Startup with standard bike benefits', 50.00, 24);

-- ============================================================================
-- Profile Invites
-- ============================================================================
-- Add test invites so users can register via OTP
INSERT INTO public.profile_invites (email, status, company_id) VALUES
  ('test@example.com', 'inactive', '11111111-1111-1111-1111-111111111111'::uuid),
  ('admin@example.com', 'inactive', '11111111-1111-1111-1111-111111111111'::uuid),
  ('hr@example.com', 'inactive', '11111111-1111-1111-1111-111111111111'::uuid),
  ('someonestolemyyahoo@gmail.com', 'inactive', '22222222-2222-2222-2222-222222222222'::uuid);

-- ============================================================================
-- Notes for Testing
-- ============================================================================
-- To test the register flow locally:
-- 
-- 1. Start Supabase:
--    supabase start
--
-- 2. Reset database (applies migrations + seeds):
--    supabase db reset
--
-- 3. Test register endpoint:
--    curl -X POST http://127.0.0.1:54321/functions/v1/register \
--      -H "Content-Type: application/json" \
--      -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0" \
--      -d '{"email":"test@example.com"}'
--
-- 4. Check Inbucket for OTP email:
--    http://127.0.0.1:54324
--
-- 5. After OTP verification, check that:
--    - profile was created in public.profiles
--    - user_role 'employee' was assigned in public.user_roles
--    - profile_invites status changed to 'active'

