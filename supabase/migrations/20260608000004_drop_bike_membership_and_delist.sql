-- ============================================================================
-- bike-sync: remove catalog-membership (in_catalog) + streak-based delisting
-- ============================================================================
-- Decision (2026-06-08): the GraphQL "catalog membership" signal is WRONG.
-- A storefront audit checked the configurable parents that
-- products(filter:{sku:{in:[parentSku]}}) marks ABSENT and found 19 of 20 were
-- in fact LIVE and buyable on bellabike.ro (HTTP 200 — current 2025 Scott /
-- Raymon e-bikes). The query under-reports live *configurable* parents, so it
-- cannot drive in_catalog or delisting without retiring live listings.
--
-- Root cause: BellaBike's catalog is configurable — the parent is a price:0 /
-- salable_qty:0 shell; price + stock + buyability live on the CHILDREN. Every
-- parent-grain signal (GraphQL sku-filter, is-product-salable on the parent) is
-- blind to child stock and reads live listings as "gone." The only correct
-- grains are the REST /products sweep (catalog) and per-child is-salable (stock).
--
-- New, simpler architecture:
--   * Catalog membership = presence in the REST /products category sweep
--     (admin token). The sweep already returns every live parent — no GraphQL.
--   * Stock              = per-offer is-product-salable/{childSku}/2, stored as
--     bikes.in_stock by merge_bike_offers (UNCHANGED, incl. in_stock-on-unknown).
--   * No in_catalog, no membership pass, no streak, no auto-delist. A bike that
--     leaves the feed just lingers (active=true) until we add REST-sweep-based
--     delisting later — strictly better than wrongly deleting live bikes.
--
-- Nothing user-facing changes: bikes_with_my_pricing already returned all bikes
-- and never selected in_catalog. The bike-sync edge fn AUDIT branch is now a
-- no-op (see functions/bike-sync/index.ts). schema.sql is regenerated from prod
-- via `supabase db diff`, not hand-edited.
-- ============================================================================

-- 1. functions first (they reference the tables/columns dropped below)
DROP FUNCTION IF EXISTS public.set_models_in_catalog(uuid, text[], text[]);
DROP FUNCTION IF EXISTS public.sweep_delisted_offers(uuid, uuid, integer);
DROP FUNCTION IF EXISTS public.record_membership_pass(uuid, uuid, text[], text[]);
DROP FUNCTION IF EXISTS public.sync_branch_clean(uuid);

-- 2. the streak observation-log (absences FK → passes, so absences first)
DROP TABLE IF EXISTS public.bike_membership_absences;
DROP TABLE IF EXISTS public.bike_membership_passes;

-- 3. the untrusted membership flag — no consumer (the catalog view never read it)
ALTER TABLE public.bikes       DROP COLUMN IF EXISTS in_catalog;
ALTER TABLE public.bike_models DROP COLUMN IF EXISTS in_catalog;
