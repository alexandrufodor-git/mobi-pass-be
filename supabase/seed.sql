-- ============================================================================
-- Seed Data for Local Development
-- ============================================================================
-- This file contains test data for local development and testing.
-- It will be automatically loaded when you run: supabase db reset
-- ============================================================================

-- Clear existing data (in correct order to respect foreign keys)
TRUNCATE TABLE public.user_roles CASCADE;
TRUNCATE TABLE public.profiles CASCADE;
TRUNCATE TABLE public.profile_invites CASCADE;

-- ============================================================================
-- Profile Invites
-- ============================================================================
-- Add test invites so users can register via OTP
INSERT INTO public.profile_invites (email, status) VALUES
  ('test@example.com', 'inactive'),
  ('admin@example.com', 'inactive'),
  ('hr@example.com', 'inactive'),
  ('someonestolemyyahoo@gmail.com', 'inactive');

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

