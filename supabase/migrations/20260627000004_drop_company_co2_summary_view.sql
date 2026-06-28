-- Company CO₂ engine — collapse the redundant roll-up view.
--
-- company_co2_summary stored nothing: it was pure sum()/FILTER glue whose ONLY
-- consumer is refresh_company_metrics_co2() (it LEFT JOINed the view to fill the
-- company_metrics.co2_* columns). The frontend never read it (it reads the
-- company_metrics table). So the view is an extra named object with no
-- independent reason to exist — inline its SQL into the one function that uses
-- it and drop it.
--
-- Behaviour is unchanged: the same all-time / last-month / last-week figures land
-- in company_metrics. The two source-of-truth tables stay:
--   * company_co2_stats  = weekly time-series (ledger; needed for true cumulative)
--   * company_metrics    = denormalised read model (balance; Realtime-published)

-- ── Inline the roll-up that used to live in company_co2_summary ────────────────
CREATE OR REPLACE FUNCTION "public"."refresh_company_metrics_co2"(
  "p_company_ids" uuid[] DEFAULT NULL
) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.company_metrics AS m
    (company_id, co2_all_time_kg, co2_last_month_kg, co2_last_week_kg, co2_updated_at)
  SELECT
    c.id,
    COALESCE(s.all_time_kg,   0),
    COALESCE(s.last_month_kg, 0),
    COALESCE(s.last_week_kg,  0),
    now()
  FROM public.companies c
  LEFT JOIN (
    -- formerly public.company_co2_summary:
    --   all-time  → sum of every week
    --   last-month→ weeks whose Monday falls in the previous calendar month
    --   last-week → the previous completed week
    SELECT
      company_id,
      round(sum(kg_co2_saved), 3) AS all_time_kg,
      round(sum(kg_co2_saved) FILTER (
        WHERE period >= date_trunc('month', now() - interval '1 month')::date
          AND period <  date_trunc('month', now())::date), 3) AS last_month_kg,
      round(sum(kg_co2_saved) FILTER (
        WHERE period = date_trunc('week', now() - interval '1 week')::date), 3) AS last_week_kg
    FROM public.company_co2_stats
    GROUP BY company_id
  ) s ON s.company_id = c.id
  WHERE (p_company_ids IS NULL OR c.id = ANY (p_company_ids))
  ON CONFLICT (company_id) DO UPDATE SET
    co2_all_time_kg   = EXCLUDED.co2_all_time_kg,
    co2_last_month_kg = EXCLUDED.co2_last_month_kg,
    co2_last_week_kg  = EXCLUDED.co2_last_week_kg,
    co2_updated_at    = now();
END;
$$;

-- ── Drop the now-orphaned view ────────────────────────────────────────────────
DROP VIEW IF EXISTS "public"."company_co2_summary";

-- ── Fix the two comments that referenced the dropped view ─────────────────────
COMMENT ON FUNCTION "public"."refresh_company_co2_stats"("p_period" date, "p_company_ids" uuid[]) IS
  'Idempotent upsert of per-company commute-CO₂ stats for the given WEEK (default: current ISO week, Monday); p_company_ids restricts to specific companies (NULL = all, used by cron; the bike_benefits trigger passes the affected company for live updates). Pure SQL over employee_pii.commute_distance_km + bike_benefits lifecycle gate; never reads plaintext PII. Months/all-time roll up inline in refresh_company_metrics_co2 (→ company_metrics). See mobipass-backend skill references/co2-commute-engine.md.';

COMMENT ON TABLE "public"."company_co2_stats" IS
  'Per-company WEEKLY commute-CO₂ aggregate (period = Monday of the ISO week) for the HR / CSRD dashboard. Populated only by the engine (refresh_company_co2_stats via pg_cron) — no client write path. Months/all-time roll up inline in refresh_company_metrics_co2 (→ company_metrics; clients read that table). kg_co2_saved is ESTIMATED AVOIDED emissions vs. an average-car baseline (NOT a Scope-3 inventory reduction). Methodology: mobipass-backend skill references/co2-commute-engine.md.';
