-- ============================================================================
-- User Registration Trigger
-- ============================================================================
-- This trigger handles automatic user setup when a new user registers or
-- updates their password after OTP verification.
--
-- Actions performed:
-- 1. Assigns 'employee' role to new users
-- 2. Creates/updates profile record
-- 3. Sets profile_invites status to 'active'
--
-- Triggers:
-- - on_auth_user_created: Fires when user verifies OTP (email_confirmed_at set)
-- - on_auth_user_updated: Fires when user sets/changes password
-- ============================================================================

-- Drop existing triggers if they exist
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP TRIGGER IF EXISTS on_auth_user_updated ON auth.users;

-- Create or replace the trigger function
CREATE OR REPLACE FUNCTION public.handle_user_registration()
RETURNS TRIGGER AS $$
BEGIN
  -- Automatically assign 'employee' role to new users
  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, 'employee')
  ON CONFLICT (user_id, role) DO NOTHING;
  
  -- Only proceed if user has confirmed their email (via OTP verification)
  IF NEW.email_confirmed_at IS NOT NULL THEN
    
    -- 1. Create or update profile
    INSERT INTO public.profiles (id, email, updated_at)
    VALUES (NEW.id, NEW.email, NOW())
    ON CONFLICT (id) 
    DO UPDATE SET 
      email = EXCLUDED.email,
      updated_at = NOW();
    
    -- 2. Update profile_invites status to 'active' (with explicit enum cast)
    UPDATE public.profile_invites
    SET status = 'active'::user_profile_status
    WHERE LOWER(email) = LOWER(NEW.email);
    
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger for new user creation (when OTP is verified)
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  WHEN (NEW.email_confirmed_at IS NOT NULL)
  EXECUTE FUNCTION public.handle_user_registration();

-- Create trigger for user updates (when password is set/changed)
CREATE TRIGGER on_auth_user_updated
  AFTER UPDATE ON auth.users
  FOR EACH ROW
  WHEN (
    (NEW.email_confirmed_at IS NOT NULL) AND 
    (OLD.encrypted_password IS DISTINCT FROM NEW.encrypted_password OR
     OLD.email_confirmed_at IS DISTINCT FROM NEW.email_confirmed_at)
  )
  EXECUTE FUNCTION public.handle_user_registration();

