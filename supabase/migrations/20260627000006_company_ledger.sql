-- HR Reports — Plan A, part 2: weekly point-in-time ledger for the monthly chart.
--
-- The Reports page's top-right chart is a 12-month TREND of currently-active
-- accounts/benefits (a STOCK question — "how many were active at month end?" —
-- deliberately different from the cards' engagement-in-window). Realtime can't
-- push history and company_metrics holds only the live balance, so we sample it
-- into a frozen weekly snapshot and roll up to month-end for the chart.
--
-- No triggers: company_metrics is already the exact read model. A daily cron
-- re-stamps the current ISO week's row; on week rollover the prior week's value
-- is frozen. See llm-agent-assist/plans/company-metrics-dashboard.md.

-- ── Weekly snapshot table ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS "public"."company_ledger" (
  "company_id"      uuid NOT NULL REFERENCES "public"."companies"("id") ON DELETE CASCADE,
  "period"          date NOT NULL,              -- Monday of the ISO week
  "total_accounts"  integer NOT NULL DEFAULT 0,
  "active_accounts" integer NOT NULL DEFAULT 0,
  "active_benefits" integer NOT NULL DEFAULT 0,
  "computed_at"     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("company_id", "period")
);

ALTER TABLE "public"."company_ledger" OWNER TO "postgres";

COMMENT ON TABLE "public"."company_ledger" IS
  'Per-company WEEKLY point-in-time snapshot (period = Monday) of currently-active account/benefit counts, sampled off company_metrics by refresh_company_ledger (daily cron). Frozen on week rollover. Feeds the HR Reports monthly trend chart via company_metrics_monthly. No client write path. See llm-agent-assist/plans/company-metrics-dashboard.md.';

-- RLS: HR/admin read only their own company's rows. No client writes —
-- service_role (the cron) bypasses RLS.
ALTER TABLE "public"."company_ledger" ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON "public"."company_ledger" TO "authenticated";
GRANT ALL    ON "public"."company_ledger" TO "service_role";

DROP POLICY IF EXISTS "company_ledger_hr_select" ON "public"."company_ledger";
CREATE POLICY "company_ledger_hr_select" ON "public"."company_ledger"
  FOR SELECT TO "authenticated"
  USING (
    ((auth.jwt() ->> 'user_role') = ANY (ARRAY['hr', 'admin']))
    AND ("company_id" = (select public.auth_company_id()))
  );

-- ── Refresher: sample company_metrics into the current week's row ─────────────
CREATE OR REPLACE FUNCTION "public"."refresh_company_ledger"() RETURNS void
  LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $$
  INSERT INTO public.company_ledger
    (company_id, period, total_accounts, active_accounts, active_benefits, computed_at)
  SELECT company_id, date_trunc('week', now())::date,
         total_accounts, active_accounts, active_benefits, now()
  FROM public.company_metrics
  ON CONFLICT (company_id, period) DO UPDATE SET
    total_accounts  = EXCLUDED.total_accounts,
    active_accounts = EXCLUDED.active_accounts,
    active_benefits = EXCLUDED.active_benefits,
    computed_at     = now();
$$;

ALTER FUNCTION "public"."refresh_company_ledger"() OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."refresh_company_ledger"() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."refresh_company_ledger"() TO "service_role";

COMMENT ON FUNCTION "public"."refresh_company_ledger"() IS
  'Idempotent upsert of the current ISO week''s company_ledger row from company_metrics (one row/company/week, re-stamped daily, frozen on rollover). Daily pg_cron job company-ledger-refresh. See llm-agent-assist/plans/company-metrics-dashboard.md.';

-- ── Monthly chart read: last snapshot per (company, month) ────────────────────
CREATE OR REPLACE VIEW "public"."company_metrics_monthly" WITH ("security_invoker"='on') AS
SELECT DISTINCT ON (company_id, date_trunc('month', period))
  company_id,
  date_trunc('month', period)::date AS month,
  active_accounts,
  active_benefits,
  total_accounts
FROM public.company_ledger
ORDER BY company_id, date_trunc('month', period), period DESC;   -- last snapshot per month

ALTER VIEW "public"."company_metrics_monthly" OWNER TO "postgres";
GRANT SELECT ON "public"."company_metrics_monthly" TO "authenticated";

COMMENT ON VIEW "public"."company_metrics_monthly" IS
  'HR Reports monthly trend chart: per (company, month) the END-OF-MONTH balance (last weekly company_ledger snapshot in the month) of currently-active accounts/benefits. security_invoker inherits company_ledger RLS (HR/admin own company). FE: GET /rest/v1/company_metrics_monthly?month=gte.<from>&month=lte.<to>. Frozen history → no realtime.';

-- ── Daily cron (every day, so the frozen weekly value is the true week-end) ───
SELECT cron.schedule(
  'company-ledger-refresh',
  '0 3 * * *',
  $$ SELECT public.refresh_company_ledger(); $$
);

-- Seed the current week immediately so the chart isn't empty post-deploy.
SELECT public.refresh_company_ledger();

-- To pause later:
--   SELECT cron.unschedule('company-ledger-refresh');
