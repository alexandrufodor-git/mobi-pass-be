-- BellaBike sync — page-queue redesign, part 3/3: the heartbeat schedule.
--
-- bike_sync_tick() is the durable driver. It runs every minute and is a cheap
-- no-op whenever no run is 'running', so it is safe to leave always-on. This is
-- what makes the sync resilient: even if every edge isolate dies, the next tick
-- re-fires workers and re-claims lease-expired units.
--
-- (The daily/weekly kickoff schedules live in 20260605000005; those CREATE the
-- runs, this tick DRAINS them.)

SELECT cron.schedule(
  'bike-sync-tick',
  '* * * * *',
  $$ SELECT public.bike_sync_tick(); $$
);

-- To pause draining (runs already created will stall until re-enabled):
--   SELECT cron.unschedule('bike-sync-tick');
