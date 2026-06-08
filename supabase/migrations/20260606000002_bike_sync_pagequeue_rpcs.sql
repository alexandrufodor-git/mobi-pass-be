-- BellaBike sync — page-queue redesign, part 2/3: RPCs + cron driver.
--
-- Replaces the self-chain-only orchestration with a lease-based queue driven by
-- a pg_cron heartbeat:
--   • claim_next_sync_unit  — now takes a LEASE; a unit is claimable when it is
--                             enqueued OR its lease has expired (crash recovery).
--   • complete_sync_unit    — clears the lease on terminal/retry.
--   • enqueue_page_units    — a prepare unit fans out one rest_page unit per page.
--   • bike_sync_kickoff     — seeds one `prepare` unit per category (not a whole
--                             category of work).
--   • bike_sync_invoke      — bumped pg_net timeout (pages take a few seconds).
--   • bike_sync_tick        — cron heartbeat: keeps MAX_LANES workers draining
--                             each active run, transitions sync→audit, finalizes.
--                             Liveness no longer depends on any single isolate.

-- ── claim_next_sync_unit — lease-based pop (enqueued OR lease-expired) ────────
DROP FUNCTION IF EXISTS public.claim_next_sync_unit(uuid, text);
CREATE OR REPLACE FUNCTION public.claim_next_sync_unit(
  p_run_id        uuid,
  p_branch        text,
  p_lease_seconds integer DEFAULT 90
) RETURNS public.sync_units
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_unit public.sync_units;
BEGIN
  UPDATE sync_units SET
    status       = 'running',
    attempts     = attempts + 1,
    started_at   = COALESCE(started_at, now()),
    leased_until = now() + (p_lease_seconds * interval '1 second')
  WHERE id = (
    SELECT id FROM sync_units
    WHERE run_id = p_run_id
      AND branch = p_branch
      AND (
            (status = 'enqueued' AND (next_retry_at IS NULL OR next_retry_at <= now()))
         OR (status = 'running'  AND leased_until IS NOT NULL AND leased_until < now())
      )
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 1
  )
  RETURNING * INTO v_unit;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN v_unit;
END;
$$;
COMMENT ON FUNCTION public.claim_next_sync_unit(uuid, text, integer) IS 'Lease-based queue pop: claims an enqueued unit OR steals one whose lease expired (dead worker). FOR UPDATE SKIP LOCKED. Sets leased_until = now()+p_lease_seconds.';
GRANT EXECUTE ON FUNCTION public.claim_next_sync_unit(uuid, text, integer) TO service_role;

-- ── complete_sync_unit — same as before, but always clears the lease ─────────
CREATE OR REPLACE FUNCTION public.complete_sync_unit(
  p_unit_id    uuid,
  p_status     text,
  p_n_fetched  integer DEFAULT 0,
  p_n_inserted integer DEFAULT 0,
  p_n_updated  integer DEFAULT 0,
  p_n_models   integer DEFAULT 0,
  p_n_failed   integer DEFAULT 0,
  p_error      text    DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_attempts integer;
  v_run_id   uuid;
BEGIN
  SELECT attempts, run_id INTO v_attempts, v_run_id FROM sync_units WHERE id = p_unit_id;

  IF p_status = 'failed' AND v_attempts < 3 THEN
    UPDATE sync_units SET
      status        = 'enqueued',
      leased_until  = NULL,
      next_retry_at = now() + (v_attempts * interval '20 seconds'),
      error         = p_error
    WHERE id = p_unit_id;
    RETURN 'retry';
  END IF;

  UPDATE sync_units SET
    status            = p_status,
    leased_until      = NULL,
    n_fetched         = p_n_fetched,
    n_upserted        = p_n_inserted + p_n_updated,
    n_models_upserted = p_n_models,
    n_failed          = p_n_failed,
    error             = p_error,
    finished_at       = now()
  WHERE id = p_unit_id;

  UPDATE sync_runs SET
    n_fetched         = n_fetched         + p_n_fetched,
    n_inserted        = n_inserted        + p_n_inserted,
    n_updated         = n_updated         + p_n_updated,
    n_models_upserted = n_models_upserted + p_n_models,
    n_failed          = n_failed          + p_n_failed
  WHERE id = v_run_id;

  RETURN p_status;
END;
$$;
GRANT EXECUTE ON FUNCTION public.complete_sync_unit(uuid, text, integer, integer, integer, integer, integer, text) TO service_role;

-- ── enqueue_page_units — prepare unit fans out rest_page units ───────────────
CREATE OR REPLACE FUNCTION public.enqueue_page_units(
  p_run_id      uuid,
  p_category_id text,
  p_total       integer,
  p_page_size   integer
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pages integer := CEIL(GREATEST(p_total, 0)::numeric / GREATEST(p_page_size, 1));
  p       integer;
BEGIN
  FOR p IN 1..v_pages LOOP
    INSERT INTO sync_units (run_id, branch, kind, category_id, page, page_size)
    VALUES (p_run_id, 'sync', 'rest_page', p_category_id, p, p_page_size)
    ON CONFLICT (run_id, branch, category_id, page) WHERE kind = 'rest_page'
    DO NOTHING;
  END LOOP;
  RETURN v_pages;
END;
$$;
COMMENT ON FUNCTION public.enqueue_page_units(uuid, text, integer, integer) IS 'Fan out one rest_page unit per page of a category (idempotent via the uq_sync_units_page index).';
GRANT EXECUTE ON FUNCTION public.enqueue_page_units(uuid, text, integer, integer) TO service_role;

-- ── seed_audit_units — idempotent now (tick AND the edge fn may both call) ───
CREATE OR REPLACE FUNCTION public.seed_audit_units(p_run_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM sync_units WHERE run_id = p_run_id AND branch = 'audit') THEN
    RETURN;   -- already seeded
  END IF;
  INSERT INTO sync_units (run_id, branch, kind) VALUES
    (p_run_id, 'audit', 'gql_membership'),
    (p_run_id, 'audit', 'verify');
END;
$$;
GRANT EXECUTE ON FUNCTION public.seed_audit_units(uuid) TO service_role;

-- ── bike_sync_invoke — base URL from Vault + a real timeout (pages ~secs) ────
CREATE OR REPLACE FUNCTION public.bike_sync_invoke(
  p_run_id uuid,
  p_branch text
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, net, vault AS $$
DECLARE
  v_secret     text;
  v_base       text;
  v_request_id bigint;
BEGIN
  SELECT decrypted_secret INTO v_secret
    FROM vault.decrypted_secrets WHERE name = 'bike_sync_webhook_secret' LIMIT 1;
  IF v_secret IS NULL THEN
    RAISE WARNING '[bike_sync_invoke] Vault secret "bike_sync_webhook_secret" not found — invocation skipped';
    RETURN NULL;
  END IF;

  SELECT decrypted_secret INTO v_base
    FROM vault.decrypted_secrets WHERE name = 'bike_sync_base_url' LIMIT 1;
  v_base := COALESCE(v_base, 'https://xlfkdumbsflqxpezolhl.supabase.co');

  SELECT net.http_post(
    url     := v_base || '/functions/v1/bike-sync',
    headers := jsonb_build_object(
      'Content-Type',     'application/json',
      'x-webhook-secret', v_secret
    ),
    body    := jsonb_build_object('run_id', p_run_id, 'branch', p_branch),
    timeout_milliseconds := 30000
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.bike_sync_invoke(uuid, text) TO service_role;

-- ── bike_sync_kickoff — seed one prepare unit per category ───────────────────
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

  SELECT max(watermark_to) INTO v_watermark
    FROM sync_runs WHERE dealer_id = c_dealer AND status = 'succeeded';

  INSERT INTO sync_runs (dealer_id, mode, status, watermark_from, watermark_to)
  VALUES (
    c_dealer, p_mode, 'running',
    CASE WHEN p_mode = 'weekly' THEN NULL ELSE v_watermark END,
    now()
  )
  RETURNING id INTO v_run_id;

  -- One prepare unit per category; each fans out its own rest_page units.
  FOREACH v_cat IN ARRAY v_cats LOOP
    INSERT INTO sync_units (run_id, branch, kind, category_id)
    VALUES (v_run_id, 'sync', 'prepare', v_cat);
  END LOOP;

  PERFORM public.bike_sync_invoke(v_run_id, 'sync');
  RETURN v_run_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.bike_sync_kickoff(text, text[]) TO service_role;

-- ── bike_sync_tick — cron heartbeat that drives every active run ─────────────
-- Keeps up to MAX_LANES workers draining each running sync_run, transitions
-- sync→audit when sync drains, and finalizes when everything is terminal.
-- Idempotent + safe to over-fire (claim uses SKIP LOCKED + leases), but it caps
-- new invocations at MAX_LANES − in-flight so concurrency (and vendor request
-- rate) stays bounded.
CREATE OR REPLACE FUNCTION public.bike_sync_tick()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c_max_lanes constant integer := 2;   -- concurrency cap (vendor rate-limit knob)
  r            record;
  v_inflight   integer;
  v_sync_claim integer;
  v_audit_claim integer;
  v_slots      integer;
  v_fired      integer := 0;
  i            integer;
BEGIN
  FOR r IN SELECT id FROM sync_runs WHERE status = 'running' LOOP
    SELECT count(*) INTO v_inflight FROM sync_units
      WHERE run_id = r.id AND status = 'running'
        AND leased_until IS NOT NULL AND leased_until >= now();

    SELECT count(*) INTO v_sync_claim FROM sync_units
      WHERE run_id = r.id AND branch = 'sync'
        AND ( (status = 'enqueued' AND (next_retry_at IS NULL OR next_retry_at <= now()))
           OR (status = 'running'  AND leased_until IS NOT NULL AND leased_until < now()) );

    SELECT count(*) INTO v_audit_claim FROM sync_units
      WHERE run_id = r.id AND branch = 'audit'
        AND ( (status = 'enqueued' AND (next_retry_at IS NULL OR next_retry_at <= now()))
           OR (status = 'running'  AND leased_until IS NOT NULL AND leased_until < now()) );

    v_slots := c_max_lanes - v_inflight;

    IF v_slots > 0 AND v_sync_claim > 0 THEN
      FOR i IN 1..LEAST(v_slots, v_sync_claim) LOOP
        PERFORM public.bike_sync_invoke(r.id, 'sync'); v_fired := v_fired + 1;
      END LOOP;

    ELSIF v_slots > 0 AND v_audit_claim > 0 THEN
      FOR i IN 1..LEAST(v_slots, v_audit_claim) LOOP
        PERFORM public.bike_sync_invoke(r.id, 'audit'); v_fired := v_fired + 1;
      END LOOP;

    ELSIF v_inflight = 0 AND v_sync_claim = 0 AND v_audit_claim = 0 THEN
      -- Truly idle: either sync drained but audit not seeded, or all done.
      IF NOT EXISTS (SELECT 1 FROM sync_units WHERE run_id = r.id AND branch = 'audit')
         AND NOT EXISTS (SELECT 1 FROM sync_units
                          WHERE run_id = r.id AND branch = 'sync'
                            AND status IN ('enqueued', 'running')) THEN
        PERFORM public.seed_audit_units(r.id);
        PERFORM public.bike_sync_invoke(r.id, 'audit'); v_fired := v_fired + 1;
      ELSE
        PERFORM public.finalize_sync_run(r.id);
      END IF;
    END IF;
  END LOOP;

  RETURN v_fired;
END;
$$;
COMMENT ON FUNCTION public.bike_sync_tick() IS 'pg_cron heartbeat: drives every running sync_run by firing up to MAX_LANES−inflight bike-sync workers, transitions sync→audit, and finalizes drained runs. Decouples liveness from any single edge isolate.';
GRANT EXECUTE ON FUNCTION public.bike_sync_tick() TO service_role;
