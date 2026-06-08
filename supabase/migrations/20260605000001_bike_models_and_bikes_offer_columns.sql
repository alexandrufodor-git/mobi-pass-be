-- BellaBike sync — Phase 1 (additive, zero blast radius).
--
-- Introduces the multi-dealer model: bike_models (shared parent facts) +
-- bikes-as-dealer-OFFER. Everything here is ADDITIVE — the live benefit /
-- contract path, bikes_with_my_pricing, the update_bike_benefit_status
-- trigger, and both pricing fns are UNTOUCHED. Model columns are DUPLICATED
-- on bikes (single merge RPC writes both → no drift); the view keeps reading
-- bikes. The model-join + dropping the duplicated columns is Phase 2
-- (mobile-gated), a separate later migration.
--
-- See the locked design in llm-agent-assist/plans/bella-bike-integration.md
-- (sections §4 + §4b).

-- ---------------------------------------------------------------------------
-- 1. bike_models — shared model facts (parent grain).
--    Phase-1 identity = (dealer_id, external_parent_sku): each BellaBike
--    configurable parent (and each standalone simple, wrapped as a singleton)
--    is one model. mpn / ean are stored + indexed as the dealer-#2
--    cross-dealer match seam (matching itself is deferred — too sparse to key
--    on now). `type` + `in_catalog` live HERE (model grain).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "public"."bike_models" (
    "id"                  uuid DEFAULT gen_random_uuid() NOT NULL,
    "dealer_id"           uuid NOT NULL,
    "external_parent_sku" text NOT NULL,
    "mpn"                 text,
    "ean"                 text,
    "brand"               text,
    "name"                text NOT NULL,
    "type"                "public"."bike_type",
    "description"         text,
    "images"              jsonb,
    "raw_specs"           jsonb,
    "in_catalog"          boolean,
    "created_at"          timestamp with time zone DEFAULT now() NOT NULL,
    "updated_at"          timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT "bike_models_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "bike_models_dealer_parent_sku_key" UNIQUE ("dealer_id", "external_parent_sku"),
    CONSTRAINT "bike_models_dealer_id_fkey" FOREIGN KEY ("dealer_id")
        REFERENCES "public"."dealers"("id")
);

ALTER TABLE "public"."bike_models" OWNER TO "postgres";

COMMENT ON TABLE  "public"."bike_models" IS 'Shared model facts (parent grain). One row per dealer configurable-parent listing (or standalone-simple singleton). bikes = the per-dealer OFFER under a model. type + in_catalog live here. Phase 1: model columns are duplicated onto bikes and written by the single merge RPC; the join into the catalog view is Phase 2.';
COMMENT ON COLUMN "public"."bike_models"."external_parent_sku" IS 'Vendor parent SKU (BellaBike configurable parent, or the simple''s own SKU for singletons; legacy Maros rows use "legacy:<bike_id>"). Phase-1 merge key with dealer_id.';
COMMENT ON COLUMN "public"."bike_models"."mpn" IS 'Manufacturer part number — stored + indexed as the future cross-dealer model-match seam (matching deferred).';
COMMENT ON COLUMN "public"."bike_models"."ean" IS 'EAN/barcode — stored + indexed as the future cross-dealer model-match seam (matching deferred).';
COMMENT ON COLUMN "public"."bike_models"."in_catalog" IS 'Storefront catalog membership (GraphQL presence). NULL = pending audit. Has no DB proxy — only the storefront knows it. Publish rule (Phase 2): show iff in_catalog = true.';

CREATE INDEX "idx_bike_models_dealer" ON "public"."bike_models" USING btree ("dealer_id");
CREATE INDEX "idx_bike_models_mpn"    ON "public"."bike_models" USING btree ("mpn") WHERE "mpn" IS NOT NULL;
CREATE INDEX "idx_bike_models_ean"    ON "public"."bike_models" USING btree ("ean") WHERE "ean" IS NOT NULL;

CREATE OR REPLACE TRIGGER "update_bike_models_updated_at"
    BEFORE UPDATE ON "public"."bike_models"
    FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();

-- RLS: forward-compat for the Phase-2 catalog view join. Clients don't read
-- bike_models in Phase 1; the sync writes via service_role (bypasses RLS).
ALTER TABLE "public"."bike_models" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "bike_models_authenticated_select" ON "public"."bike_models"
    FOR SELECT TO "authenticated" USING (true);

GRANT ALL ON TABLE "public"."bike_models" TO "anon";
GRANT ALL ON TABLE "public"."bike_models" TO "authenticated";
GRANT ALL ON TABLE "public"."bike_models" TO "service_role";

-- ---------------------------------------------------------------------------
-- 2. bikes = dealer OFFER. Add the model FK + provenance / lifecycle /
--    pricing / raw_specs columns. Offer-grain price + stock; model facts are
--    duplicated here in Phase 1 (already true for name/brand/description/
--    images/type; in_catalog + raw_specs added now).
-- ---------------------------------------------------------------------------
ALTER TABLE "public"."bikes"
    ADD COLUMN IF NOT EXISTS "model_id"         uuid,
    ADD COLUMN IF NOT EXISTS "source"           text,
    ADD COLUMN IF NOT EXISTS "in_catalog"       boolean,
    ADD COLUMN IF NOT EXISTS "active"           boolean DEFAULT true NOT NULL,
    ADD COLUMN IF NOT EXISTS "delisted_at"      timestamp with time zone,
    ADD COLUMN IF NOT EXISTS "first_seen_at"    timestamp with time zone,
    ADD COLUMN IF NOT EXISTS "last_seen_at"     timestamp with time zone,
    ADD COLUMN IF NOT EXISTS "last_in_stock_at" timestamp with time zone,
    ADD COLUMN IF NOT EXISTS "list_price"       numeric(10,2),
    ADD COLUMN IF NOT EXISTS "special_price"    numeric(10,2),
    ADD COLUMN IF NOT EXISTS "special_from"     timestamp with time zone,
    ADD COLUMN IF NOT EXISTS "special_to"       timestamp with time zone,
    ADD COLUMN IF NOT EXISTS "raw_specs"        jsonb;

COMMENT ON COLUMN "public"."bikes"."model_id"      IS 'Parent bike_models row (ON DELETE RESTRICT). The selectable/orderable unit stays bikes.';
COMMENT ON COLUMN "public"."bikes"."source"        IS 'Provenance vendor key (e.g. ''bellabike''). NULL for legacy Maros rows.';
COMMENT ON COLUMN "public"."bikes"."in_catalog"    IS 'Storefront membership propagated from the parent model by the audit branch. NULL = pending. Publish gating itself stays Phase 2.';
COMMENT ON COLUMN "public"."bikes"."full_price"    IS 'Effective price = LEAST(list_price, special_price when in window). UNCHANGED benefit basis — both pricing fns key off this.';
COMMENT ON COLUMN "public"."bikes"."list_price"    IS 'Vendor list (regular) price.';
COMMENT ON COLUMN "public"."bikes"."special_price" IS 'Vendor promo price; effective only inside [special_from, special_to].';
COMMENT ON COLUMN "public"."bikes"."last_in_stock_at" IS 'Last time this offer was seen in stock (is-product-salable/2 = true). Powers back-in-stock detection.';
COMMENT ON COLUMN "public"."bikes"."raw_specs"     IS 'Decoded vendor option attributes (jsonb). Marketing prose + component table stay in description (HTML, no parser).';

-- Merge key for the sync upsert. Legacy rows keep NULL/distinct skus — NULLs
-- are distinct under a UNIQUE constraint, so this is non-breaking.
ALTER TABLE "public"."bikes"
    ADD CONSTRAINT "bikes_dealer_id_sku_key" UNIQUE ("dealer_id", "sku");

ALTER TABLE "public"."bikes"
    ADD CONSTRAINT "bikes_model_id_fkey" FOREIGN KEY ("model_id")
        REFERENCES "public"."bike_models"("id") ON DELETE RESTRICT;

CREATE INDEX "idx_bikes_model_id" ON "public"."bikes" USING btree ("model_id");
CREATE INDEX "idx_bikes_source"   ON "public"."bikes" USING btree ("source");

-- ---------------------------------------------------------------------------
-- 3. Backfill: wrap each existing (Maros) bikes row in its own singleton
--    model. NEVER delete — live FKs (bike_benefits, bike_orders) reference
--    these rows. external_parent_sku = "legacy:<bike_id>" guarantees
--    uniqueness regardless of duplicate/NULL skus.
-- ---------------------------------------------------------------------------
WITH ins AS (
    INSERT INTO "public"."bike_models"
        ("dealer_id", "external_parent_sku", "name", "brand", "type", "description", "images")
    SELECT "dealer_id", 'legacy:' || "id"::text, "name", "brand", "type", "description", "images"
    FROM "public"."bikes"
    WHERE "model_id" IS NULL
    RETURNING "id", "external_parent_sku"
)
UPDATE "public"."bikes" b
SET "model_id"      = ins."id",
    "source"        = COALESCE(b."source", 'maros'),
    "first_seen_at" = COALESCE(b."first_seen_at", b."created_at"),
    "last_seen_at"  = COALESCE(b."last_seen_at",  b."updated_at")
FROM ins
WHERE ins."external_parent_sku" = 'legacy:' || b."id"::text;

-- NOTE: model_id is left NULLABLE on purpose (Phase 1 = zero blast radius).
-- The sync always sets it and the backfill above covers every existing row,
-- but keeping it nullable means any other bikes INSERT path (e.g. an HR
-- "add bike" action) is not broken by this migration. The FK still enforces
-- referential integrity whenever model_id is set. Phase 2 may tighten it.
