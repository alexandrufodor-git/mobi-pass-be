-- HR Reports — Plan A, part 1: parameterized metrics RPC + drop redundant CO₂ columns.
--
-- The shipped company_metrics carries CO₂ as timeframe COLUMNS but the COUNTS
-- (active_accounts, active_benefits) as single point-in-time values → not
-- filterable. The FE used to derive windowed counts client-side from
-- profile_invites_with_details; that broke when the view became paginated.
--
-- Plan A: one RPC taking [from,to] that returns ONE value per metric, computed
-- on read. Any range forever, zero schema churn, no slide cron. company_metrics
-- stays the realtime beacon + all-time snapshot; the FE refetches this RPC on
-- each beacon ping (windowed ranges) and reads company_metrics directly for the
-- all-time card. See llm-agent-assist/plans/company-metrics-dashboard.md.

-- ── Parameterized, any-range reader (single value per metric) ─────────────────
-- Semantics mirror the old client-side filter, now server-side:
--   active accounts  = invites currently 'active' whose last_activity ∈ [from,to]
--                      last_activity = COALESCE(bb.updated_at, bo.updated_at,
--                      p.created_at, pi.created_at)  (matches the view's
--                      last_modified_at exactly).
--   active benefits  = bike_benefits currently 'active' touched in [from,to]
--                      (last_activity = bike_benefits.updated_at).
--   co2_kg           = sum of weekly company_co2_stats whose Monday ∈ [from,to].
-- from = NULL → no lower bound (all-time); to defaults to now().
CREATE OR REPLACE FUNCTION "public"."get_company_metrics"(
  "p_from" timestamptz DEFAULT NULL,
  "p_to"   timestamptz DEFAULT now()
) RETURNS TABLE (active_accounts integer, active_benefits integer, co2_kg numeric)
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_company uuid := (select public.auth_company_id());
  v_role    text := (auth.jwt() ->> 'user_role');
  v_to      timestamptz := COALESCE(p_to, now());
BEGIN
  IF v_company IS NULL OR v_role NOT IN ('hr', 'admin') THEN
    RAISE EXCEPTION 'not_authorized' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    -- active accounts whose last activity falls in [from,to]
    (SELECT count(*)::int FROM (
       SELECT pi.id,
              max(COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at)) AS last_activity
       FROM public.profile_invites pi
       LEFT JOIN public.profiles      p  ON p.profile_invite_id = pi.id
       LEFT JOIN public.bike_benefits bb ON bb.user_id = p.user_id
       LEFT JOIN public.bike_orders   bo ON bo.bike_benefit_id = bb.id
       WHERE pi.company_id = v_company
         AND pi.status = 'active'::public.user_profile_status
       GROUP BY pi.id
     ) a
     WHERE (p_from IS NULL OR a.last_activity >= p_from) AND a.last_activity <= v_to),
    -- active benefits touched in [from,to]
    (SELECT count(*)::int FROM public.bike_benefits bb
       JOIN public.profiles p ON p.user_id = bb.user_id
       WHERE p.company_id = v_company
         AND bb.benefit_status = 'active'::public.benefit_status
         AND (p_from IS NULL OR bb.updated_at >= p_from) AND bb.updated_at <= v_to),
    -- CO₂ saved across weeks whose Monday falls in [from,to]
    (SELECT COALESCE(round(sum(s.kg_co2_saved), 3), 0) FROM public.company_co2_stats s
       WHERE s.company_id = v_company
         AND (p_from IS NULL OR s.period >= p_from::date) AND s.period <= v_to::date);
END;
$$;

ALTER FUNCTION "public"."get_company_metrics"(timestamptz, timestamptz) OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."get_company_metrics"(timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."get_company_metrics"(timestamptz, timestamptz) TO "authenticated";

COMMENT ON FUNCTION "public"."get_company_metrics"(timestamptz, timestamptz) IS
  'HR Reports "at a glance" reader. Returns active_accounts / active_benefits / co2_kg for the calling HR/admin''s own company over [p_from, p_to] (p_from NULL = all-time, p_to defaults now()). Computed on read — any range, no precomputed windows. PostgREST: POST /rest/v1/rpc/get_company_metrics. FE refetches on each company_metrics realtime ping. See llm-agent-assist/plans/company-metrics-dashboard.md.';

-- ── Drop the now-redundant windowed CO₂ columns ───────────────────────────────
-- The RPC supersedes co2_last_month_kg / co2_last_week_kg (it serves any ranged
-- CO₂). Keep co2_all_time_kg — it's the direct-push value the all-time card
-- reads off the realtime beacon. Redefine the single writer FIRST so it no
-- longer references the columns, then drop them.
CREATE OR REPLACE FUNCTION "public"."refresh_company_metrics_co2"(
  "p_company_ids" uuid[] DEFAULT NULL
) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.company_metrics AS m
    (company_id, co2_all_time_kg, co2_updated_at)
  SELECT
    c.id,
    COALESCE(s.all_time_kg, 0),
    now()
  FROM public.companies c
  LEFT JOIN (
    SELECT company_id, round(sum(kg_co2_saved), 3) AS all_time_kg
    FROM public.company_co2_stats
    GROUP BY company_id
  ) s ON s.company_id = c.id
  WHERE (p_company_ids IS NULL OR c.id = ANY (p_company_ids))
  ON CONFLICT (company_id) DO UPDATE SET
    co2_all_time_kg = EXCLUDED.co2_all_time_kg,
    co2_updated_at  = now();
END;
$$;

ALTER TABLE "public"."company_metrics"
  DROP COLUMN IF EXISTS "co2_last_month_kg",
  DROP COLUMN IF EXISTS "co2_last_week_kg";

COMMENT ON TABLE "public"."company_metrics" IS
  'Per-company HR-console KPI projection (one row/company): account/benefit counts + all-time commute-CO₂. Engine-maintained via triggers; no client write path. Realtime-published → the FE subscribes to it as a beacon and refetches get_company_metrics for windowed ranges (the all-time card reads this row directly). company_co2_stats remains the authoritative weekly time-series. Skill: references/co2-commute-engine.md.';
