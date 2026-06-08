-- BellaBike sync — server-side RPCs.
--
-- Single writer + queue mechanics, mirroring the reges/csv "edge prepares,
-- one DB call commits" precedent. All SECURITY DEFINER, granted to
-- service_role (the bike-sync edge fn's identity).
--
--   merge_bike_offers     — the ONE writer: upserts bike_models (parent) AND
--                           bikes (offer) in one pass, so the duplicated model
--                           columns can never drift.
--   claim_next_sync_unit  — FOR UPDATE SKIP LOCKED queue pop.
--   complete_sync_unit    — terminal record OR re-enqueue with backoff (3x).
--   finalize_sync_run     — roll unit tallies → run status.
--   seed_audit_units      — enqueue the post-sync AUDIT branch.
--   set_models_in_catalog — audit membership setter (+ propagate to offers).
--   sweep_delisted_offers — weekly soft-delete of rows not seen this run.

-- ---------------------------------------------------------------------------
-- merge_bike_offers — single writer for parent models + dealer offers.
-- Payload: jsonb array of model objects, each with a nested `offers` array.
-- Offer rows inherit the duplicated model columns (name/brand/description/
-- images/type) straight from the parent object here, so the edge fn never
-- duplicates them. in_catalog is intentionally NOT touched (audit owns it).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.merge_bike_offers(
  p_dealer_id uuid,
  p_models    jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  m           jsonb;
  o           jsonb;
  v_model_id  uuid;
  v_offer_ins boolean;
  n_models    integer := 0;
  n_inserted  integer := 0;
  n_updated   integer := 0;
  n_offers    integer := 0;
BEGIN
  FOR m IN SELECT * FROM jsonb_array_elements(p_models)
  LOOP
    INSERT INTO bike_models (
      dealer_id, external_parent_sku, mpn, ean, brand, name, type,
      description, images, raw_specs
    ) VALUES (
      p_dealer_id,
      m->>'external_parent_sku',
      m->>'mpn', m->>'ean', m->>'brand', m->>'name',
      NULLIF(m->>'type', '')::bike_type,
      m->>'description',
      m->'images',
      m->'raw_specs'
    )
    ON CONFLICT (dealer_id, external_parent_sku) DO UPDATE SET
      mpn         = EXCLUDED.mpn,
      ean         = EXCLUDED.ean,
      brand       = EXCLUDED.brand,
      name        = EXCLUDED.name,
      type        = EXCLUDED.type,
      description = EXCLUDED.description,
      images      = EXCLUDED.images,
      raw_specs   = EXCLUDED.raw_specs
      -- in_catalog deliberately preserved — set by the audit branch.
    RETURNING id INTO v_model_id;
    n_models := n_models + 1;

    FOR o IN SELECT * FROM jsonb_array_elements(COALESCE(m->'offers', '[]'::jsonb))
    LOOP
      INSERT INTO bikes (
        name, brand, description, image_url, images, type,
        full_price, list_price, special_price, special_from, special_to,
        in_stock, frame_size, wheel_size, frame_material, power_wh, engine,
        available_for_test, sku, dealer_id, model_id, source, raw_specs,
        active, first_seen_at, last_seen_at, last_in_stock_at
      ) VALUES (
        m->>'name', m->>'brand', m->>'description',
        m->'images'->>0, m->'images', NULLIF(m->>'type', '')::bike_type,
        COALESCE((o->>'full_price')::numeric, 0),
        (o->>'list_price')::numeric,
        (o->>'special_price')::numeric,
        (o->>'special_from')::timestamptz,
        (o->>'special_to')::timestamptz,
        COALESCE((o->>'in_stock')::boolean, false),
        o->>'frame_size', o->>'wheel_size', o->>'frame_material',
        (o->>'power_wh')::integer, o->>'engine',
        COALESCE((o->>'available_for_test')::boolean, true),
        o->>'sku', p_dealer_id, v_model_id,
        COALESCE(o->>'source', 'bellabike'),
        o->'raw_specs',
        true, now(), now(),
        CASE WHEN COALESCE((o->>'in_stock')::boolean, false) THEN now() ELSE NULL END
      )
      ON CONFLICT (dealer_id, sku) DO UPDATE SET
        name               = EXCLUDED.name,
        brand              = EXCLUDED.brand,
        description        = EXCLUDED.description,
        image_url          = EXCLUDED.image_url,
        images             = EXCLUDED.images,
        type               = EXCLUDED.type,
        full_price         = EXCLUDED.full_price,
        list_price         = EXCLUDED.list_price,
        special_price      = EXCLUDED.special_price,
        special_from       = EXCLUDED.special_from,
        special_to         = EXCLUDED.special_to,
        in_stock           = EXCLUDED.in_stock,
        frame_size         = EXCLUDED.frame_size,
        wheel_size         = EXCLUDED.wheel_size,
        frame_material     = EXCLUDED.frame_material,
        power_wh           = EXCLUDED.power_wh,
        engine             = EXCLUDED.engine,
        available_for_test = EXCLUDED.available_for_test,
        model_id           = EXCLUDED.model_id,
        source             = EXCLUDED.source,
        raw_specs          = EXCLUDED.raw_specs,
        active             = true,
        delisted_at        = NULL,
        last_seen_at       = now(),
        last_in_stock_at   = CASE WHEN EXCLUDED.in_stock THEN now()
                                  ELSE bikes.last_in_stock_at END
      -- xmax = 0 on an INSERTed tuple, nonzero on the ON CONFLICT UPDATE path.
      -- Cast via text to dodge the missing xid=int operator.
      RETURNING (xmax::text::bigint = 0) INTO v_offer_ins;

      IF v_offer_ins THEN n_inserted := n_inserted + 1;
      ELSE                n_updated  := n_updated  + 1;
      END IF;
      n_offers := n_offers + 1;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'n_models_upserted', n_models,
    'n_inserted',        n_inserted,
    'n_updated',         n_updated,
    'n_offers',          n_offers
  );
END;
$$;
COMMENT ON FUNCTION public.merge_bike_offers(uuid, jsonb) IS 'Single writer: upserts bike_models (parent, by dealer_id+external_parent_sku) and bikes (offer, by dealer_id+sku) in one pass. Duplicated model columns are copied onto each offer here. in_catalog preserved (audit-owned).';
GRANT EXECUTE ON FUNCTION public.merge_bike_offers(uuid, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- claim_next_sync_unit — atomically pop the next enqueued unit for a branch.
-- Returns NULL when the branch is drained (used by the edge fn to transition).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_next_sync_unit(
  p_run_id uuid,
  p_branch text
) RETURNS public.sync_units
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_unit public.sync_units;
BEGIN
  UPDATE sync_units SET
    status     = 'running',
    attempts   = attempts + 1,
    started_at = COALESCE(started_at, now())
  WHERE id = (
    SELECT id FROM sync_units
    WHERE run_id = p_run_id
      AND branch = p_branch
      AND status = 'enqueued'
      AND (next_retry_at IS NULL OR next_retry_at <= now())
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
GRANT EXECUTE ON FUNCTION public.claim_next_sync_unit(uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- complete_sync_unit — terminal record (+ roll into run) OR re-enqueue with
-- backoff while attempts remain. Returns 'retry' | 'succeeded' | 'failed' |
-- 'skipped'.
-- ---------------------------------------------------------------------------
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

  -- Transient failure with retries left → re-enqueue with linear backoff.
  -- No run rollup yet (it'll be counted on the terminal attempt).
  IF p_status = 'failed' AND v_attempts < 3 THEN
    UPDATE sync_units SET
      status        = 'enqueued',
      next_retry_at = now() + (v_attempts * interval '20 seconds'),
      error         = p_error
    WHERE id = p_unit_id;
    RETURN 'retry';
  END IF;

  UPDATE sync_units SET
    status            = p_status,
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

-- ---------------------------------------------------------------------------
-- finalize_sync_run — set run status from unit tallies. No-op (stays running)
-- if any unit is still enqueued/running.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.finalize_sync_run(p_run_id uuid)
RETURNS public.sync_runs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_succeeded integer;
  v_failed    integer;
  v_pending   integer;
  v_status    text;
  v_run       public.sync_runs;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'succeeded'),
         count(*) FILTER (WHERE status = 'failed'),
         count(*) FILTER (WHERE status IN ('enqueued', 'running'))
    INTO v_succeeded, v_failed, v_pending
    FROM sync_units WHERE run_id = p_run_id;

  IF v_pending > 0 THEN
    SELECT * INTO v_run FROM sync_runs WHERE id = p_run_id;
    RETURN v_run;
  END IF;

  IF    v_failed = 0    THEN v_status := 'succeeded';
  ELSIF v_succeeded = 0 THEN v_status := 'failed';
  ELSE                       v_status := 'partial';
  END IF;

  UPDATE sync_runs SET status = v_status, finished_at = now()
  WHERE id = p_run_id
  RETURNING * INTO v_run;
  RETURN v_run;
END;
$$;
GRANT EXECUTE ON FUNCTION public.finalize_sync_run(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- seed_audit_units — enqueue the AUDIT branch (membership + reconcile).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.seed_audit_units(p_run_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO sync_units (run_id, branch, kind) VALUES
    (p_run_id, 'audit', 'gql_membership'),
    (p_run_id, 'audit', 'verify');
END;
$$;
GRANT EXECUTE ON FUNCTION public.seed_audit_units(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- set_models_in_catalog — audit membership setter. The edge fn does the public
-- GraphQL presence pass and hands back the present + checked parent-sku sets;
-- this flips bike_models.in_catalog and propagates it down to the offers.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_models_in_catalog(
  p_dealer_id           uuid,
  p_present_parent_skus text[],
  p_checked_parent_skus text[]
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  n_true  integer;
  n_false integer;
BEGIN
  UPDATE bike_models SET in_catalog = true
   WHERE dealer_id = p_dealer_id
     AND external_parent_sku = ANY (p_present_parent_skus);
  GET DIAGNOSTICS n_true = ROW_COUNT;

  UPDATE bike_models SET in_catalog = false
   WHERE dealer_id = p_dealer_id
     AND external_parent_sku = ANY (p_checked_parent_skus)
     AND NOT (external_parent_sku = ANY (p_present_parent_skus));
  GET DIAGNOSTICS n_false = ROW_COUNT;

  UPDATE bikes b SET in_catalog = m.in_catalog
    FROM bike_models m
   WHERE b.model_id = m.id
     AND m.dealer_id = p_dealer_id
     AND m.external_parent_sku = ANY (p_checked_parent_skus);

  RETURN jsonb_build_object('in_catalog_true', n_true, 'in_catalog_false', n_false);
END;
$$;
GRANT EXECUTE ON FUNCTION public.set_models_in_catalog(uuid, text[], text[]) TO service_role;

-- ---------------------------------------------------------------------------
-- sweep_delisted_offers — weekly soft-delete of offers not seen this run.
-- Never hard-deletes (preserves bike_benefits / bike_orders FKs + history).
-- Bumps the run's n_delisted.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sweep_delisted_offers(
  p_run_id     uuid,
  p_dealer_id  uuid,
  p_seen_after timestamptz
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
  UPDATE bikes SET
    active      = false,
    delisted_at = now(),
    in_stock    = false
   WHERE dealer_id = p_dealer_id
     AND source = 'bellabike'
     AND active
     AND (last_seen_at IS NULL OR last_seen_at < p_seen_after);
  GET DIAGNOSTICS n = ROW_COUNT;

  UPDATE sync_runs SET n_delisted = n_delisted + n WHERE id = p_run_id;
  RETURN n;
END;
$$;
GRANT EXECUTE ON FUNCTION public.sweep_delisted_offers(uuid, uuid, timestamptz) TO service_role;
