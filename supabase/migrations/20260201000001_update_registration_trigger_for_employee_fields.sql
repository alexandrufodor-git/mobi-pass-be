-- ============================================
-- Migration: Update user registration trigger to copy employee fields
-- Created: 2026-02-01
-- Description: Update handle_user_registration to copy firstName, lastName, description, department, and hireDate
-- ============================================

-- Drop existing triggers if they exist
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP TRIGGER IF EXISTS on_auth_user_updated ON auth.users;

-- Create or replace the trigger function
-- NOTE: Must use fully qualified type names (public.user_role, public.user_profile_status)
-- because this trigger runs in auth schema context, not public schema context
CREATE OR REPLACE FUNCTION public.handle_user_registration()
RETURNS TRIGGER AS $$
DECLARE
  v_company_id uuid;
  v_first_name text;
  v_last_name text;
  v_description text;
  v_department text;
  v_hire_date bigint;
BEGIN
  -- Only proceed if user has confirmed their email (via OTP verification)
  IF NEW.email_confirmed_at IS NOT NULL THEN

    -- 1. Resolve company_id and employee fields from profile_invites
    SELECT 
      pi.company_id,
      pi.first_name,
      pi.last_name,
      pi.description,
      pi.department,
      pi.hire_date
    INTO 
      v_company_id,
      v_first_name,
      v_last_name,
      v_description,
      v_department,
      v_hire_date
    FROM public.profile_invites pi
    WHERE LOWER(pi.email) = LOWER(NEW.email)
    LIMIT 1;

    -- Optional but STRONGLY recommended safety check
    IF v_company_id IS NULL THEN
      RAISE EXCEPTION
        'No active invite found for email %',
        NEW.email;
      -- or: RETURN NEW;  -- if you want silent failure
    END IF;
    
    -- 2. Automatically assign 'employee' role to new users
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, 'employee'::public.user_role)
    ON CONFLICT (user_id, role) DO NOTHING;
    
    -- 3. Create or update profile with employee fields
    INSERT INTO public.profiles (
      user_id, 
      email, 
      status, 
      company_id,
      first_name,
      last_name,
      description,
      department,
      hire_date
    )
    VALUES (
      NEW.id, 
      NEW.email, 
      'active'::public.user_profile_status, 
      v_company_id,
      v_first_name,
      v_last_name,
      v_description,
      v_department,
      v_hire_date
    )
    ON CONFLICT (user_id) 
    DO UPDATE SET 
      email = EXCLUDED.email,
      status = 'active'::public.user_profile_status,
      company_id = EXCLUDED.company_id,
      first_name = EXCLUDED.first_name,
      last_name = EXCLUDED.last_name,
      description = EXCLUDED.description,
      department = EXCLUDED.department,
      hire_date = EXCLUDED.hire_date;
    
    -- 4. Update profile_invites status to 'active'
    UPDATE public.profile_invites
    SET status = 'active'::public.user_profile_status
    WHERE LOWER(email) = LOWER(NEW.email);
    
    -- 5. Create a bike benefit for the user
    INSERT INTO public.bike_benefits (user_id)
    VALUES (NEW.id)
    ON CONFLICT DO NOTHING;
    
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger for new user creation (when OTP is verified AND password is set)
-- This ensures the trigger only fires when registration is COMPLETE
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  WHEN (NEW.email_confirmed_at IS NOT NULL AND NEW.encrypted_password IS NOT NULL)
  EXECUTE FUNCTION public.handle_user_registration();

-- Create trigger for user updates (when password is set/changed)
-- This handles cases where user verifies email first, then sets password later
CREATE TRIGGER on_auth_user_updated
  AFTER UPDATE ON auth.users
  FOR EACH ROW
  WHEN (
    NEW.email_confirmed_at IS NOT NULL AND 
    NEW.encrypted_password IS NOT NULL AND
    OLD.encrypted_password IS DISTINCT FROM NEW.encrypted_password
  )
  EXECUTE FUNCTION public.handle_user_registration();
