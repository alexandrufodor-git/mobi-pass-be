-- ============================================================================
-- User Registration Trigger - Update to include bike benefit creation
-- ============================================================================
-- This migration updates the handle_user_registration trigger to also create
-- a bike benefit record when a user registers.
--
-- Actions performed:
-- 1. Assigns 'employee' role to new users
-- 2. Creates/updates profile record (also fixes company_id column bug)
-- 3. Sets profile_invites status to 'active'
-- 4. Creates a bike benefit record for the user
--
-- Triggers:
-- - on_auth_user_created: Fires when user verifies OTP (email_confirmed_at set)
-- - on_auth_user_updated: Fires when user sets/changes password
-- ============================================================================

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
BEGIN
  -- Only proceed if user has confirmed their email (via OTP verification)
  IF NEW.email_confirmed_at IS NOT NULL THEN

    -- 1. Resolve company_id from profile_invites
    SELECT pi.company_id
    INTO v_company_id
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
    
    -- 1. Automatically assign 'employee' role to new users
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, 'employee'::public.user_role)
    ON CONFLICT (user_id, role) DO NOTHING;
    
    -- 2. Create or update profile (fixed: added company_id to column list)
    INSERT INTO public.profiles (user_id, email, status, company_id)
    VALUES (NEW.id, NEW.email, 'active'::public.user_profile_status, v_company_id)
    ON CONFLICT (user_id) 
    DO UPDATE SET 
      email = EXCLUDED.email,
      status = 'active'::public.user_profile_status,
      company_id = EXCLUDED.company_id;
    
    -- 3. Update profile_invites status to 'active'
    UPDATE public.profile_invites
    SET status = 'active'::public.user_profile_status
    WHERE LOWER(email) = LOWER(NEW.email);
    
    -- 4. Create a bike benefit for the user
    INSERT INTO public.bike_benefits (user_id)
    VALUES (NEW.id)
    ON CONFLICT DO NOTHING;
    
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger for new user creation (when OTP is verified AND password is set)
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  WHEN (NEW.email_confirmed_at IS NOT NULL AND NEW.encrypted_password IS NOT NULL)
  EXECUTE FUNCTION public.handle_user_registration();

-- Create trigger for user updates (when password is set/changed)
CREATE TRIGGER on_auth_user_updated
  AFTER UPDATE ON auth.users
  FOR EACH ROW
  WHEN (
    NEW.email_confirmed_at IS NOT NULL AND 
    NEW.encrypted_password IS NOT NULL AND
    OLD.encrypted_password IS DISTINCT FROM NEW.encrypted_password
  )
  EXECUTE FUNCTION public.handle_user_registration();
