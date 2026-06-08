-- ============================================================================
-- bike-sync: safe delisting (replaces the false-delist-prone last_seen_at sweep)
-- ============================================================================
-- Incident (2026-06-07): the old sweep delisted every bike whose
-- `last_seen_at < run.started_at` — i.e. "anything the SYNC branch didn't
-- re-fetch this run." That infers absence from a FAILURE TO OBSERVE. A prod
-- Cloudflare 403 made the REST fetches fail, last_seen_at went stale for
-- ~everything, and the weekly sweep (which ran unconditionally) delisted 4031
-- bikes — a false positive.
--
-- Principle (architect-reviewed): the DB is SSOT. Retire a row only on a
-- POSITIVE, COMPLETE signal of absence — never on a failure to observe. Stock
-- and catalog-membership stay DECOUPLED (proven ~1.1% independent on
-- 2026-06-04). Out-of-stock is a reversible flag, never a delist.
--
-- Mechanism — a "missing streak" over COMPLETE membership passes:
--   * fetchMembership (edge fn) reports `complete=false` if ANY GraphQL batch
--     errored; an incomplete pass records NOTHING.
--   * record_membership_pass logs one complete pass + the parent SKUs absent in
--     it, into two append-only tables. The streak is DERIVED by SELECT over
--     these (never a mutable counter → safe under tick double-fire / re-claim).
--   * sweep_delisted_offers delists iff: (gate 1) this run's SYNC branch is
--     clean (0 failed / 0 unfinished), (gate 2) this run recorded a complete
--     membership pass, (gate 3) the parent has been absent across the last
--     N=2 complete passes. No %-cap (it'd block legit bulk changes); a WARNING
--     is raised on an unusually large sweep instead.
-- ============================================================================

-- ── 1. merge_bike_offers — in_stock must never be flipped by an UNKNOWN read ──
-- isSalable now returns boolean|null (null = couldn't check). On UPDATE, keep
-- the existing in_stock when the new reading is unknown, instead of forcing it
-- to false. (Same failure-to-observe disease, one layer down.) Only the two
-- in_stock-related lines of the ON CONFLICT clause change vs 20260605000003.
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
        -- INSERT: a brand-new offer with unknown stock defaults to false.
        COALESCE((o->>'in_stock')::boolean, false),
        o->>'frame_size', o->>'wheel_size', o->>'frame_material',
        (o->>'power_wh')::integer, o->>'engine',
        COALESCE((o->>'available_for_test')::boolean, true),
        o->>'sku', p_dealer_id, v_model_id,
        COALESCE(o->>'source', 'bellabike'),
        o->'raw_specs',
        true, now(), now(),
        CASE WHEN (o->>'in_stock')::boolean IS TRUE THEN now() ELSE NULL END
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
        -- UPDATE: unknown stock (null) keeps the existing flag — never forces
        -- false. `o` is in scope, so read the raw nullable value directly
        -- (EXCLUDED.in_stock has already been COALESCEd to false above).
        in_stock           = COALESCE((o->>'in_stock')::boolean, bikes.in_stock),
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
        -- only bump when we actually OBSERVED in-stock this run (null → keep).
        last_in_stock_at   = CASE WHEN (o->>'in_stock')::boolean IS TRUE THEN now()
                                  ELSE bikes.last_in_stock_at END
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
GRANT EXECUTE ON FUNCTION public.merge_bike_offers(uuid, jsonb) TO service_role;

-- ── 2. Observation log (append-only) — the streak SSOT ───────────────────────
CREATE TABLE IF NOT EXISTS public.bike_membership_passes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- `seq` is the strictly-monotonic recording order, used to pick "the last N
  -- passes". completed_at is informational only — never order on it (it defaults
  -- to transaction time, so passes recorded in the same txn would tie).
  seq          bigint GENERATED BY DEFAULT AS IDENTITY,
  run_id       uuid NOT NULL REFERENCES public.sync_runs(id) ON DELETE CASCADE,
  dealer_id    uuid NOT NULL,
  completed_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.bike_membership_passes IS 'One row per COMPLETE GraphQL membership pass (0 failed batches). The streak that drives delisting is derived by SELECT over this + bike_membership_absences (ordered by seq) — never a mutable counter.';
CREATE INDEX IF NOT EXISTS bike_membership_passes_dealer_seq_idx
  ON public.bike_membership_passes (dealer_id, seq DESC);
ALTER TABLE public.bike_membership_passes ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.bike_membership_absences (
  pass_id             uuid NOT NULL REFERENCES public.bike_membership_passes(id) ON DELETE CASCADE,
  external_parent_sku text NOT NULL,
  PRIMARY KEY (pass_id, external_parent_sku)
);
COMMENT ON TABLE public.bike_membership_absences IS 'Parent SKUs that were CHECKED-but-absent in a complete membership pass (i.e. confirmed not present in the storefront catalog).';
ALTER TABLE public.bike_membership_absences ENABLE ROW LEVEL SECURITY;
-- No policies: service_role (the only writer/reader, via the edge fn) bypasses
-- RLS; anon/authenticated get no access. Matches sync_run_cache.

-- ── 3. record_membership_pass — log a COMPLETE pass + its absences ───────────
-- Called by the edge fn ONLY when the pass is complete (every GraphQL batch
-- returned). Absent = checked-but-not-present.
CREATE OR REPLACE FUNCTION public.record_membership_pass(
  p_run_id              uuid,
  p_dealer_id           uuid,
  p_present_parent_skus text[],
  p_checked_parent_skus text[]
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_pass_id uuid;
BEGIN
  INSERT INTO bike_membership_passes (run_id, dealer_id)
  VALUES (p_run_id, p_dealer_id)
  RETURNING id INTO v_pass_id;

  INSERT INTO bike_membership_absences (pass_id, external_parent_sku)
  SELECT v_pass_id, s
  FROM unnest(p_checked_parent_skus) AS s
  WHERE s <> ALL (p_present_parent_skus);

  RETURN v_pass_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.record_membership_pass(uuid, uuid, text[], text[]) TO service_role;

-- ── 4. sync_branch_clean — gate 1 ───────────────────────────────────────────
-- True iff the run's SYNC branch did work AND every sync unit succeeded
-- (no failed, no enqueued/running). This is the gate the 2026-06-07 incident
-- lacked: a partial sync branch still "drains", but must NOT license a sweep.
CREATE OR REPLACE FUNCTION public.sync_branch_clean(p_run_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
           SELECT 1 FROM sync_units WHERE run_id = p_run_id AND branch = 'sync'
         )
     AND NOT EXISTS (
           SELECT 1 FROM sync_units
           WHERE run_id = p_run_id AND branch = 'sync'
             AND status IN ('enqueued', 'running', 'failed')
         );
$$;
GRANT EXECUTE ON FUNCTION public.sync_branch_clean(uuid) TO service_role;

-- ── 5. sweep_delisted_offers — gated, streak-based (REPLACES the old sweep) ───
-- Old signature (uuid, uuid, timestamptz) keyed on last_seen_at — dropped.
DROP FUNCTION IF EXISTS public.sweep_delisted_offers(uuid, uuid, timestamptz);

CREATE OR REPLACE FUNCTION public.sweep_delisted_offers(
  p_run_id    uuid,
  p_dealer_id uuid,
  p_streak    integer DEFAULT 2
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_passes integer;
  v_before integer;
  n        integer;
BEGIN
  -- Gate 1: this run's SYNC branch must be clean.
  IF NOT public.sync_branch_clean(p_run_id) THEN
    RAISE NOTICE '[bike-sync] sweep skipped: sync branch not clean (run %)', p_run_id;
    RETURN 0;
  END IF;

  -- Gate 2: this run must have recorded a COMPLETE membership pass.
  IF NOT EXISTS (
    SELECT 1 FROM bike_membership_passes
    WHERE run_id = p_run_id AND dealer_id = p_dealer_id
  ) THEN
    RAISE NOTICE '[bike-sync] sweep skipped: no complete membership pass (run %)', p_run_id;
    RETURN 0;
  END IF;

  -- Need at least N complete passes before a streak can exist.
  SELECT count(*) INTO v_passes FROM (
    SELECT id FROM bike_membership_passes
    WHERE dealer_id = p_dealer_id
    ORDER BY seq DESC
    LIMIT p_streak
  ) recent;
  IF v_passes < p_streak THEN
    RAISE NOTICE '[bike-sync] sweep skipped: only % complete pass(es), need %', v_passes, p_streak;
    RETURN 0;
  END IF;

  -- Gate 3: delist parents absent in ALL of the last N complete passes.
  -- (These ARE the most recent N, so "absent in all N" == absent for the last
  -- N consecutive complete passes.)
  WITH recent AS (
    SELECT id FROM bike_membership_passes
    WHERE dealer_id = p_dealer_id
    ORDER BY seq DESC
    LIMIT p_streak
  ),
  eligible AS (
    SELECT a.external_parent_sku
    FROM bike_membership_absences a
    JOIN recent r ON r.id = a.pass_id
    GROUP BY a.external_parent_sku
    HAVING count(*) = p_streak
  )
  UPDATE bikes b SET
    active      = false,
    delisted_at = now(),
    in_stock    = false
  FROM bike_models m
  WHERE b.model_id = m.id
    AND b.dealer_id = p_dealer_id
    AND b.source    = 'bellabike'
    AND b.active
    AND m.dealer_id = p_dealer_id
    AND m.external_parent_sku IN (SELECT external_parent_sku FROM eligible);
  GET DIAGNOSTICS n = ROW_COUNT;

  -- Defense-in-depth ALERT (not a block, per design): flag an oversized sweep.
  IF n > 0 THEN
    SELECT count(*) INTO v_before
    FROM bikes WHERE dealer_id = p_dealer_id AND source = 'bellabike';
    IF n > GREATEST(50, v_before / 5) THEN
      RAISE WARNING '[bike-sync] sweep delisted % of % bellabike offers (>20%%) — run %, review', n, v_before, p_run_id;
    END IF;
  END IF;

  UPDATE sync_runs SET n_delisted = n_delisted + n WHERE id = p_run_id;
  RETURN n;
END;
$$;
COMMENT ON FUNCTION public.sweep_delisted_offers(uuid, uuid, integer) IS 'Gated, streak-based soft-delete. Delists bellabike offers only when: the run sync branch is clean, this run recorded a complete membership pass, and the parent was absent across the last p_streak complete passes. Never hard-deletes; never delists on a failure to observe.';
GRANT EXECUTE ON FUNCTION public.sweep_delisted_offers(uuid, uuid, integer) TO service_role;
