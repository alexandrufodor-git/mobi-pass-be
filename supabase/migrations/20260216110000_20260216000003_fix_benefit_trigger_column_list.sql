-- ============================================
-- Fix benefit_status trigger: remove benefit_status from watch list
-- ============================================
-- Root cause of "always searching" bug:
--   benefit_status was in the trigger's UPDATE OF column list.
--   When HR sets benefit_status = 'insurance_claim' directly, the trigger
--   fires and immediately overwrites it back to 'searching' (or whatever
--   the current step resolves to).
--
-- Fix:
--   1. Drop the trigger and recreate it watching ONLY the columns that
--      should drive automatic status changes: step, live_test_whatsapp_sent_at,
--      committed_at.  benefit_status and delivered_at are removed.
--   2. Fix the terminal-state guard: if OLD.benefit_status is already a
--      terminal state (set manually by HR), do not auto-update on any
--      step/timestamp change.
--   3. Keep the choose_bike reset guard (clears later-step timestamps AND
--      contract_status so the contract flow restarts cleanly).
-- ============================================


-- ============================================
-- 1. Drop existing trigger (function stays, only the trigger binding changes)
-- ============================================
DROP TRIGGER IF EXISTS update_benefit_status_on_change ON public.bike_benefits;


-- ============================================
-- 2. Replace trigger function with corrected guard and explicit branches
-- ============================================
CREATE OR REPLACE FUNCTION public.update_bike_benefit_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- ── Terminal-state guard ─────────────────────────────────────────────────
  -- If HR has manually set the benefit to a terminal state, never overwrite
  -- it automatically.  HR must explicitly change it to resume normal flow.
  IF TG_OP = 'UPDATE' AND OLD.benefit_status IN ('insurance_claim', 'terminated') THEN
    RETURN NEW;
  END IF;

  -- ── step IS NULL ─────────────────────────────────────────────────────────
  IF NEW.step IS NULL THEN
    NEW.benefit_status := 'inactive';

  -- ── choose_bike ──────────────────────────────────────────────────────────
  -- Employee started the flow, or reconsidered and went back to bike selection.
  -- Clear all later-step data so nothing is left in an inconsistent state.
  ELSIF NEW.step = 'choose_bike' THEN
    IF TG_OP = 'UPDATE' THEN
      NEW.live_test_whatsapp_sent_at := NULL;
      NEW.contract_requested_at     := NULL;
      NEW.committed_at              := NULL;
      -- Reset contract_status: contract_requested_at is cleared so the
      -- timestamp-driven contract trigger would leave it stale otherwise.
      NEW.contract_status           := NULL;
    END IF;
    NEW.benefit_status := 'searching';

  -- ── book_live_test ───────────────────────────────────────────────────────
  -- 'testing' only once HR confirms by recording the WhatsApp timestamp.
  ELSIF NEW.step = 'book_live_test' THEN
    IF NEW.live_test_whatsapp_sent_at IS NOT NULL THEN
      NEW.benefit_status := 'testing';
    ELSE
      NEW.benefit_status := 'searching';
    END IF;

  -- ── commit_to_bike ───────────────────────────────────────────────────────
  -- 'active' only once the committed_at timestamp is recorded.
  -- Until then preserve the previous auto-status (typically 'testing').
  ELSIF NEW.step = 'commit_to_bike' THEN
    IF NEW.committed_at IS NOT NULL THEN
      NEW.benefit_status := 'active';
    ELSE
      NEW.benefit_status := COALESCE(OLD.benefit_status, 'searching');
    END IF;

  -- ── sign_contract / pickup_delivery ─────────────────────────────────────
  -- No automatic status change for these steps; preserve current status.
  ELSIF NEW.step IN ('sign_contract', 'pickup_delivery') THEN
    NEW.benefit_status := COALESCE(OLD.benefit_status, 'searching');

  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.update_bike_benefit_status IS
'Auto-updates benefit_status on step / timestamp changes.
Fires ONLY when step, live_test_whatsapp_sent_at, or committed_at change
so that HR direct writes to benefit_status (insurance_claim, terminated)
are never overwritten by the trigger.
Terminal-state guard: once HR sets insurance_claim or terminated, any
subsequent step/timestamp updates are ignored until HR explicitly changes it.
choose_bike resets live_test_whatsapp_sent_at, contract_requested_at,
committed_at, and contract_status to NULL.';


-- ============================================
-- 3. Recreate trigger watching ONLY data-driving columns
--    benefit_status and delivered_at intentionally removed:
--      - benefit_status: HR direct writes must not trigger auto-overwrite
--      - delivered_at:   no benefit_status logic depends on it
-- ============================================
CREATE TRIGGER update_benefit_status_on_change
  BEFORE INSERT OR UPDATE OF step, live_test_whatsapp_sent_at, committed_at
  ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_bike_benefit_status();
