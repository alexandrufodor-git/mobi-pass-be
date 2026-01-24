-- ============================================================================
-- Fix User Registration Trigger - Prevent Duplicate Execution
-- ============================================================================
-- This migration updates the trigger conditions to prevent duplicate execution
-- during magic link registration flow.
--
-- Problem: With magic link flow, triggers were firing twice:
--   1. When email is confirmed (email_confirmed_at set)
--   2. When password is set later (encrypted_password changes)
--
-- Solution: Only fire triggers when BOTH email is confirmed AND password is set
--
-- This ensures registration logic (role, profile, bike benefit) executes
-- exactly once when the user completes password setup.
-- ============================================================================

-- Drop existing triggers
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP TRIGGER IF EXISTS on_auth_user_updated ON auth.users;

-- Recreate trigger for new user creation (only when BOTH OTP verified AND password set)
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  WHEN (NEW.email_confirmed_at IS NOT NULL AND NEW.encrypted_password IS NOT NULL)
  EXECUTE FUNCTION public.handle_user_registration();

-- Recreate trigger for user updates (only when password is set/changed)
CREATE TRIGGER on_auth_user_updated
  AFTER UPDATE ON auth.users
  FOR EACH ROW
  WHEN (
    NEW.email_confirmed_at IS NOT NULL AND 
    NEW.encrypted_password IS NOT NULL AND
    OLD.encrypted_password IS DISTINCT FROM NEW.encrypted_password
  )
  EXECUTE FUNCTION public.handle_user_registration();
