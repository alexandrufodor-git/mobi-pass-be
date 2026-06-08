-- BellaBike sync — activate the nightly schedule (locked design §6, step 6).
--
-- ⚠️ PUSH THIS MIGRATION ONLY AFTER the first manual production run is green
-- (see the runbook in scripts/dev/README-bellabike.md). Pushing it activates
-- unattended nightly syncs immediately. Migrations 0001–0004 are safe to push
-- tonight; this one is the deliberate "go live" switch.
--
-- 02:00 UTC (~05:00 Bucharest), off-peak:
--   Mon–Sat → daily delta (updated_at > watermark)
--   Sun     → weekly full reconcile + soft-delete sweep
-- pg_cron is unbounded; each edge invocation stays within budget via the
-- per-category WorkManager queue.

SELECT cron.schedule(
  'bike-sync-daily',
  '0 2 * * 1-6',
  $$ SELECT public.bike_sync_kickoff('daily'); $$
);

SELECT cron.schedule(
  'bike-sync-weekly',
  '0 2 * * 0',
  $$ SELECT public.bike_sync_kickoff('weekly'); $$
);

-- To pause later:
--   SELECT cron.unschedule('bike-sync-daily');
--   SELECT cron.unschedule('bike-sync-weekly');
