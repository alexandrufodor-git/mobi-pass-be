-- ============================================
-- Fix contract_status enum, benefit_status defaults, and trigger logic
-- ============================================
-- Changes:
-- 1. Replace contract_status enum: drop not_started, add pending; column becomes nullable/no default
-- 2. Drop DEFAULT and NOT NULL from contract_status column (nullable, no default)
-- 3. Fix benefit_status trigger:
--    - Set 'inactive' on INSERT when step IS NULL (was incorrectly NULL)
--    - Add reset guard when step = 'choose_bike': clear live_test_whatsapp_sent_at,
--      contract_requested_at, committed_at, and contract_status back to NULL
-- 4. Fix contract_status trigger:
--    - Add 'pending' state when contract_requested_at IS NOT NULL
--    - Fallback is now NULL instead of 'not_started'
-- 5. Recreate triggers to include committed_at and contract_requested_at columns
-- 6. Backfill existing data
-- ============================================


-- ============================================
-- 1. Replace contract_status enum
-- PostgreSQL does not support dropping individual enum values.
-- Strategy: convert column to TEXT, drop old enum, create new enum, convert back.
-- ============================================

-- 1a. Drop the view and triggers that depend on contract_status — required before altering
--     the column type. Both are recreated at the end of this migration.
DROP VIEW IF EXISTS public.profile_invites_with_details;
DROP TRIGGER IF EXISTS update_benefit_status_on_change  ON public.bike_benefits;
DROP TRIGGER IF EXISTS update_contract_status_on_change ON public.bike_benefits;

-- 1b. Drop the column default and NOT NULL so we can change the type freely
ALTER TABLE public.bike_benefits
  ALTER COLUMN contract_status DROP DEFAULT,
  ALTER COLUMN contract_status DROP NOT NULL;

-- 1c. Convert column to TEXT so we can safely drop the enum type
ALTER TABLE public.bike_benefits
  ALTER COLUMN contract_status TYPE TEXT
  USING contract_status::TEXT;

-- 1d. Drop the old enum (no longer referenced by any column)
DROP TYPE public.contract_status;

-- 1e. Create the new enum with 'pending' in place of 'not_started'
CREATE TYPE public.contract_status AS ENUM (
  'pending',              -- Contract has been requested but not yet viewed by employee
  'viewed_by_employee',   -- Employee has opened/viewed the contract
  'signed_by_employee',   -- Employee has signed the contract
  'signed_by_employer',   -- Employer has signed the contract (after employee)
  'approved',             -- Both parties have signed - contract is fully executed
  'terminated'            -- Contract is terminated by HR
);

COMMENT ON TYPE public.contract_status IS 'Contract signing workflow status. Tracks progression from pending (requested) to final approval.';

-- 1f. Cast column back to the new enum type.
--     Any row that previously held 'not_started' becomes NULL via the NULLIF fallback.
ALTER TABLE public.bike_benefits
  ALTER COLUMN contract_status TYPE public.contract_status
  USING NULLIF(contract_status, 'not_started')::public.contract_status;


-- ============================================
-- 2. Replace benefit_status trigger function
--    Key fixes:
--    - INSERT with step IS NULL → 'inactive' (not NULL)
--    - UPDATE with step = 'choose_bike' → reset later-step fields to NULL,
--      set benefit_status = 'searching'
-- ============================================
CREATE OR REPLACE FUNCTION public.update_bike_benefit_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Preserve manually set terminal states (insurance_claim, terminated)
  IF NEW.benefit_status IN ('insurance_claim', 'terminated') AND
     TG_OP = 'UPDATE' AND OLD.benefit_status IN ('insurance_claim', 'terminated') THEN
    RETURN NEW;
  END IF;

  IF NEW.step IS NULL THEN
    -- Benefit exists but employee has not started the process yet
    NEW.benefit_status := 'inactive';

  ELSIF NEW.step = 'choose_bike' THEN
    -- Reset guard: employee reconsidered and went back to bike selection.
    -- Clear all fields that belong to later steps so data stays consistent.
    IF TG_OP = 'UPDATE' THEN
      NEW.live_test_whatsapp_sent_at := NULL;
      NEW.contract_requested_at     := NULL;
      NEW.committed_at              := NULL;
      -- Also reset contract_status since contract_requested_at is being cleared
      NEW.contract_status           := NULL;
    END IF;
    NEW.benefit_status := 'searching';

  ELSIF NEW.step = 'book_live_test' AND NEW.live_test_whatsapp_sent_at IS NOT NULL THEN
    NEW.benefit_status := 'testing';

  ELSIF NEW.step = 'commit_to_bike' AND NEW.committed_at IS NOT NULL THEN
    NEW.benefit_status := 'active';

  ELSE
    -- For all other steps (book_live_test without whatsapp, sign_contract, pickup_delivery)
    -- keep the existing status if set, otherwise fall back to searching
    IF TG_OP = 'UPDATE' AND OLD.benefit_status IS NOT NULL THEN
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
Sets status to ''inactive'' on INSERT when step is NULL (benefit just created, not started).
Clears later-step timestamps (live test, contract, commit) when step reverts to choose_bike.
Does not override manually set insurance_claim or terminated statuses.';


-- ============================================
-- 3. Replace contract_status trigger function
--    Key fixes:
--    - Add 'pending' when contract_requested_at IS NOT NULL
--    - Fallback is NULL (was 'not_started', which no longer exists)
-- ============================================
CREATE OR REPLACE FUNCTION public.update_contract_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Preserve manually set terminated state
  IF NEW.contract_status = 'terminated' AND
     TG_OP = 'UPDATE' AND OLD.contract_status = 'terminated' THEN
    RETURN NEW;
  END IF;

  -- Determine contract_status from timestamps (most complete state first)
  IF NEW.contract_employee_signed_at IS NOT NULL AND
     NEW.contract_employer_signed_at IS NOT NULL AND
     NEW.contract_approved_at        IS NOT NULL THEN
    NEW.contract_status := 'approved';

  ELSIF NEW.contract_employer_signed_at IS NOT NULL THEN
    NEW.contract_status := 'signed_by_employer';

  ELSIF NEW.contract_employee_signed_at IS NOT NULL THEN
    NEW.contract_status := 'signed_by_employee';

  ELSIF NEW.contract_viewed_at IS NOT NULL THEN
    NEW.contract_status := 'viewed_by_employee';

  ELSIF NEW.contract_requested_at IS NOT NULL THEN
    -- Contract has been requested but not yet viewed
    NEW.contract_status := 'pending';

  ELSE
    -- No contract interaction at all → NULL
    IF NEW.contract_status IS DISTINCT FROM 'terminated' THEN
      NEW.contract_status := NULL;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.update_contract_status IS
'Trigger function that auto-updates contract_status based on contract timestamp changes.
Sets ''pending'' when contract_requested_at IS NOT NULL (contract requested but not yet viewed).
Falls back to NULL when no contract timestamps are set.
Does not override manually set terminated status.';


-- ============================================
-- 4. Recreate triggers with updated column lists
-- ============================================

-- Benefit status trigger: add committed_at so changes to it also fire the trigger
CREATE TRIGGER update_benefit_status_on_change
  BEFORE INSERT OR UPDATE OF step, live_test_whatsapp_sent_at, committed_at, delivered_at, benefit_status
  ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_bike_benefit_status();

-- Contract status trigger: add contract_requested_at so the new 'pending' state is set correctly
CREATE TRIGGER update_contract_status_on_change
  BEFORE INSERT OR UPDATE OF contract_requested_at, contract_viewed_at,
                             contract_employee_signed_at, contract_employer_signed_at,
                             contract_approved_at, contract_status
  ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_contract_status();


-- ============================================
-- 5. Backfill existing data
-- ============================================

-- 5a. Set benefit_status = 'inactive' for records where step IS NULL and
--     benefit_status is still NULL (created before this fix)
UPDATE public.bike_benefits
SET benefit_status = 'inactive'
WHERE step IS NULL AND benefit_status IS NULL;

-- 5b. For records where contract_requested_at is NULL (no contract was ever requested),
--     ensure contract_status is NULL.
--     The NULLIF cast in step 1f already converts former 'not_started' rows to NULL,
--     but this covers any edge cases where a row somehow kept a non-null value.
UPDATE public.bike_benefits
SET contract_status = NULL
WHERE contract_requested_at IS NULL
  AND contract_status IS NOT NULL
  AND contract_status NOT IN ('terminated');


-- ============================================
-- 6. Recreate view (was dropped in step 1a)
-- ============================================
CREATE VIEW public.profile_invites_with_details WITH (security_invoker = on) AS
SELECT
  pi.id AS invite_id,
  pi.email,
  pi.status AS invite_status,
  pi.created_at AS invited_at,
  pi.company_id,
  c.name AS company_name,
  c.monthly_benefit_subsidy,
  c.contract_months,

  -- Profile data (will be NULL if user hasn't registered yet)
  p.user_id,
  p.status AS profile_status,
  p.created_at AS registered_at,

  -- Employee data (from profile if registered, otherwise from invite)
  COALESCE(p.first_name,   pi.first_name)   AS first_name,
  COALESCE(p.last_name,    pi.last_name)    AS last_name,
  COALESCE(p.description,  pi.description)  AS description,
  COALESCE(p.department,   pi.department)   AS department,
  COALESCE(p.hire_date,    pi.hire_date)    AS hire_date,

  -- Bike benefit data (will be NULL if user hasn't started benefit process)
  bb.id   AS bike_benefit_id,
  bb.step AS current_step,

  -- Status fields for HR dashboard
  bb.benefit_status,
  bb.contract_status,
  bb.updated_at AS last_modified_at,

  -- Bike data
  bb.bike_id,
  b.name       AS bike_name,
  b.brand      AS bike_brand,
  b.type       AS bike_type,
  b.full_price AS bike_full_price,

  -- Calculate employee price based on company benefit
  CASE
    WHEN b.full_price IS NOT NULL THEN
      GREATEST(0, b.full_price - (c.monthly_benefit_subsidy * c.contract_months))
    ELSE NULL
  END AS bike_employee_price,

  c.monthly_benefit_subsidy AS monthly_benefit_price,

  -- Benefit progress timestamps
  bb.committed_at,
  bb.delivered_at,
  bb.benefit_terminated_at,
  bb.benefit_insurance_claim_at,

  -- Contract timestamps
  bb.contract_requested_at,
  bb.contract_viewed_at,
  bb.contract_employee_signed_at,
  bb.contract_employer_signed_at,
  bb.contract_approved_at,
  bb.contract_terminated_at,

  -- Test location
  bb.live_test_location_coords,
  bb.live_test_location_name,
  bb.live_test_whatsapp_sent_at,
  bb.live_test_checked_in_at,

  -- Order details
  bo.id        AS order_id,
  bo.helmet    AS ordered_helmet,
  bo.insurance AS ordered_insurance

FROM public.profile_invites pi
  LEFT JOIN public.companies    c  ON pi.company_id = c.id
  LEFT JOIN public.profiles     p  ON pi.email = p.email
  LEFT JOIN public.bike_benefits bb ON p.user_id = bb.user_id
  LEFT JOIN public.bikes         b  ON bb.bike_id = b.id
  LEFT JOIN public.bike_orders   bo ON bb.id = bo.bike_benefit_id;

COMMENT ON VIEW public.profile_invites_with_details IS
'Combined view of profile invites, user profiles, and bike benefits with status tracking and employee information.
HR can use this to track the entire employee bike benefit journey from invite to delivery.
Includes benefit_status, contract_status, and employee details (name, department, hire date, etc.) for dashboard display.
Employee data is taken from the profile table if registered, otherwise from the invite table.';
