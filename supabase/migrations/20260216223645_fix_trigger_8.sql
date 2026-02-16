-- ============================================
-- Fix status triggers — final version with diagnostic test
-- ============================================
-- Bug: "works once, after choose_bike reset stays searching forever"
--
-- Root cause candidates addressed:
-- 1. choose_bike reset fired on EVERY update while step = choose_bike
--    (not just on transition) — cleared timestamps set by other updates.
--    Fix: only reset when OLD.step IS DISTINCT FROM 'choose_bike'.
-- 2. choose_bike reset only cleared 3 fields but left contract_viewed_at,
--    contract_employee_signed_at, etc. — contract trigger then derived a
--    stale contract_status from leftover timestamps.
--    Fix: clear ALL later-step timestamps on choose_bike transition.
-- 3. Column-restricted triggers could be silently dropped by CASCADE
--    operations on enum types.  Fix: fire on EVERY INSERT/UPDATE.
-- 4. Implicit enum casts may silently fail comparisons.
--    Fix: every literal is explicitly cast.
-- ============================================


-- ============================================
-- 1. Drop both status triggers
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
  -- HR terminal states: once set, only HR can change them
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
    -- Reset ONLY when transitioning TO choose_bike (user reconsidered).
    -- Without this guard, every unrelated update while on choose_bike
    -- would wipe timestamps that other updates just set.
    IF TG_OP = 'UPDATE'
       AND (OLD.step IS NULL OR OLD.step IS DISTINCT FROM 'choose_bike'::public.bike_benefit_step) THEN
      -- Clear ALL later-step fields so the flow restarts cleanly
      NEW.live_test_whatsapp_sent_at    := NULL;
      NEW.live_test_checked_in_at       := NULL;
      NEW.committed_at                  := NULL;
      NEW.contract_requested_at         := NULL;
      NEW.contract_viewed_at            := NULL;
      NEW.contract_employee_signed_at   := NULL;
      NEW.contract_employer_signed_at   := NULL;
      NEW.contract_approved_at          := NULL;
      NEW.delivered_at                  := NULL;
      NEW.contract_status               := NULL;
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
      NEW.benefit_status := COALESCE(OLD.benefit_status, 'searching'::public.benefit_status);
    END IF;

  -- ── sign_contract / pickup_delivery ──────────────────────────────────────
  ELSIF NEW.step IN (
    'sign_contract'::public.bike_benefit_step,
    'pickup_delivery'::public.bike_benefit_step
  ) THEN
    NEW.benefit_status := COALESCE(OLD.benefit_status, 'searching'::public.benefit_status);

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
  IF TG_OP = 'UPDATE'
     AND OLD.contract_status = 'terminated'::public.contract_status THEN
    RETURN NEW;
  END IF;

  IF NEW.contract_employee_signed_at IS NOT NULL
     AND NEW.contract_employer_signed_at IS NOT NULL
     AND NEW.contract_approved_at IS NOT NULL THEN
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
-- 4. Recreate triggers — BEFORE INSERT OR UPDATE (every row change)
-- ============================================
CREATE TRIGGER update_benefit_status_on_change
  BEFORE INSERT OR UPDATE ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_bike_benefit_status();

CREATE TRIGGER update_contract_status_on_change
  BEFORE INSERT OR UPDATE ON public.bike_benefits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_contract_status();


-- ============================================
-- 5. DIAGNOSTIC TEST — run this block in Supabase SQL Editor after applying
--    the migration to verify everything works. It creates a temporary test
--    row, walks through the full flow twice (including a choose_bike reset),
--    and reports PASS/FAIL for each step.
--    The test row is deleted at the end.
-- ============================================
/*
DO $$
DECLARE
  v_test_user_id uuid;
  v_test_id      uuid;
  v_bs           public.benefit_status;
  v_cs           public.contract_status;
  v_whatsapp     timestamptz;
  v_committed    timestamptz;
  v_pass         int := 0;
  v_fail         int := 0;
BEGIN
  -- Pick an existing user_id from profiles (needed for FK)
  SELECT user_id INTO v_test_user_id FROM public.profiles LIMIT 1;
  IF v_test_user_id IS NULL THEN
    RAISE NOTICE 'NO PROFILES FOUND — cannot run test';
    RETURN;
  END IF;

  -- INSERT: step NULL → should be 'inactive'
  INSERT INTO public.bike_benefits (user_id)
  VALUES (v_test_user_id)
  RETURNING id, benefit_status, contract_status INTO v_test_id, v_bs, v_cs;
  IF v_bs = 'inactive' THEN v_pass := v_pass+1; RAISE NOTICE 'PASS 1: INSERT → inactive (got %)', v_bs;
  ELSE v_fail := v_fail+1; RAISE NOTICE 'FAIL 1: INSERT → expected inactive, got %', v_bs; END IF;

  -- STEP choose_bike → searching
  UPDATE public.bike_benefits SET step = 'choose_bike' WHERE id = v_test_id
  RETURNING benefit_status INTO v_bs;
  IF v_bs = 'searching' THEN v_pass := v_pass+1; RAISE NOTICE 'PASS 2: choose_bike → searching (got %)', v_bs;
  ELSE v_fail := v_fail+1; RAISE NOTICE 'FAIL 2: choose_bike → expected searching, got %', v_bs; END IF;

  -- STEP book_live_test (no whatsapp yet) → searching
  UPDATE public.bike_benefits SET step = 'book_live_test' WHERE id = v_test_id
  RETURNING benefit_status INTO v_bs;
  IF v_bs = 'searching' THEN v_pass := v_pass+1; RAISE NOTICE 'PASS 3: book_live_test (no whatsapp) → searching (got %)', v_bs;
  ELSE v_fail := v_fail+1; RAISE NOTICE 'FAIL 3: book_live_test → expected searching, got %', v_bs; END IF;

  -- SET live_test_whatsapp_sent_at → testing
  UPDATE public.bike_benefits SET live_test_whatsapp_sent_at = now() WHERE id = v_test_id
  RETURNING benefit_status INTO v_bs;
  IF v_bs = 'testing' THEN v_pass := v_pass+1; RAISE NOTICE 'PASS 4: whatsapp sent → testing (got %)', v_bs;
  ELSE v_fail := v_fail+1; RAISE NOTICE 'FAIL 4: whatsapp sent → expected testing, got %', v_bs; END IF;

  -- STEP commit_to_bike (no committed_at) → preserve testing
  UPDATE public.bike_benefits SET step = 'commit_to_bike' WHERE id = v_test_id
  RETURNING benefit_status INTO v_bs;
  IF v_bs = 'testing' THEN v_pass := v_pass+1; RAISE NOTICE 'PASS 5: commit_to_bike (no timestamp) → testing preserved (got %)', v_bs;
  ELSE v_fail := v_fail+1; RAISE NOTICE 'FAIL 5: commit_to_bike → expected testing, got %', v_bs; END IF;

  -- SET committed_at → active
  UPDATE public.bike_benefits SET committed_at = now() WHERE id = v_test_id
  RETURNING benefit_status INTO v_bs;
  IF v_bs = 'active' THEN v_pass := v_pass+1; RAISE NOTICE 'PASS 6: committed_at → active (got %)', v_bs;
  ELSE v_fail := v_fail+1; RAISE NOTICE 'FAIL 6: committed_at → expected active, got %', v_bs; END IF;

  -- SET contract_requested_at → contract_status = pending
  UPDATE public.bike_benefits SET contract_requested_at = now() WHERE id = v_test_id
  RETURNING contract_status INTO v_cs;
  IF v_cs = 'pending' THEN v_pass := v_pass+1; RAISE NOTICE 'PASS 7: contract_requested_at → pending (got %)', v_cs;
  ELSE v_fail := v_fail+1; RAISE NOTICE 'FAIL 7: contract_requested_at → expected pending, got %', v_cs; END IF;

  -- ═══════════════════════════════════════════════
  -- RESET to choose_bike (user reconsidered)
  -- ═══════════════════════════════════════════════
  UPDATE public.bike_benefits SET step = 'choose_bike' WHERE id = v_test_id
  RETURNING benefit_status, contract_status, live_test_whatsapp_sent_at, committed_at
  INTO v_bs, v_cs, v_whatsapp, v_committed;

  IF v_bs = 'searching' AND v_cs IS NULL AND v_whatsapp IS NULL AND v_committed IS NULL THEN
    v_pass := v_pass+1; RAISE NOTICE 'PASS 8: choose_bike RESET → searching, timestamps cleared (bs=%, cs=%, wa=%, ca=%)', v_bs, v_cs, v_whatsapp, v_committed;
  ELSE
    v_fail := v_fail+1; RAISE NOTICE 'FAIL 8: choose_bike RESET → bs=%, cs=%, whatsapp=%, committed=%', v_bs, v_cs, v_whatsapp, v_committed;
  END IF;

  -- ═══════════════════════════════════════════════
  -- SECOND PASS — same flow again after reset
  -- ═══════════════════════════════════════════════

  -- STEP book_live_test → searching
  UPDATE public.bike_benefits SET step = 'book_live_test' WHERE id = v_test_id
  RETURNING benefit_status INTO v_bs;
  IF v_bs = 'searching' THEN v_pass := v_pass+1; RAISE NOTICE 'PASS 9: [2nd] book_live_test → searching (got %)', v_bs;
  ELSE v_fail := v_fail+1; RAISE NOTICE 'FAIL 9: [2nd] book_live_test → expected searching, got %', v_bs; END IF;

  -- SET live_test_whatsapp_sent_at → testing
  UPDATE public.bike_benefits SET live_test_whatsapp_sent_at = now() WHERE id = v_test_id
  RETURNING benefit_status INTO v_bs;
  IF v_bs = 'testing' THEN v_pass := v_pass+1; RAISE NOTICE 'PASS 10: [2nd] whatsapp sent → testing (got %)', v_bs;
  ELSE v_fail := v_fail+1; RAISE NOTICE 'FAIL 10: [2nd] whatsapp sent → expected testing, got %', v_bs; END IF;

  -- SET committed_at + step → active
  UPDATE public.bike_benefits SET step = 'commit_to_bike', committed_at = now() WHERE id = v_test_id
  RETURNING benefit_status INTO v_bs;
  IF v_bs = 'active' THEN v_pass := v_pass+1; RAISE NOTICE 'PASS 11: [2nd] commit + timestamp → active (got %)', v_bs;
  ELSE v_fail := v_fail+1; RAISE NOTICE 'FAIL 11: [2nd] commit + timestamp → expected active, got %', v_bs; END IF;

  -- SET contract_requested_at → pending
  UPDATE public.bike_benefits SET contract_requested_at = now() WHERE id = v_test_id
  RETURNING contract_status INTO v_cs;
  IF v_cs = 'pending' THEN v_pass := v_pass+1; RAISE NOTICE 'PASS 12: [2nd] contract_requested_at → pending (got %)', v_cs;
  ELSE v_fail := v_fail+1; RAISE NOTICE 'FAIL 12: [2nd] contract_requested_at → expected pending, got %', v_cs; END IF;

  -- Cleanup
  DELETE FROM public.bike_benefits WHERE id = v_test_id;

  RAISE NOTICE '══════════════════════════════════════';
  RAISE NOTICE 'RESULTS: % passed, % failed', v_pass, v_fail;
  RAISE NOTICE '══════════════════════════════════════';
END;
$$;
*/
