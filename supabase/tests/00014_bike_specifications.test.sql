SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: public.specifications(bikes) + bikes_with_my_pricing.specifications
-- The dynamic Specifications list (BellaBike sync Phase 2a). Verifies:
--   • synced bikes render the decoded vendor attributes from raw_specs,
--   • legacy bikes (raw_specs NULL) fall back to curated columns,
--   • raw_specs is PREFERRED over the column where both exist (COALESCE),
--   • empty/whitespace values are dropped,
--   • keys shown elsewhere (battery→Power, brand) + the internal stock key
--     are excluded,
--   • ordering is deterministic,
--   • the view surfaces the column for both kinds of bike.
--
-- Function-level cases build a transient bikes row with jsonb_populate_record
-- (only the fields under test are set; everything else is NULL).
-- ============================================================

BEGIN;

SELECT plan(9);

-- ── T01: synced bike — full ordered list from raw_specs ──────
-- capacitate_baterie / manufacturer / producatori / disponibilitate_stocuri
-- are present in the input but must NOT appear in the output.
SELECT is(
  public.specifications(jsonb_populate_record(NULL::public.bikes, '{
    "raw_specs":{"motorizare":"Bosch CX","putere_motor":"85 Nm","numar_viteze":"12",
      "tip_franare":"Disc - Hidraulica","material":"Aluminiu","marime":"L",
      "marime_roata":"29 inch","gen":"Barbati","color":"Negru",
      "capacitate_baterie":"625 Wh","manufacturer":"Trek",
      "producatori":"Bikefun","disponibilitate_stocuri":"Stock Furnizor"}}'::jsonb)),
  '[{"label":"Motor","value":"Bosch CX"},
    {"label":"Motor power","value":"85 Nm"},
    {"label":"Gears","value":"12"},
    {"label":"Brakes","value":"Disc - Hidraulica"},
    {"label":"Frame material","value":"Aluminiu"},
    {"label":"Frame size","value":"L"},
    {"label":"Wheel size","value":"29 inch"},
    {"label":"Category","value":"Barbati"},
    {"label":"Color","value":"Negru"}]'::jsonb,
  'T01: synced bike builds ordered specs from raw_specs'
);

-- ── T02: excluded keys really are excluded (exactly 9 rows above) ──
SELECT is(
  jsonb_array_length(public.specifications(jsonb_populate_record(NULL::public.bikes, '{
    "raw_specs":{"motorizare":"Bosch CX","putere_motor":"85 Nm","numar_viteze":"12",
      "tip_franare":"Disc - Hidraulica","material":"Aluminiu","marime":"L",
      "marime_roata":"29 inch","gen":"Barbati","color":"Negru",
      "capacitate_baterie":"625 Wh","manufacturer":"Trek",
      "producatori":"Bikefun","disponibilitate_stocuri":"Stock Furnizor"}}'::jsonb))),
  9,
  'T02: battery/brand/stock keys are excluded (9 rows, not 13)'
);

-- ── T03: legacy bike — falls back to curated columns ─────────
SELECT is(
  public.specifications(jsonb_populate_record(NULL::public.bikes, '{
    "engine":"Bosch Performance CX","supported_features":"Eco, Tour, eMTB, Turbo",
    "frame_material":"Aluminium Superlite","frame_size":"M (18\")",
    "wheel_size":"29 inches","wheel_bandwidth":"30mm",
    "lock_type":"Frame lock compatible"}'::jsonb)),
  '[{"label":"Supported features","value":"Eco, Tour, eMTB, Turbo"},
    {"label":"Motor","value":"Bosch Performance CX"},
    {"label":"Frame material","value":"Aluminium Superlite"},
    {"label":"Frame size","value":"M (18\")"},
    {"label":"Wheel size","value":"29 inches"},
    {"label":"Wheel bandwidth","value":"30mm"},
    {"label":"Lock","value":"Frame lock compatible"}]'::jsonb,
  'T03: legacy bike (raw_specs NULL) builds specs from curated columns'
);

-- ── T04: raw_specs is PREFERRED over the column where both exist ──
SELECT is(
  public.specifications(jsonb_populate_record(NULL::public.bikes, '{
    "raw_specs":{"motorizare":"MotorRaw","material":"MaterialRaw","marime":"SizeRaw",
      "marime_roata":"WheelRaw"},
    "engine":"EngineCol","frame_material":"MaterialCol","frame_size":"SizeCol",
    "wheel_size":"WheelCol"}'::jsonb)),
  '[{"label":"Motor","value":"MotorRaw"},
    {"label":"Frame material","value":"MaterialRaw"},
    {"label":"Frame size","value":"SizeRaw"},
    {"label":"Wheel size","value":"WheelRaw"}]'::jsonb,
  'T04: raw_specs value wins over the curated column (COALESCE order)'
);

-- ── T05: empty / whitespace-only values are dropped ──────────
SELECT is(
  public.specifications(jsonb_populate_record(NULL::public.bikes, '{
    "raw_specs":{"motorizare":"","numar_viteze":"   ","color":"Red"},
    "supported_features":""}'::jsonb)),
  '[{"label":"Color","value":"Red"}]'::jsonb,
  'T05: empty and whitespace-only values are filtered out'
);

-- ── T06: all NULL → empty array (not NULL) ───────────────────
SELECT is(
  public.specifications(jsonb_populate_record(NULL::public.bikes, '{}'::jsonb)),
  '[]'::jsonb,
  'T06: NULL raw_specs + all-NULL columns → []'
);

-- ── T07: empty raw_specs object + NULL columns → empty array ──
SELECT is(
  public.specifications(jsonb_populate_record(NULL::public.bikes, '{"raw_specs":{}}'::jsonb)),
  '[]'::jsonb,
  'T07: {} raw_specs + NULL columns → []'
);

-- ── View wiring ──────────────────────────────────────────────
-- Insert one dealer + a synced bike (raw_specs) and a legacy bike (columns),
-- then read the specifications column back through bikes_with_my_pricing.
CREATE TEMP TABLE _fix14 (synced_id UUID, legacy_id UUID) ON COMMIT DROP;

DO $$
DECLARE
  v_dl UUID;
  v_syn UUID;
  v_leg UUID;
BEGIN
  INSERT INTO public.dealers (name) VALUES ('Test Dealer 00014') RETURNING id INTO v_dl;

  INSERT INTO public.bikes (name, full_price, dealer_id, raw_specs)
  VALUES ('pgTAP Synced 00014', 5000.00, v_dl,
          '{"motorizare":"Shimano","numar_viteze":"10","color":"Albastru"}'::jsonb)
  RETURNING id INTO v_syn;

  INSERT INTO public.bikes (name, full_price, dealer_id, engine, supported_features, lock_type)
  VALUES ('pgTAP Legacy 00014', 5000.00, v_dl, 'Yamaha', 'Eco, Sport', 'Ring lock')
  RETURNING id INTO v_leg;

  INSERT INTO _fix14 VALUES (v_syn, v_leg);
END;
$$;

-- ── T08: view surfaces dynamic specs for a synced bike ───────
SELECT is(
  (SELECT specifications FROM public.bikes_with_my_pricing
   WHERE id = (SELECT synced_id FROM _fix14)),
  '[{"label":"Motor","value":"Shimano"},
    {"label":"Gears","value":"10"},
    {"label":"Color","value":"Albastru"}]'::jsonb,
  'T08: bikes_with_my_pricing.specifications built from raw_specs'
);

-- ── T09: view surfaces curated-column specs for a legacy bike ─
SELECT is(
  (SELECT specifications FROM public.bikes_with_my_pricing
   WHERE id = (SELECT legacy_id FROM _fix14)),
  '[{"label":"Supported features","value":"Eco, Sport"},
    {"label":"Motor","value":"Yamaha"},
    {"label":"Lock","value":"Ring lock"}]'::jsonb,
  'T09: bikes_with_my_pricing.specifications falls back to columns'
);

SELECT * FROM finish();
ROLLBACK;
