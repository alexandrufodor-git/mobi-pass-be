-- ============================================
-- Fix benefit_status trigger logic and view last_modified_at / ORDER BY
-- ============================================
-- Changes:
-- 1. Rewrite update_bike_benefit_status() with explicit per-step branches so
--    every possible NEW.step value sets a deterministic benefit_status.
--    Previously the ELSE catch-all grouped book_live_test (no whatsapp) and
--    commit_to_bike (no committed_at) together, making the logic ambiguous.
-- 2. Recreate profile_invites_with_details view with:
--    - COALESCE for last_modified_at (falls back to order / profile / invite dates
--      when bike_benefit row has not been updated yet) — returned to frontend
--    - ORDER BY last_modified_at DESC
-- ============================================


-- ============================================
-- 1. Replace benefit_status trigger function
-- ============================================
CREATE OR REPLACE FUNCTION public.update_bike_benefit_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Preserve manually set terminal states (insurance_claim, terminated).
  -- Only bail out when both OLD and NEW are already terminal so that a manual
  -- reset from a terminal state is still allowed.
  IF TG_OP = 'UPDATE'
     AND OLD.benefit_status IN ('insurance_claim', 'terminated')
     AND NEW.benefit_status IN ('insurance_claim', 'terminated') THEN
    RETURN NEW;
  END IF;

  -- ── step IS NULL ────────────────────────────────────────────────────────
  -- Benefit created (e.g. by registration trigger) but employee has not
  -- started the process yet.
  IF NEW.step IS NULL THEN
    NEW.benefit_status := 'inactive';

  -- ── choose_bike ──────────────────────────────────────────────────────────
  -- Employee started the flow, OR reconsidered and went back to bike selection.
  -- Reset all fields that belong to later steps so data stays consistent.
  ELSIF NEW.step = 'choose_bike' THEN
    IF TG_OP = 'UPDATE' THEN
      NEW.live_test_whatsapp_sent_at := NULL;
      NEW.contract_requested_at     := NULL;
      NEW.committed_at              := NULL;
      -- contract_status is timestamp-driven; clearing contract_requested_at
      -- would leave it stale, so reset it here explicitly.
      NEW.contract_status           := NULL;
    END IF;
    NEW.benefit_status := 'searching';

  -- ── book_live_test ───────────────────────────────────────────────────────
  -- 'testing' only once HR has confirmed by sending the WhatsApp message.
  -- Until then the employee is still effectively in the searching state.
  ELSIF NEW.step = 'book_live_test' THEN
    IF NEW.live_test_whatsapp_sent_at IS NOT NULL THEN
      NEW.benefit_status := 'testing';
    ELSE
      NEW.benefit_status := 'searching';
    END IF;

  -- ── commit_to_bike ───────────────────────────────────────────────────────
  -- 'active' only once the commitment timestamp is recorded.
  -- Until then preserve the last known auto-status (typically 'testing').
  ELSIF NEW.step = 'commit_to_bike' THEN
    IF NEW.committed_at IS NOT NULL THEN
      NEW.benefit_status := 'active';
    ELSE
      IF TG_OP = 'UPDATE' AND OLD.benefit_status IS NOT NULL THEN
        NEW.benefit_status := OLD.benefit_status;
      ELSE
        NEW.benefit_status := 'searching';
      END IF;
    END IF;

  -- ── sign_contract / pickup_delivery ─────────────────────────────────────
  -- These steps do not change benefit_status automatically.
  -- Preserve whatever was already set (should be 'active').
  ELSIF NEW.step IN ('sign_contract', 'pickup_delivery') THEN
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
Each step has its own explicit branch:
  NULL            → inactive  (benefit just created, not started)
  choose_bike     → searching (also resets later-step timestamps)
  book_live_test  → testing   (requires live_test_whatsapp_sent_at) / searching otherwise
  commit_to_bike  → active    (requires committed_at) / preserves previous status otherwise
  sign_contract, pickup_delivery → preserves current status
Does not override manually set insurance_claim or terminated statuses.';


-- ============================================
-- 2. Recreate view with COALESCE last_modified_at (returned as column) + ORDER BY
-- ============================================
DROP VIEW IF EXISTS public.profile_invites_with_details;

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

  -- Profile data (NULL if user has not registered yet)
  p.user_id,
  p.status AS profile_status,
  p.created_at AS registered_at,

  -- Employee data: prefer registered profile values, fall back to invite values
  COALESCE(p.first_name,  pi.first_name)  AS first_name,
  COALESCE(p.last_name,   pi.last_name)   AS last_name,
  COALESCE(p.description, pi.description) AS description,
  COALESCE(p.department,  pi.department)  AS department,
  COALESCE(p.hire_date,   pi.hire_date)   AS hire_date,

  -- Bike benefit data (NULL if user has not started the benefit process)
  bb.id   AS bike_benefit_id,
  bb.step AS current_step,

  -- Status fields for HR dashboard
  bb.benefit_status,
  bb.contract_status,

  -- Most recent activity across benefit → order → profile → invite.
  -- Returned as a column so the frontend can display / sort by it.
  COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) AS last_modified_at,

  -- Bike data
  bb.bike_id,
  b.name       AS bike_name,
  b.brand      AS bike_brand,
  b.type       AS bike_type,
  b.full_price AS bike_full_price,

  -- Employee price = full price minus total company subsidy over contract term
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

  -- Live test details
  bb.live_test_location_coords,
  bb.live_test_location_name,
  bb.live_test_whatsapp_sent_at,
  bb.live_test_checked_in_at,

  -- Order details
  bo.id        AS order_id,
  bo.helmet    AS ordered_helmet,
  bo.insurance AS ordered_insurance

FROM public.profile_invites pi
  LEFT JOIN public.companies     c  ON pi.company_id = c.id
  LEFT JOIN public.profiles      p  ON pi.email = p.email
  LEFT JOIN public.bike_benefits bb ON p.user_id = bb.user_id
  LEFT JOIN public.bikes         b  ON bb.bike_id = b.id
  LEFT JOIN public.bike_orders   bo ON bb.id = bo.bike_benefit_id

ORDER BY last_modified_at DESC;

COMMENT ON VIEW public.profile_invites_with_details IS
'Combined view of profile invites, user profiles, and bike benefits with status tracking.
Ordered by most recent activity (benefit update → order update → registration → invite).
benefit_status and contract_status are auto-maintained by triggers.';
