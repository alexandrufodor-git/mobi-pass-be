-- Company CO₂ / CSRD engine — Phase 1 schema.
--
-- Computes per-employee commute emissions, aggregated per company, for the HR
-- console's green-impact / CSRD (Scope-3 Cat-7 commuting) reporting. See the
-- methodology writeup in the mobipass-backend skill: references/co2-commute-engine.md.
--
-- Design (driven by the PII constraint): home coords are encrypted and only
-- decryptable in the edge runtime, so the commute *distance* is computed once
-- there (update-employee-pii) and persisted as the non-sensitive scalar
-- employee_pii.commute_distance_km. The recurring aggregation is then pure SQL
-- over that scalar — it never touches plaintext PII (Phase 3).
--
-- Office location reuses the existing companies.address_lat/lon (already
-- populated and already mobile's work-coords source) — no new office columns.

-- ── employee_pii: derived, non-sensitive commute distance ────────────────────
-- One-way, detour-adjusted (×1.3) km between home and office. Derived from
-- encrypted coords but NOT itself sensitive (not reversible to an address) and
-- intentionally NOT exposed per-employee to HR — only the company aggregate is.
ALTER TABLE "public"."employee_pii"
  ADD COLUMN IF NOT EXISTS "commute_distance_km" numeric,
  ADD COLUMN IF NOT EXISTS "commute_distance_computed_at" timestamptz,
  ADD COLUMN IF NOT EXISTS "commute_distance_source" text
    CONSTRAINT "employee_pii_commute_distance_source_check"
    CHECK ("commute_distance_source" IS NULL OR "commute_distance_source" = ANY (ARRAY['routed', 'estimated']));

COMMENT ON COLUMN "public"."employee_pii"."commute_distance_km" IS
  'Derived one-way commute distance home→office in km. Computed in the edge runtime (update-employee-pii / recompute-commute-distances) from decrypted home coords + companies.address_lat/lon. NULL when coords are missing. Consumed by the per-company CO₂ aggregation (refresh_company_co2_stats); never exposed per-employee to HR.';

COMMENT ON COLUMN "public"."employee_pii"."commute_distance_source" IS
  'Provenance of commute_distance_km (CSRD auditability): ''estimated'' = haversine × 1.3 detour (the v1 default, no external dependency); ''routed'' = OpenRouteService driving-car road distance (opt-in, only when ors_base_url is configured — intended for a self-hosted ORS).';

-- ── bike_benefits: prior commute mode (CSRD baseline capture) ─────────────────
-- The CO₂ figure is "avoided emissions vs. an average-car baseline". GHG
-- Protocol / ESRS E1 asks an auditor to justify that baseline. This optional
-- field captures the rider's prior commute mode (once, at onboarding) so the
-- baseline becomes a measured assumption rather than a blanket one. v1 leaves
-- it NULL and the aggregation assumes the solo-ICE-car baseline for everyone;
-- a future version can refine using this column. See the methodology doc.
ALTER TABLE "public"."bike_benefits"
  ADD COLUMN IF NOT EXISTS "prior_commute_mode" text
    CONSTRAINT "bike_benefits_prior_commute_mode_check"
    CHECK ("prior_commute_mode" IS NULL OR "prior_commute_mode" = ANY (ARRAY[
      'car', 'public_transit', 'bike', 'walk', 'motorcycle', 'other', 'unknown'
    ]));

COMMENT ON COLUMN "public"."bike_benefits"."prior_commute_mode" IS
  'Rider''s commute mode before the e-bike, captured once at onboarding. Used to qualify the CSRD avoided-emissions baseline. NULL = unknown → v1 aggregation assumes the average-car baseline.';

-- ── company_co2_stats: per-company monthly time series (HR-visible) ───────────
CREATE TABLE IF NOT EXISTS "public"."company_co2_stats" (
  "company_id"    uuid NOT NULL REFERENCES "public"."companies"("id") ON DELETE CASCADE,
  "period"        date NOT NULL,                 -- Monday of the ISO week
  "kg_co2_saved"  numeric NOT NULL DEFAULT 0,    -- estimated avoided emissions vs. avg-car baseline
  "active_riders" integer NOT NULL DEFAULT 0,    -- delivered + active riders contributing
  "total_km"      numeric NOT NULL DEFAULT 0,    -- aggregate round-trip commute km for the week
  "computed_at"   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("company_id", "period")
);

ALTER TABLE "public"."company_co2_stats" OWNER TO "postgres";

COMMENT ON TABLE "public"."company_co2_stats" IS
  'Per-company WEEKLY commute-CO₂ aggregate (period = Monday of the ISO week) for the HR / CSRD dashboard. Populated only by the engine (refresh_company_co2_stats via pg_cron) — no client write path. Months/all-time roll up via company_co2_summary. kg_co2_saved is ESTIMATED AVOIDED emissions vs. an average-car baseline (NOT a Scope-3 inventory reduction). Methodology: mobipass-backend skill references/co2-commute-engine.md.';

-- RLS: HR/admin may read only their own company's row. No client writes —
-- service_role (the engine) bypasses RLS.
ALTER TABLE "public"."company_co2_stats" ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON "public"."company_co2_stats" TO "authenticated";
GRANT ALL    ON "public"."company_co2_stats" TO "service_role";

DROP POLICY IF EXISTS "company_co2_stats_hr_select" ON "public"."company_co2_stats";
CREATE POLICY "company_co2_stats_hr_select" ON "public"."company_co2_stats"
  FOR SELECT TO "authenticated"
  USING (
    ((auth.jwt() ->> 'user_role') = ANY (ARRAY['hr', 'admin']))
    AND ("company_id" = (select public.auth_company_id()))
  );
