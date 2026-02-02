-- ============================================
-- Migration: Add employee profile fields
-- Created: 2026-02-01
-- Description: Add firstName, lastName, description, department, and hireDate to profiles and profile_invites
-- ============================================

-- Add columns to profile_invites table
-- These fields are captured during the invite/bulk-create process
ALTER TABLE public.profile_invites 
  ADD COLUMN first_name text NOT NULL,
  ADD COLUMN last_name text NOT NULL,
  ADD COLUMN description text,
  ADD COLUMN department text,
  ADD COLUMN hire_date bigint;

-- Add columns to profiles table
-- These fields are copied from profile_invites during user registration
ALTER TABLE public.profiles
  ADD COLUMN first_name text NOT NULL,
  ADD COLUMN last_name text NOT NULL,
  ADD COLUMN description text,
  ADD COLUMN department text,
  ADD COLUMN hire_date bigint;

-- Create indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_profiles_last_name ON public.profiles(last_name);
CREATE INDEX IF NOT EXISTS idx_profiles_department ON public.profiles(department) WHERE department IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_profiles_hire_date ON public.profiles(hire_date) WHERE hire_date IS NOT NULL;

-- Add comments for documentation
COMMENT ON COLUMN public.profiles.first_name IS 'Employee first name';
COMMENT ON COLUMN public.profiles.last_name IS 'Employee last name';
COMMENT ON COLUMN public.profiles.description IS 'Employee description or bio';
COMMENT ON COLUMN public.profiles.department IS 'Employee department or team';
COMMENT ON COLUMN public.profiles.hire_date IS 'Employee hire date as Unix timestamp in milliseconds';

COMMENT ON COLUMN public.profile_invites.first_name IS 'Employee first name';
COMMENT ON COLUMN public.profile_invites.last_name IS 'Employee last name';
COMMENT ON COLUMN public.profile_invites.description IS 'Employee description or bio';
COMMENT ON COLUMN public.profile_invites.department IS 'Employee department or team';
COMMENT ON COLUMN public.profile_invites.hire_date IS 'Employee hire date as Unix timestamp in milliseconds';
