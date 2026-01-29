-- ============================================
-- Fix bike_benefit_step enum - Remove Extra Values
-- ============================================
-- This migration recreates the bike_benefit_step enum to remove any extra
-- values that were added in production and reset it to the correct 5 values.
--
-- WARNING: This will drop and recreate the step column, losing existing data.
-- If you need to preserve step data, run a backup query first.
-- ============================================

-- ============================================
-- 1. Store existing step data in a temporary table (optional backup)
-- ============================================
-- Uncomment if you need to preserve the data:
-- CREATE TEMP TABLE temp_benefit_steps AS
-- SELECT id, step::text as step_value
-- FROM public.bike_benefits
-- WHERE step IS NOT NULL;

-- ============================================
-- 2. Drop and recreate bike_benefit_step enum
-- ============================================
-- This removes the corrupted enum with extra values
DROP TYPE IF EXISTS public.bike_benefit_step CASCADE;

-- Recreate with only the 5 correct values
CREATE TYPE public.bike_benefit_step AS ENUM (
  'choose_bike',        -- Step 1: Choose an eBike
  'book_live_test',     -- Step 2: Book a live test
  'commit_to_bike',     -- Step 3: Commit to your eBike
  'sign_contract',      -- Step 4: Sign your contract
  'pickup_delivery'     -- Step 5: eBike pickup / delivery
);

COMMENT ON TYPE public.bike_benefit_step IS 'Steps in the bike benefit workflow process';

-- ============================================
-- 3. Re-add step column to bike_benefits
-- ============================================
-- The CASCADE drop removed the step column, so we need to add it back
ALTER TABLE public.bike_benefits
  ADD COLUMN step public.bike_benefit_step;

COMMENT ON COLUMN public.bike_benefits.step IS 'Current step in the bike benefit workflow. NULL when benefit not yet started.';

-- ============================================
-- 4. Restore step data from backup (optional)
-- ============================================
-- Uncomment if you backed up the data:
-- UPDATE public.bike_benefits bb
-- SET step = tbs.step_value::public.bike_benefit_step
-- FROM temp_benefit_steps tbs
-- WHERE bb.id = tbs.id
--   AND tbs.step_value IN ('choose_bike', 'book_live_test', 'commit_to_bike', 'sign_contract', 'pickup_delivery');

-- ============================================
-- 5. Update triggers to use the new enum
-- ============================================
-- Recreate the benefit status update trigger to ensure it works with new enum
CREATE OR REPLACE FUNCTION public.update_bike_benefit_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Don't auto-update if manually set to insurance_claim or terminated
  IF NEW.benefit_status IN ('insurance_claim', 'terminated') AND 
     OLD.benefit_status IN ('insurance_claim', 'terminated') THEN
    RETURN NEW;
  END IF;
  
  -- Auto-determine benefit_status based on step and timestamps
  IF NEW.step IS NULL THEN
    -- If step is reset/NULL, status should also be NULL
    NEW.benefit_status := NULL;
    
  ELSIF NEW.step = 'pickup_delivery' AND NEW.delivered_at IS NOT NULL THEN
    NEW.benefit_status := 'active';
    
  ELSIF NEW.step = 'book_live_test' AND NEW.live_test_whatsapp_sent_at IS NOT NULL THEN
    NEW.benefit_status := 'testing';
    
  ELSIF NEW.step = 'choose_bike' THEN
    NEW.benefit_status := 'searching';
    
  -- If step is 'commit_to_bike' or 'sign_contract', keep current status or set to searching
  ELSIF NEW.step IN ('commit_to_bike', 'sign_contract') THEN
    IF OLD.benefit_status IS NOT NULL THEN
      NEW.benefit_status := OLD.benefit_status;
    ELSE
      NEW.benefit_status := 'searching';
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.update_bike_benefit_status IS 
'Trigger function that auto-updates benefit_status based on step and timestamp changes. 
Sets status to NULL when step is NULL (benefit not started).
Does not override manually set insurance_claim or terminated statuses.';

-- Drop and recreate the trigger
DROP TRIGGER IF EXISTS update_benefit_status_on_change ON public.bike_benefits;

CREATE TRIGGER update_benefit_status_on_change
  BEFORE INSERT OR UPDATE OF step, live_test_whatsapp_sent_at, delivered_at, benefit_status
  ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_bike_benefit_status();

-- ============================================
-- 6. Update existing records to sync benefit_status
-- ============================================
-- Sync benefit_status based on current step values (if any were preserved)
UPDATE public.bike_benefits
SET benefit_status = CASE
  WHEN step = 'commit_to_bike' AND committed_at IS NOT NULL THEN 'active'::public.benefit_status
  WHEN step = 'book_live_test' AND live_test_whatsapp_sent_at IS NOT NULL THEN 'testing'::public.benefit_status
  WHEN step = 'choose_bike' THEN 'searching'::public.benefit_status
  WHEN step IS NULL THEN NULL
  ELSE benefit_status
END
WHERE step IS NOT NULL OR benefit_status IS NULL;
