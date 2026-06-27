-- Company CO₂ / CSRD engine — Phase 3 aggregation (WEEKLY).
--
-- Pure SQL over the derived scalar employee_pii.commute_distance_km — never
-- touches plaintext PII. Idempotent WEEKLY upsert into company_co2_stats,
-- refreshed Mon–Fri by pg_cron.
--
-- Why weekly, not monthly: the office mandate is "days_in_office PER WEEK", so a
-- week is the model's native, honest unit — it holds exactly that many commute
-- trips regardless of which days. That removes the monthly 4.33/floor
-- approximation entirely. Months/years/all-time roll up by SUMMING weeks (see
-- the company_co2_summary view). A single day is below the rule's resolution
-- (we know 5 of 7 days, not which) → not exposed.
--
-- Formula (per qualifying rider, per week):
--   week_km      = commute_distance_km × 2 × days_in_office   -- one-way ×2 ×trips/week
--   kg_co2_saved = week_km × 0.165                            -- avg-car factor (2.31 kg/L ÷ 14 km/L)
--
-- Lifecycle gate (authoritative): delivered_at IS NOT NULL AND benefit_status='active'.
-- A terminated/insurance_claim benefit drops out on the next run; a not-yet-
-- delivered one never accrues. benefit_status is trigger-derived (not freely set).

CREATE OR REPLACE FUNCTION "public"."refresh_company_co2_stats"(
  "p_period"      date     DEFAULT date_trunc('week', now())::date,  -- Monday of the ISO week
  "p_company_ids" uuid[]   DEFAULT NULL                              -- NULL = all companies
) RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $$
DECLARE
  -- Avg-car avoided-emissions factor, kg CO₂ per km. Identical to mobile's
  -- RouteEstimations (CO2_KG_PER_LITER 2.31 / AVG_CAR_KM_PER_LITER 14.0).
  v_emission_factor constant numeric := 0.165;
BEGIN
  -- LEFT JOIN LATERAL so EVERY company gets a current-week row: companies with
  -- zero qualifying riders upsert to 0 (corrects a drop to zero), not a
  -- missing/stale row.
  INSERT INTO public.company_co2_stats AS s
    (company_id, period, kg_co2_saved, active_riders, total_km, computed_at)
  SELECT
    c.id,
    p_period,
    COALESCE(round(sum(w.week_km * v_emission_factor)::numeric, 3), 0),
    count(w.user_id),
    COALESCE(round(sum(w.week_km)::numeric, 3), 0),
    now()
  FROM public.companies c
  LEFT JOIN LATERAL (
    SELECT
      ep.user_id,
      ep.commute_distance_km * 2 * COALESCE(c.days_in_office, 5) AS week_km
    FROM public.employee_pii ep
    JOIN public.bike_benefits bb ON bb.user_id = ep.user_id
    WHERE ep.company_id = c.id
      AND ep.user_id IS NOT NULL
      AND ep.commute_distance_km IS NOT NULL
      AND bb.delivered_at IS NOT NULL
      AND bb.benefit_status = 'active'::public.benefit_status
  ) w ON true
  WHERE (p_company_ids IS NULL OR c.id = ANY (p_company_ids))
  GROUP BY c.id
  ON CONFLICT (company_id, period) DO UPDATE SET
    kg_co2_saved  = EXCLUDED.kg_co2_saved,
    active_riders = EXCLUDED.active_riders,
    total_km      = EXCLUDED.total_km,
    computed_at   = now();
END;
$$;

ALTER FUNCTION "public"."refresh_company_co2_stats"(date, uuid[]) OWNER TO "postgres";

COMMENT ON FUNCTION "public"."refresh_company_co2_stats"(date, uuid[]) IS
  'Idempotent upsert of per-company commute-CO₂ stats for the given WEEK (default: current ISO week, Monday); p_company_ids restricts to specific companies (NULL = all, used by cron; the bike_benefits trigger passes the affected company for live updates). Pure SQL over employee_pii.commute_distance_km + bike_benefits lifecycle gate; never reads plaintext PII. Months/all-time roll up via company_co2_summary. See mobipass-backend skill references/co2-commute-engine.md.';

-- SECURITY DEFINER in public is callable by PUBLIC (anon/authenticated) by
-- default — lock it to the engine. Owner (postgres), cron, and the trigger
-- (owned by postgres) execute regardless of these grants.
REVOKE ALL ON FUNCTION "public"."refresh_company_co2_stats"(date, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."refresh_company_co2_stats"(date, uuid[]) TO "service_role";

-- Mon–Fri refresh of the current week at 03:00 UTC (~06:00 Bucharest), after the
-- 02:00 bike-sync window. No weekend runs: with a Mon–Fri work week there is no
-- modelled weekend commuting and the week is closed by Friday — a weekend run
-- would only re-stamp a finished week. The daily run keeps the current week's
-- estimate fresh as riders are delivered/terminated mid-week (it refreshes, it
-- does NOT accumulate day-by-day — the week's estimate is whole from Monday).
SELECT cron.schedule(
  'company-co2-refresh',
  '0 3 * * 1-5',
  $$ SELECT public.refresh_company_co2_stats(); $$
);

-- Seed the current week immediately so the HR console isn't empty post-deploy
-- (zeros until the Phase 2 distance backfill has run).
SELECT public.refresh_company_co2_stats();

-- ---------------------------------------------------------------------------
-- Read model for the HR console. One row per company with the timeframe totals
-- as COLUMNS, so the frontend never sums — it reads its (RLS-scoped) row and
-- picks the column matching the selected timeframe. security_invoker inherits
-- company_co2_stats' RLS (HR/admin own company only).
--   all-time  → all_time_kg
--   last-month→ last_month_kg   (weeks whose Monday falls in the previous month)
--   last-week → last_week_kg    (the previous completed week)
--   last-day  → intentionally ABSENT (sub-week = no honest resolution → UI "-")
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW "public"."company_co2_summary" WITH ("security_invoker"='on') AS
SELECT
  company_id,
  COALESCE(round(sum(kg_co2_saved), 3), 0) AS all_time_kg,
  COALESCE(round(sum(kg_co2_saved) FILTER (
    WHERE period >= date_trunc('month', now() - interval '1 month')::date
      AND period <  date_trunc('month', now())::date), 3), 0) AS last_month_kg,
  COALESCE(round(sum(kg_co2_saved) FILTER (
    WHERE period = date_trunc('week', now() - interval '1 week')::date), 3), 0) AS last_week_kg,
  COALESCE(round(sum(total_km), 3), 0) AS all_time_km
FROM public.company_co2_stats
GROUP BY company_id;

ALTER VIEW "public"."company_co2_summary" OWNER TO "postgres";
GRANT SELECT ON "public"."company_co2_summary" TO "authenticated";

COMMENT ON VIEW "public"."company_co2_summary" IS
  'Internal CO₂ roll-up: one row per company with commute-CO₂ totals per timeframe (all_time_kg, last_month_kg, last_week_kg, all_time_km), summed from the weekly company_co2_stats. Consumed by refresh_company_metrics_co2 to fill company_metrics.co2_* — NOT read by clients directly (the frontend reads the company_metrics table). last-day omitted by design (below the weekly model resolution).';

-- To pause later:
--   SELECT cron.unschedule('company-co2-refresh');
