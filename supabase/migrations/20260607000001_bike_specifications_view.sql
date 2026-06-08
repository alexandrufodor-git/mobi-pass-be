-- BellaBike sync — Phase 2a: surface a clean, dynamic Specifications list to
-- clients without breaking the existing General-details fields.
--
-- Design (agreed with the team):
--   • General details (top card: Weight / Charge time / Range / Power) stays on
--     the fixed curated columns — UNCHANGED. Legacy Maros bikes keep their
--     hand-entered values; synced BellaBike bikes fill Power (from
--     capacitate_baterie → power_wh) and show N/A for weight/charge/range,
--     which BellaBike simply does not publish as structured data.
--   • Specifications (bottom list) becomes data-driven. ONE database function,
--     public.specifications(bikes), builds a clean, English-labeled, ordered
--     `[{label,value}]` array so every client (mobile + web) renders identically
--     with no mapping code — the single source of truth.
--
-- Separation logic lives in that function: each row prefers the decoded vendor
-- attribute in raw_specs (synced bikes) and falls back to the curated column
-- (legacy bikes) — so the SAME function serves both kinds of bike. Rows with no
-- value are dropped. Keys already shown elsewhere (capacitate_baterie → Power;
-- manufacturer/producatori → brand) and the internal disponibilitate_stocuri
-- are intentionally excluded.
--
-- Exposed two ways from that one function, no duplicated logic:
--   • bikes_with_my_pricing.specifications  → the catalog path (the view).
--   • PostgREST computed column on bikes    → the YourEBike path, which embeds
--     the table: bike_benefits?select=*,bike:bikes(*,specifications,...).
-- Because the function takes a `bikes` row, PostgREST automatically publishes it
-- as a selectable computed column — the SAME object the view calls.
--
-- Additive: adds one function + one view column. No column drops, no writer
-- changes. The HTML `description` is NOT parsed (vendor weight/range live there
-- sparsely as free-form prose — out of scope by design).

-- ---------------------------------------------------------------------------
-- 1. specifications(bikes) — the single source of truth for the dynamic
--    Specifications list AND the PostgREST computed column on bikes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."specifications"("b" "public"."bikes")
    RETURNS jsonb
    LANGUAGE sql
    STABLE
    AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('label', s.label, 'value', s.value)
      ORDER BY s.ord
    ) FILTER (WHERE NULLIF(btrim(s.value), '') IS NOT NULL),
    '[]'::jsonb
  )
  FROM (VALUES
    ( 1, 'Supported features', b.supported_features),
    ( 2, 'Motor',           COALESCE(b.raw_specs ->> 'motorizare',   b.engine)),
    ( 3, 'Motor power',     b.raw_specs ->> 'putere_motor'),
    ( 4, 'Gears',           b.raw_specs ->> 'numar_viteze'),
    ( 5, 'Brakes',          b.raw_specs ->> 'tip_franare'),
    ( 6, 'Frame material',  COALESCE(b.raw_specs ->> 'material',      b.frame_material)),
    ( 7, 'Frame size',      COALESCE(b.raw_specs ->> 'marime',        b.frame_size)),
    ( 8, 'Wheel size',      COALESCE(b.raw_specs ->> 'marime_roata',  b.wheel_size)),
    ( 9, 'Wheel bandwidth', b.wheel_bandwidth),
    (10, 'Category',        b.raw_specs ->> 'gen'),
    (11, 'Color',           b.raw_specs ->> 'color'),
    (12, 'Lock',            b.lock_type)
  ) AS s(ord, label, value);
$$;

ALTER FUNCTION "public"."specifications"("b" "public"."bikes") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."specifications"("b" "public"."bikes") IS
  'Single source of truth for the dynamic Specifications [{label,value}] list. Prefers decoded vendor attributes in raw_specs (synced bikes), falls back to curated columns (legacy bikes); drops empty rows. Excludes keys shown elsewhere (battery→Power, brand) and the internal stock key. Used by the bikes_with_my_pricing view AND exposed by PostgREST as a computed column on bikes (select it explicitly — not included by select=*).';

GRANT ALL ON FUNCTION "public"."specifications"("b" "public"."bikes") TO "anon";
GRANT ALL ON FUNCTION "public"."specifications"("b" "public"."bikes") TO "authenticated";
GRANT ALL ON FUNCTION "public"."specifications"("b" "public"."bikes") TO "service_role";

-- ---------------------------------------------------------------------------
-- 2. bikes_with_my_pricing — add the `specifications` column (appended last:
--    CREATE OR REPLACE VIEW only permits new columns at the end). Everything
--    else is byte-for-byte the existing view (General-details columns untouched).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW "public"."bikes_with_my_pricing" WITH ("security_invoker"='on') AS
 SELECT "b"."id",
    "b"."name",
    "b"."created_at",
    "b"."updated_at",
    "b"."brand",
    "b"."description",
    "b"."image_url",
    "b"."full_price",
    "b"."employee_price",
    "b"."weight_kg",
    "b"."charge_time_hours",
    "b"."range_max_km",
    "b"."power_wh",
    "b"."engine",
    "b"."supported_features",
    "b"."frame_material",
    "b"."frame_size",
    "b"."wheel_size",
    "b"."wheel_bandwidth",
    "b"."lock_type",
    "b"."sku",
    "d"."name" AS "dealer_name",
    "d"."address" AS "dealer_address",
    "d"."lat" AS "dealer_lat",
    "d"."lon" AS "dealer_lon",
    "d"."phone" AS "dealer_phone",
    "b"."available_for_test",
    "b"."in_stock",
    "b"."type",
    "b"."images",
    "c"."monthly_benefit_subsidy",
    "c"."contract_months",
    "c"."contract_months" AS "employee_contract_month",
    "c"."currency",
    "prices"."employee_price" AS "employee_full_price",
    "prices"."monthly_employee_price" AS "employee_monthly_price",
    "public"."specifications"("b".*) AS "specifications"
   FROM (((("public"."bikes" "b"
     JOIN "public"."dealers" "d" ON (("d"."id" = "b"."dealer_id")))
     LEFT JOIN "public"."profiles" "me" ON (("me"."user_id" = "auth"."uid"())))
     LEFT JOIN "public"."companies" "c" ON (("c"."id" = "me"."company_id")))
     LEFT JOIN LATERAL "public"."calc_employee_prices"("b"."full_price", "c"."monthly_benefit_subsidy", "c"."contract_months") "prices"("employee_price", "monthly_employee_price") ON (true));

ALTER VIEW "public"."bikes_with_my_pricing" OWNER TO "postgres";

COMMENT ON VIEW "public"."bikes_with_my_pricing" IS 'Bike catalog with employee-specific pricing and dealer info. Uses auth.uid() to resolve the calling user''s company subsidy and contract terms automatically. Returns all bikes; pricing columns are NULL when the user has no linked company. `specifications` is the dynamic [{label,value}] spec list (public.specifications); General-details columns (weight_kg/charge_time_hours/range_max_km/power_wh) stay separate.';
