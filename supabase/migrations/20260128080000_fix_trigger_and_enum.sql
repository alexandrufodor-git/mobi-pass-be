-- ============================================
-- Fix bike_type enum and update trigger
-- ============================================

-- Drop and recreate the enum (only if it exists)
DO $$ BEGIN
  DROP TYPE IF EXISTS public.bike_type CASCADE;
  CREATE TYPE public.bike_type AS ENUM (
    'e_mtb_hardtail_29',
    'e_mtb_hardtail_27_5',
    'e_full_suspension_29',
    'e_full_suspension_27_5',
    'e_city_bike',
    'e_touring',
    'e_road_race',
    'e_cargo_bike',
    'e_kids_24'
  );
EXCEPTION WHEN duplicate_object THEN
  NULL; -- Type already exists, ignore
END $$;

-- ============================================
-- Update the handle_user_registration trigger
-- ============================================

CREATE OR REPLACE FUNCTION public.handle_user_registration()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
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

    -- Safety check
    IF v_company_id IS NULL THEN
      RAISE EXCEPTION 'No active invite found for email %', NEW.email;
    END IF;
    
    -- 2. Automatically assign 'employee' role to new users
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, 'employee'::public.user_role)
    ON CONFLICT (user_id, role) DO NOTHING;
    
    -- 3. Create or update profile
    INSERT INTO public.profiles (user_id, email, status, company_id)
    VALUES (NEW.id, NEW.email, 'active'::public.user_profile_status, v_company_id)
    ON CONFLICT (user_id) 
    DO UPDATE SET 
      email = EXCLUDED.email,
      status = 'active'::public.user_profile_status,
      company_id = EXCLUDED.company_id;
    
    -- 4. Update profile_invites status to 'active' and link to user
    UPDATE public.profile_invites
    SET 
      status = 'active'::public.user_profile_status,
      user_id = NEW.id
    WHERE LOWER(email) = LOWER(NEW.email);
    
    -- 5. Create a bike benefit for the user
    INSERT INTO public.bike_benefits (user_id)
    VALUES (NEW.id)
    ON CONFLICT DO NOTHING;
    
  END IF;
  
  RETURN NEW;
END;
$function$;
