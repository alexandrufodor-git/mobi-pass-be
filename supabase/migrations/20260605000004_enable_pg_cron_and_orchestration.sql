-- BellaBike sync — orchestration (pg_cron + pg_net invocation).
--
-- Enables pg_cron (the FIRST scheduled job in this DB; the actual schedule is
-- a separate migration, applied after the first manual run is green) and adds
-- the two-function kickoff/invoke pair. Invocation reuses the existing
-- registration-trigger pattern: pg_net → edge fn, secret read from Vault.
--
-- Branches (see locked design §6):
--   SYNC  — pg_cron seeds a run + one enqueued unit per leaf category; the
--           edge fn self-drains it (one category per invocation), then seeds
--           and drains the AUDIT branch.
--   AUDIT — gql_membership sets in_catalog, then verify reconciles.

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ---------------------------------------------------------------------------
-- bike_sync_invoke — fire-and-forget POST to the bike-sync edge fn.
-- The function holds the service-role key in its own runtime env; here we only
-- read a scoped webhook secret from Vault (zero DB access if leaked).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bike_sync_invoke(
  p_run_id uuid,
  p_branch text
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, net, vault AS $$
DECLARE
  v_secret     text;
  v_request_id bigint;
BEGIN
  SELECT decrypted_secret INTO v_secret
    FROM vault.decrypted_secrets
   WHERE name = 'bike_sync_webhook_secret'
   LIMIT 1;

  IF v_secret IS NULL THEN
    RAISE WARNING '[bike_sync_invoke] Vault secret "bike_sync_webhook_secret" not found — invocation skipped';
    RETURN NULL;
  END IF;

  SELECT net.http_post(
    url     := 'https://xlfkdumbsflqxpezolhl.supabase.co/functions/v1/bike-sync',
    headers := jsonb_build_object(
      'Content-Type',     'application/json',
      'x-webhook-secret', v_secret
    ),
    body    := jsonb_build_object('run_id', p_run_id, 'branch', p_branch)
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$$;
COMMENT ON FUNCTION public.bike_sync_invoke(uuid, text) IS 'Fire-and-forget pg_net POST to the bike-sync edge fn for one branch drain. Secret from Vault (bike_sync_webhook_secret).';
GRANT EXECUTE ON FUNCTION public.bike_sync_invoke(uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- bike_sync_kickoff — seed a run + the SYNC branch queue, then fire the first
-- invocation. Called by pg_cron (mode 'daily'/'weekly') or manually
-- (mode 'manual', optional category subset for staged rollout).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bike_sync_kickoff(
  p_mode       text   DEFAULT 'manual',
  p_categories text[] DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c_dealer    constant uuid   := '099380e6-5991-4acc-b737-9815365bf9d1';  -- Bella Bike
  c_leaves    constant text[] := ARRAY['721', '722', '723', '725', '751'];
  v_cats      text[];
  v_watermark timestamptz;
  v_run_id    uuid;
  v_cat       text;
BEGIN
  v_cats := COALESCE(p_categories, c_leaves);

  -- Next delta starts from the last SUCCEEDED run's watermark_to. A
  -- failed/partial run never advanced it, so missed SKUs self-heal.
  SELECT max(watermark_to) INTO v_watermark
    FROM sync_runs
   WHERE dealer_id = c_dealer AND status = 'succeeded';

  INSERT INTO sync_runs (dealer_id, mode, status, watermark_from, watermark_to)
  VALUES (
    c_dealer, p_mode, 'running',
    -- weekly = full reconcile (no updated_at floor); daily/manual = delta.
    CASE WHEN p_mode = 'weekly' THEN NULL ELSE v_watermark END,
    now()
  )
  RETURNING id INTO v_run_id;

  FOREACH v_cat IN ARRAY v_cats
  LOOP
    INSERT INTO sync_units (run_id, branch, kind, category_id)
    VALUES (v_run_id, 'sync', 'rest_category', v_cat);
  END LOOP;

  PERFORM public.bike_sync_invoke(v_run_id, 'sync');
  RETURN v_run_id;
END;
$$;
COMMENT ON FUNCTION public.bike_sync_kickoff(text, text[]) IS 'Seed a BellaBike sync run + SYNC-branch queue (one unit per leaf category) and fire the first edge-fn invocation. p_categories restricts the run for staged manual rollout.';
GRANT EXECUTE ON FUNCTION public.bike_sync_kickoff(text, text[]) TO service_role;
