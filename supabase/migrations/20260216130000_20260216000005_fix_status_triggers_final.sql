-- ============================================
-- Final fix: status triggers, fire on every row change
-- ============================================
-- Key fixes vs all previous versions:
--
-- 1. Both triggers fire on EVERY INSERT/UPDATE (no column restriction).
--    Column-level restrictions were unreliable — missed updates when multiple
--    columns changed at once, or when an earlier CASCADE dropped the step column
--    and silently removed triggers that specified "UPDATE OF step".
--
-- 2. choose_bike reset ONLY fires when step is TRANSITIONING TO choose_bike
--    (OLD.step IS DISTINCT FROM 'choose_bike'). Previously it fired on every
--    update while step was already choose_bike, so setting
--    live_test_whatsapp_sent_at while on choose_bike immediately wiped it.
--
-- 3. Enum type casts are explicit (::public.benefit_status,
--    ::public.bike_benefit_step) so there is zero ambiguity.
-- ============================================


-- ============================================
-- 1. Drop existing triggers
-- ============================================
DROP TRIGGER IF EXISTS update_benefit_status_on_change  ON public.bike_benefits;
DROP TRIGGER IF EXISTS update_contract_status_on_change ON public.bike_benefits;


-- ============================================
-- 2. Benefit status trigger function
-- ============================================
CREATE OR REPLACE FUNCTION public.update_bike_benefit_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- HR-set terminal states: never overwrite automatically.
  -- Once HR marks insurance_claim or terminated, step/timestamp changes are ignored.
  IF TG_OP = 'UPDATE'
     AND OLD.benefit_status IN (
       'insurance_claim'::public.benefit_status,
       'terminated'::public.benefit_status
     ) THEN
    RETURN NEW;
  END IF;

  -- ── step IS NULL ─────────────────────────────────────────────────────────
  IF NEW.step IS NULL THEN
    NEW.benefit_status := 'inactive'::public.benefit_status;

  -- ── choose_bike ──────────────────────────────────────────────────────────
  ELSIF NEW.step = 'choose_bike'::public.bike_benefit_step THEN
    -- Only reset later-step fields when TRANSITIONING to choose_bike.
    -- If step was already choose_bike, skip the reset so unrelated field
    -- updates do not wipe data.
    IF TG_OP = 'UPDATE'
       AND OLD.step IS DISTINCT FROM 'choose_bike'::public.bike_benefit_step THEN
      NEW.live_test_whatsapp_sent_at := NULL;
      NEW.contract_requested_at     := NULL;
      NEW.committed_at              := NULL;
      NEW.contract_status           := NULL;
    END IF;
    NEW.benefit_status := 'searching'::public.benefit_status;

  -- ── book_live_test ───────────────────────────────────────────────────────
  ELSIF NEW.step = 'book_live_test'::public.bike_benefit_step THEN
    IF NEW.live_test_whatsapp_sent_at IS NOT NULL THEN
      NEW.benefit_status := 'testing'::public.benefit_status;
    ELSE
      NEW.benefit_status := 'searching'::public.benefit_status;
    END IF;

  -- ── commit_to_bike ───────────────────────────────────────────────────────
  ELSIF NEW.step = 'commit_to_bike'::public.bike_benefit_step THEN
    IF NEW.committed_at IS NOT NULL THEN
      NEW.benefit_status := 'active'::public.benefit_status;
    ELSE
      NEW.benefit_status := COALESCE(
        OLD.benefit_status,
        'searching'::public.benefit_status
      );
    END IF;

  -- ── sign_contract / pickup_delivery ──────────────────────────────────────
  ELSIF NEW.step IN (
    'sign_contract'::public.bike_benefit_step,
    'pickup_delivery'::public.bike_benefit_step
  ) THEN
    NEW.benefit_status := COALESCE(
      OLD.benefit_status,
      'searching'::public.benefit_status
    );

  END IF;

  RETURN NEW;
END;
$$;


-- ============================================
-- 3. Contract status trigger function
-- ============================================
CREATE OR REPLACE FUNCTION public.update_contract_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- HR-set terminated: never overwrite automatically
  IF TG_OP = 'UPDATE'
     AND OLD.contract_status = 'terminated'::public.contract_status THEN
    RETURN NEW;
  END IF;

  -- Evaluate most-complete state first
  IF NEW.contract_employee_signed_at IS NOT NULL AND
     NEW.contract_employer_signed_at IS NOT NULL AND
     NEW.contract_approved_at        IS NOT NULL THEN
    NEW.contract_status := 'approved'::public.contract_status;

  ELSIF NEW.contract_employer_signed_at IS NOT NULL THEN
    NEW.contract_status := 'signed_by_employer'::public.contract_status;

  ELSIF NEW.contract_employee_signed_at IS NOT NULL THEN
    NEW.contract_status := 'signed_by_employee'::public.contract_status;

  ELSIF NEW.contract_viewed_at IS NOT NULL THEN
    NEW.contract_status := 'viewed_by_employee'::public.contract_status;

  ELSIF NEW.contract_requested_at IS NOT NULL THEN
    NEW.contract_status := 'pending'::public.contract_status;

  ELSE
    NEW.contract_status := NULL;

  END IF;

  RETURN NEW;
END;
$$;


-- ============================================
-- 4. Recreate triggers — fire on every INSERT/UPDATE, no column restriction
-- ============================================

-- Benefit trigger runs first (alphabetical order: benefit < contract)
CREATE TRIGGER update_benefit_status_on_change
  BEFORE INSERT OR UPDATE ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_bike_benefit_status();

-- Contract trigger runs second — picks up choose_bike resets from benefit trigger
CREATE TRIGGER update_contract_status_on_change
  BEFORE INSERT OR UPDATE ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_contract_status();
