-- Company CO₂ engine — Phase 4: company_metrics projection + realtime.
--
-- Single denormalised per-company KPI row the HR console reads in ONE call and
-- subscribes to over Realtime (views can't be published; a table can). Holds the
-- "At a glance" counts + commute-CO₂ roll-ups, and is the home for future
-- dashboard metrics. Kept in sync by disjoint-column refreshers fired by
-- statement-level triggers on the source tables. `company_co2_stats` stays the
-- authoritative weekly time-series; this table is a projection off it.
--
-- Design (per architecture review):
--   * Two disjoint refreshers — counts vs CO₂ — so the two trigger paths never
--     read-modify-write each other's columns (no stale-sibling race).
--   * CO₂ reaches the metrics row ONLY through company_co2_stats (its single
--     writer): benefit change → refresh_company_co2_stats → company_co2_stats
--     trigger → refresh_company_metrics_co2. bike_benefits never writes CO₂
--     columns directly. No write-back to sources → no trigger cycle.
--   * Column-scoped, statement-level triggers (transition tables) → one recompute
--     per affected company per statement, even for bulk writes.

-- ── Table ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS "public"."company_metrics" (
  "company_id"        uuid PRIMARY KEY REFERENCES "public"."companies"("id") ON DELETE CASCADE,
  "total_accounts"    integer NOT NULL DEFAULT 0,
  "active_accounts"   integer NOT NULL DEFAULT 0,
  "active_benefits"   integer NOT NULL DEFAULT 0,
  "co2_all_time_kg"   numeric NOT NULL DEFAULT 0,
  "co2_last_month_kg" numeric NOT NULL DEFAULT 0,
  "co2_last_week_kg"  numeric NOT NULL DEFAULT 0,
  "counts_updated_at" timestamptz,
  "co2_updated_at"    timestamptz
);

ALTER TABLE "public"."company_metrics" OWNER TO "postgres";

COMMENT ON TABLE "public"."company_metrics" IS
  'Per-company HR-console KPI projection (one row/company): account/benefit counts + commute-CO₂ roll-ups (all-time / last-month / last-week; last-day omitted — sub-week has no honest resolution). Engine-maintained via triggers; no client write path. Realtime-published. company_co2_stats remains the authoritative weekly time-series. Frontend reads this single row + subscribes to it. Skill: references/co2-commute-engine.md.';

ALTER TABLE "public"."company_metrics" ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON "public"."company_metrics" TO "authenticated";
GRANT ALL    ON "public"."company_metrics" TO "service_role";

DROP POLICY IF EXISTS "company_metrics_hr_select" ON "public"."company_metrics";
CREATE POLICY "company_metrics_hr_select" ON "public"."company_metrics"
  FOR SELECT TO "authenticated"
  USING (
    ((auth.jwt() ->> 'user_role') = ANY (ARRAY['hr', 'admin']))
    AND ("company_id" = (select public.auth_company_id()))
  );

-- ── Refreshers (disjoint columns, idempotent upsert) ──────────────────────────
CREATE OR REPLACE FUNCTION "public"."refresh_company_metrics_counts"(
  "p_company_ids" uuid[] DEFAULT NULL
) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.company_metrics AS m
    (company_id, total_accounts, active_accounts, active_benefits, counts_updated_at)
  SELECT
    c.id,
    (SELECT count(*) FROM public.profile_invites pi WHERE pi.company_id = c.id),
    (SELECT count(*) FROM public.profile_invites pi
       WHERE pi.company_id = c.id AND pi.status = 'active'::public.user_profile_status),
    (SELECT count(*) FROM public.bike_benefits bb
       JOIN public.profiles p ON p.user_id = bb.user_id
       WHERE p.company_id = c.id AND bb.benefit_status = 'active'::public.benefit_status),
    now()
  FROM public.companies c
  WHERE (p_company_ids IS NULL OR c.id = ANY (p_company_ids))
  ON CONFLICT (company_id) DO UPDATE SET
    total_accounts    = EXCLUDED.total_accounts,
    active_accounts   = EXCLUDED.active_accounts,
    active_benefits   = EXCLUDED.active_benefits,
    counts_updated_at = now();
END;
$$;

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
  LEFT JOIN public.company_co2_summary s ON s.company_id = c.id
  WHERE (p_company_ids IS NULL OR c.id = ANY (p_company_ids))
  ON CONFLICT (company_id) DO UPDATE SET
    co2_all_time_kg   = EXCLUDED.co2_all_time_kg,
    co2_last_month_kg = EXCLUDED.co2_last_month_kg,
    co2_last_week_kg  = EXCLUDED.co2_last_week_kg,
    co2_updated_at    = now();
END;
$$;

ALTER FUNCTION "public"."refresh_company_metrics_counts"(uuid[]) OWNER TO "postgres";
ALTER FUNCTION "public"."refresh_company_metrics_co2"(uuid[]) OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."refresh_company_metrics_counts"(uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."refresh_company_metrics_co2"(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."refresh_company_metrics_counts"(uuid[]) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."refresh_company_metrics_co2"(uuid[]) TO "service_role";

-- ── Trigger functions ─────────────────────────────────────────────────────────
-- bike_benefits change → refresh the company's weekly CO₂ stats (which cascades
-- to the metrics CO₂ columns via the company_co2_stats trigger) AND its counts.
CREATE OR REPLACE FUNCTION "public"."co2_refresh_on_benefit_change"() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_co2 uuid[];
  v_cnt uuid[];
BEGIN
  SELECT array_agg(DISTINCT ep.company_id) INTO v_co2
  FROM changed_benefits cb JOIN public.employee_pii ep ON ep.user_id = cb.user_id
  WHERE ep.company_id IS NOT NULL;

  SELECT array_agg(DISTINCT p.company_id) INTO v_cnt
  FROM changed_benefits cb JOIN public.profiles p ON p.user_id = cb.user_id
  WHERE p.company_id IS NOT NULL;

  IF v_co2 IS NOT NULL THEN
    PERFORM public.refresh_company_co2_stats(date_trunc('week', now())::date, v_co2);
  END IF;
  IF v_cnt IS NOT NULL THEN
    PERFORM public.refresh_company_metrics_counts(v_cnt);
  END IF;
  RETURN NULL;
END;
$$;

-- Statement-level (INSERT/DELETE): batches bulk REGES writes to one recompute.
CREATE OR REPLACE FUNCTION "public"."metrics_counts_on_invite_change"() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_companies uuid[];
BEGIN
  SELECT array_agg(DISTINCT company_id) INTO v_companies
  FROM changed_invites WHERE company_id IS NOT NULL;
  IF v_companies IS NOT NULL THEN
    PERFORM public.refresh_company_metrics_counts(v_companies);
  END IF;
  RETURN NULL;
END;
$$;

-- Row-level + column-scoped (UPDATE): fires ONLY when status/company_id change,
-- so the profile_invites SSOT's normal write path (email/department/etc.) is
-- untouched. Row-level is required because Postgres forbids a column list on a
-- transition-table (statement-level) trigger.
CREATE OR REPLACE FUNCTION "public"."metrics_counts_on_invite_row"() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  PERFORM public.refresh_company_metrics_counts(
    ARRAY(SELECT DISTINCT cid
          FROM unnest(ARRAY[NEW.company_id, OLD.company_id]) AS cid
          WHERE cid IS NOT NULL)
  );
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."metrics_co2_on_stats_change"() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_companies uuid[];
BEGIN
  SELECT array_agg(DISTINCT company_id) INTO v_companies
  FROM changed_stats WHERE company_id IS NOT NULL;
  IF v_companies IS NOT NULL THEN
    PERFORM public.refresh_company_metrics_co2(v_companies);
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."metrics_seed_on_company_insert"() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_companies uuid[];
BEGIN
  SELECT array_agg(id) INTO v_companies FROM changed_companies;
  IF v_companies IS NOT NULL THEN
    PERFORM public.refresh_company_metrics_counts(v_companies);
    PERFORM public.refresh_company_metrics_co2(v_companies);
  END IF;
  RETURN NULL;
END;
$$;

ALTER FUNCTION "public"."co2_refresh_on_benefit_change"()   OWNER TO "postgres";
ALTER FUNCTION "public"."metrics_counts_on_invite_change"() OWNER TO "postgres";
ALTER FUNCTION "public"."metrics_counts_on_invite_row"()    OWNER TO "postgres";
ALTER FUNCTION "public"."metrics_co2_on_stats_change"()     OWNER TO "postgres";
ALTER FUNCTION "public"."metrics_seed_on_company_insert"()  OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."co2_refresh_on_benefit_change"()   FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."metrics_counts_on_invite_change"() FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."metrics_counts_on_invite_row"()    FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."metrics_co2_on_stats_change"()     FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."metrics_seed_on_company_insert"()  FROM PUBLIC;

-- ── Triggers (statement-level + transition tables) ────────────────────────────
-- NB: Postgres forbids a transition table on a multi-event trigger, so INSERT /
-- UPDATE / DELETE are separate triggers sharing one function + transition-table
-- name.
--
-- bike_benefits: any change recomputes (status is trigger-derived, so no column
-- scope — a step change can flip benefit_status via the BEFORE trigger).
DROP TRIGGER IF EXISTS "co2_refresh_benefit_ins" ON "public"."bike_benefits";
CREATE TRIGGER "co2_refresh_benefit_ins"
  AFTER INSERT ON "public"."bike_benefits"
  REFERENCING NEW TABLE AS changed_benefits
  FOR EACH STATEMENT EXECUTE FUNCTION "public"."co2_refresh_on_benefit_change"();
DROP TRIGGER IF EXISTS "co2_refresh_benefit_upd" ON "public"."bike_benefits";
CREATE TRIGGER "co2_refresh_benefit_upd"
  AFTER UPDATE ON "public"."bike_benefits"
  REFERENCING NEW TABLE AS changed_benefits
  FOR EACH STATEMENT EXECUTE FUNCTION "public"."co2_refresh_on_benefit_change"();
DROP TRIGGER IF EXISTS "co2_refresh_benefit_del" ON "public"."bike_benefits";
CREATE TRIGGER "co2_refresh_benefit_del"
  AFTER DELETE ON "public"."bike_benefits"
  REFERENCING OLD TABLE AS changed_benefits
  FOR EACH STATEMENT EXECUTE FUNCTION "public"."co2_refresh_on_benefit_change"();

-- profile_invites (SSOT) drives total_accounts / active_accounts.
--   INSERT/DELETE → statement-level, batches bulk REGES writes to one recompute.
--   UPDATE        → row-level + column-scoped to (status, company_id) ONLY, so
--                   the SSOT's other writes (email, department, …) trigger
--                   nothing. (Column scope is impossible on the transition-table
--                   triggers, which is why UPDATE is the odd one out.)
DROP TRIGGER IF EXISTS "metrics_counts_invite_ins" ON "public"."profile_invites";
CREATE TRIGGER "metrics_counts_invite_ins"
  AFTER INSERT ON "public"."profile_invites"
  REFERENCING NEW TABLE AS changed_invites
  FOR EACH STATEMENT EXECUTE FUNCTION "public"."metrics_counts_on_invite_change"();
DROP TRIGGER IF EXISTS "metrics_counts_invite_upd" ON "public"."profile_invites";
CREATE TRIGGER "metrics_counts_invite_upd"
  AFTER UPDATE OF "status", "company_id" ON "public"."profile_invites"
  FOR EACH ROW EXECUTE FUNCTION "public"."metrics_counts_on_invite_row"();
DROP TRIGGER IF EXISTS "metrics_counts_invite_del" ON "public"."profile_invites";
CREATE TRIGGER "metrics_counts_invite_del"
  AFTER DELETE ON "public"."profile_invites"
  REFERENCING OLD TABLE AS changed_invites
  FOR EACH STATEMENT EXECUTE FUNCTION "public"."metrics_counts_on_invite_change"();

-- company_co2_stats: the single writer of metrics CO₂ columns.
DROP TRIGGER IF EXISTS "metrics_co2_stats_ins" ON "public"."company_co2_stats";
CREATE TRIGGER "metrics_co2_stats_ins"
  AFTER INSERT ON "public"."company_co2_stats"
  REFERENCING NEW TABLE AS changed_stats
  FOR EACH STATEMENT EXECUTE FUNCTION "public"."metrics_co2_on_stats_change"();
DROP TRIGGER IF EXISTS "metrics_co2_stats_upd" ON "public"."company_co2_stats";
CREATE TRIGGER "metrics_co2_stats_upd"
  AFTER UPDATE ON "public"."company_co2_stats"
  REFERENCING NEW TABLE AS changed_stats
  FOR EACH STATEMENT EXECUTE FUNCTION "public"."metrics_co2_on_stats_change"();
DROP TRIGGER IF EXISTS "metrics_co2_stats_del" ON "public"."company_co2_stats";
CREATE TRIGGER "metrics_co2_stats_del"
  AFTER DELETE ON "public"."company_co2_stats"
  REFERENCING OLD TABLE AS changed_stats
  FOR EACH STATEMENT EXECUTE FUNCTION "public"."metrics_co2_on_stats_change"();

-- companies: seed a zero metrics row for new companies.
DROP TRIGGER IF EXISTS "metrics_seed_company_ins" ON "public"."companies";
CREATE TRIGGER "metrics_seed_company_ins"
  AFTER INSERT ON "public"."companies"
  REFERENCING NEW TABLE AS changed_companies
  FOR EACH STATEMENT EXECUTE FUNCTION "public"."metrics_seed_on_company_insert"();

-- ── Seed existing companies ───────────────────────────────────────────────────
SELECT public.refresh_company_metrics_counts();
SELECT public.refresh_company_metrics_co2();

-- ── Realtime: publish company_metrics (company_id PK is in the replica identity,
-- so the RLS old-record check on UPDATE works without REPLICA IDENTITY FULL). ──
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'company_metrics'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.company_metrics;
  END IF;
END
$$;
