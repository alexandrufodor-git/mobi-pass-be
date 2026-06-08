-- BellaBike sync — RE-ENABLE the nightly schedule.
--
-- The three cron jobs were unscheduled in prod during the 2026-06-07 false-
-- delist incident (manual cron.unschedule of daily/weekly/tick). Re-enabling is
-- safe now: migration 20260608000004 removed delisting entirely (the AUDIT
-- branch is a no-op, no failure-to-observe sweep can fire), and the Cloudflare
-- 403 is resolved (CF Access service token in Vault), so the REST sync drains
-- cleanly. Mirrors the original schedules in 20260605000005 + 20260606000003.
--
-- 02:00 UTC (~05:00 Bucharest), off-peak:
--   Mon–Sat → daily delta (updated_at > watermark)
--   Sun     → weekly full reconcile (re-upsert; NO delete — sweep removed)
--   tick    → every minute, drains running runs (cheap no-op when idle)
--
-- Idempotent: drop any existing job by name first (cron.unschedule errors on a
-- missing job, so guard via the catalog), then (re)create.

DO $$
BEGIN
  PERFORM cron.unschedule(jobname)
  FROM cron.job
  WHERE jobname IN ('bike-sync-daily', 'bike-sync-weekly', 'bike-sync-tick');
END $$;

SELECT cron.schedule('bike-sync-daily',  '0 2 * * 1-6', $$ SELECT public.bike_sync_kickoff('daily');  $$);
SELECT cron.schedule('bike-sync-weekly', '0 2 * * 0',   $$ SELECT public.bike_sync_kickoff('weekly'); $$);
SELECT cron.schedule('bike-sync-tick',   '* * * * *',   $$ SELECT public.bike_sync_tick(); $$);

-- To pause again:
--   SELECT cron.unschedule('bike-sync-daily');
--   SELECT cron.unschedule('bike-sync-weekly');
--   SELECT cron.unschedule('bike-sync-tick');
