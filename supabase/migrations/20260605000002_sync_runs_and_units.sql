-- BellaBike sync — audit / queue tables (Postgres, CLI-verifiable).
--
-- sync_runs   : one row per nightly fire (rollup counters + watermark).
-- sync_units  : the WorkManager-style queue — one row per category per branch,
--               drained by the bike-sync edge fn (FOR UPDATE SKIP LOCKED),
--               retried 3x with backoff.
-- sync_run_summary : the "DONE list" rollup view (no third table).
--
-- Watermark for the next delta = MAX(watermark_to) WHERE status='succeeded'
-- (see bike_sync_kickoff) → a failed/partial run never advances it, so missed
-- SKUs self-heal next run.

-- ---------------------------------------------------------------------------
-- sync_runs
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "public"."sync_runs" (
    "id"                uuid DEFAULT gen_random_uuid() NOT NULL,
    "dealer_id"         uuid NOT NULL,
    "mode"              text NOT NULL,
    "status"            text NOT NULL DEFAULT 'running',
    "started_at"        timestamp with time zone DEFAULT now() NOT NULL,
    "finished_at"       timestamp with time zone,
    "watermark_from"    timestamp with time zone,
    "watermark_to"      timestamp with time zone,
    "n_fetched"         integer NOT NULL DEFAULT 0,
    "n_inserted"        integer NOT NULL DEFAULT 0,
    "n_updated"         integer NOT NULL DEFAULT 0,
    "n_unchanged"       integer NOT NULL DEFAULT 0,
    "n_failed"          integer NOT NULL DEFAULT 0,
    "n_delisted"        integer NOT NULL DEFAULT 0,
    "n_models_upserted" integer NOT NULL DEFAULT 0,
    "error"             text,
    CONSTRAINT "sync_runs_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "sync_runs_dealer_id_fkey" FOREIGN KEY ("dealer_id")
        REFERENCES "public"."dealers"("id"),
    CONSTRAINT "sync_runs_mode_check"   CHECK ("mode"   IN ('daily', 'weekly', 'manual')),
    CONSTRAINT "sync_runs_status_check" CHECK ("status" IN ('running', 'succeeded', 'partial', 'failed'))
);

ALTER TABLE "public"."sync_runs" OWNER TO "postgres";
COMMENT ON TABLE "public"."sync_runs" IS 'One row per BellaBike sync fire. Watermark for the next delta = MAX(watermark_to) WHERE status=''succeeded''.';

CREATE INDEX "idx_sync_runs_dealer_status" ON "public"."sync_runs" USING btree ("dealer_id", "status", "started_at" DESC);

-- ---------------------------------------------------------------------------
-- sync_units — the WorkManager queue
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "public"."sync_units" (
    "id"                uuid DEFAULT gen_random_uuid() NOT NULL,
    "run_id"            uuid NOT NULL,
    "branch"            text NOT NULL,
    "kind"              text NOT NULL,
    "category_id"       text,
    "status"            text NOT NULL DEFAULT 'enqueued',
    "attempts"          integer NOT NULL DEFAULT 0,
    "next_retry_at"     timestamp with time zone,
    "n_fetched"         integer NOT NULL DEFAULT 0,
    "n_upserted"        integer NOT NULL DEFAULT 0,
    "n_models_upserted" integer NOT NULL DEFAULT 0,
    "n_failed"          integer NOT NULL DEFAULT 0,
    "error"             text,
    "started_at"        timestamp with time zone,
    "finished_at"       timestamp with time zone,
    "created_at"        timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT "sync_units_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "sync_units_run_id_fkey" FOREIGN KEY ("run_id")
        REFERENCES "public"."sync_runs"("id") ON DELETE CASCADE,
    CONSTRAINT "sync_units_branch_check" CHECK ("branch" IN ('sync', 'audit')),
    CONSTRAINT "sync_units_kind_check"   CHECK ("kind"   IN ('rest_category', 'gql_membership', 'verify')),
    CONSTRAINT "sync_units_status_check" CHECK ("status" IN ('enqueued', 'running', 'succeeded', 'failed', 'skipped'))
);

ALTER TABLE "public"."sync_units" OWNER TO "postgres";
COMMENT ON TABLE "public"."sync_units" IS 'WorkManager-style queue: one unit per category per branch. Drained by the bike-sync edge fn via FOR UPDATE SKIP LOCKED; retried 3x with backoff (next_retry_at).';

-- The hot path: claim_next_sync_unit orders enqueued units by created_at.
CREATE INDEX "idx_sync_units_claim" ON "public"."sync_units" USING btree ("run_id", "branch", "status", "created_at");

-- ---------------------------------------------------------------------------
-- sync_run_summary — the "DONE list" rollup (one row per run)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW "public"."sync_run_summary" AS
 SELECT r."id",
        r."dealer_id",
        r."mode",
        r."status",
        r."started_at",
        r."finished_at",
        r."watermark_from",
        r."watermark_to",
        r."n_fetched",
        r."n_inserted",
        r."n_updated",
        r."n_unchanged",
        r."n_failed",
        r."n_delisted",
        r."n_models_upserted",
        r."error",
        count(u."id")                                          AS n_units,
        count(u."id") FILTER (WHERE u."status" = 'succeeded')  AS units_succeeded,
        count(u."id") FILTER (WHERE u."status" = 'failed')     AS units_failed,
        count(u."id") FILTER (WHERE u."status" = 'skipped')    AS units_skipped,
        count(u."id") FILTER (WHERE u."status" IN ('enqueued', 'running')) AS units_pending
   FROM "public"."sync_runs" r
   LEFT JOIN "public"."sync_units" u ON u."run_id" = r."id"
  GROUP BY r."id";

ALTER VIEW "public"."sync_run_summary" OWNER TO "postgres";
COMMENT ON VIEW "public"."sync_run_summary" IS 'Per-run rollup of BellaBike sync: run counters + unit status tallies. Local verify: select * from sync_run_summary order by started_at desc;';

-- ---------------------------------------------------------------------------
-- Access — operational tables. service_role (edge fn) + postgres (pg_cron)
-- write; authenticated may read for an ops dashboard. RLS on, read-only policy.
-- ---------------------------------------------------------------------------
ALTER TABLE "public"."sync_runs"  ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."sync_units" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "sync_runs_authenticated_select"  ON "public"."sync_runs"  FOR SELECT TO "authenticated" USING (true);
CREATE POLICY "sync_units_authenticated_select" ON "public"."sync_units" FOR SELECT TO "authenticated" USING (true);

GRANT ALL ON TABLE "public"."sync_runs"        TO "service_role";
GRANT ALL ON TABLE "public"."sync_units"       TO "service_role";
GRANT SELECT ON TABLE "public"."sync_runs"     TO "authenticated";
GRANT SELECT ON TABLE "public"."sync_units"    TO "authenticated";
GRANT SELECT ON "public"."sync_run_summary"    TO "authenticated";
GRANT ALL    ON "public"."sync_run_summary"    TO "service_role";
