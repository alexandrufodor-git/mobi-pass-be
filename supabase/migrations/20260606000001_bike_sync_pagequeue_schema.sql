-- BellaBike sync — page-queue redesign, part 1/3: schema.
--
-- WHY: the original "one unit = one whole leaf category" granularity made each
-- edge invocation do hundreds–thousands of sequential is-product-salable calls,
-- which blew the edge runtime wall-clock/CPU budget. The isolate was killed
-- mid-unit, the unit stayed status='running' forever (no lease), and the
-- self-firing chain died with it → silent permanent stall.
--
-- FIX (this migration = the schema for it):
--   • Units become small fixed-size SKU PAGES instead of whole categories.
--   • A `prepare` unit per category fetches the run-stable bits ONCE (attribute
--     option maps + the category's configurable parents), caches them, counts
--     the category, and fans out `rest_page` units.
--   • A LEASE (`leased_until`) makes death recoverable: a unit is re-claimable
--     once its lease expires, so a killed worker self-heals (the merge is
--     idempotent by (dealer_id,sku), so re-processing a page is safe).
--
-- Parts 2/3 (RPCs + cron tick) follow in the next two migrations.

-- ── sync_units: page identity + lease ───────────────────────────────────────
ALTER TABLE public.sync_units
  ADD COLUMN IF NOT EXISTS page         integer,
  ADD COLUMN IF NOT EXISTS page_size    integer,
  ADD COLUMN IF NOT EXISTS leased_until timestamptz;

-- New kinds: 'prepare' (per category, fans out pages) + 'rest_page' (the work).
-- Old kinds kept so historical rows + the audit branch stay valid.
ALTER TABLE public.sync_units DROP CONSTRAINT IF EXISTS sync_units_kind_check;
ALTER TABLE public.sync_units ADD  CONSTRAINT sync_units_kind_check
  CHECK (kind IN ('rest_category', 'prepare', 'rest_page', 'gql_membership', 'verify'));

-- Dedupe page enqueue: a prepare unit (or a re-run after a lease-recovered
-- prepare) can only ever create page N once per run/category.
CREATE UNIQUE INDEX IF NOT EXISTS uq_sync_units_page
  ON public.sync_units (run_id, branch, category_id, page)
  WHERE kind = 'rest_page';

-- Claimable lookup: enqueued OR lease-expired running, ordered by created_at.
CREATE INDEX IF NOT EXISTS idx_sync_units_claimable
  ON public.sync_units (run_id, branch, status, leased_until, created_at);

-- ── sync_run_cache: run-scoped fetch cache (option maps + parents) ───────────
-- scope = 'option_maps' (whole run) | 'parents:<category_id>' (per category).
-- Lets page workers avoid re-fetching the 14 attribute-option calls and the
-- category parent list on every page. Cascades away with the run.
CREATE TABLE IF NOT EXISTS public.sync_run_cache (
  run_id     uuid        NOT NULL REFERENCES public.sync_runs(id) ON DELETE CASCADE,
  scope      text        NOT NULL,
  payload    jsonb       NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, scope)
);

-- RLS on, no policies → only service_role (bypasses RLS) can touch it, matching
-- the rest of the sync_* internals. The bike-sync edge fn uses the service key.
ALTER TABLE public.sync_run_cache ENABLE ROW LEVEL SECURITY;
GRANT ALL ON TABLE public.sync_run_cache TO service_role;
