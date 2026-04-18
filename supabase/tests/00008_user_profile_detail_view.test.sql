SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: user_profile_detail view — REMOVED
-- The view was dropped in migration 20260415000002.
-- Replaced by the get-employee-details edge function.
--
-- Tests:
--  T01: user_profile_detail view no longer exists
--  T02: profiles table no longer has home_address column
--  T03: profiles table no longer has home_lat column
--  T04: profiles table no longer has home_lon column
-- ============================================================

BEGIN;

SELECT plan(4);

-- ── T01: View is gone ───────────────────────────────────────────────────────
SELECT hasnt_view('public', 'user_profile_detail',
  'T01: user_profile_detail view no longer exists (replaced by edge function)');

-- ── T02: home_address removed from profiles ─────────────────────────────────
SELECT hasnt_column('public', 'profiles', 'home_address',
  'T02: profiles.home_address column removed (moved to employee_pii)');

-- ── T03: home_lat removed from profiles ─────────────────────────────────────
SELECT hasnt_column('public', 'profiles', 'home_lat',
  'T03: profiles.home_lat column removed (moved to employee_pii)');

-- ── T04: home_lon removed from profiles ─────────────────────────────────────
SELECT hasnt_column('public', 'profiles', 'home_lon',
  'T04: profiles.home_lon column removed (moved to employee_pii)');

SELECT * FROM finish();
ROLLBACK;
