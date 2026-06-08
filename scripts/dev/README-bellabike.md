# BellaBike eBike sync — operator runbook

Read-only daily/weekly sync of BellaBike's electric bikes (price + stock + specs)
into our Supabase `bikes` catalog. BellaBike (Magento 2.4.7) is the source of
truth; we only ever GET. Full design + decision history:
`llm-agent-assist/plans/bella-bike-integration.md` (§ "LOCKED IMPLEMENTATION DESIGN").

## What got built

**Migrations** (`supabase/migrations/`):
- `20260605000001_bike_models_and_bikes_offer_columns.sql` — `bike_models`
  parent table; `bikes` offer/lifecycle/pricing/`raw_specs` columns + `model_id`
  FK; `UNIQUE(dealer_id, sku)`; Maros rows backfilled as singleton models.
- `20260605000002_sync_runs_and_units.sql` — audit/queue tables + `sync_run_summary`.
- `20260605000003_bike_sync_rpcs.sql` — `merge_bike_offers` (single writer),
  `claim_next_sync_unit`, `complete_sync_unit`, `finalize_sync_run`,
  `seed_audit_units`, `set_models_in_catalog`, `sweep_delisted_offers`.
- `20260605000004_enable_pg_cron_and_orchestration.sql` — `CREATE EXTENSION
  pg_cron`; `bike_sync_invoke` (pg_net + Vault), `bike_sync_kickoff`.
- `20260605000005_schedule_bike_sync_cron.sql` — **push LAST, after a green
  manual run.** Activates the nightly schedule.

**Edge fn** `supabase/functions/bike-sync/` (+ `_shared/bikeIngest.ts`) — the
self-draining worker. `verify_jwt=false`, gated by the Vault webhook secret.

## Tonight — runbook (locked design §8)

### 1. Save Vault secrets (prod SQL editor + local)
```sql
-- BellaBike Magento integration token (read-only eBike sync)
select vault.create_secret('<BB_INTEGRATION_TOKEN>', 'vendor_bela_access',
  'BellaBike Magento 2.4.7 integration token — read-only eBike sync');

-- Shared secret guarding the bike-sync edge fn (any long random string;
-- the same value is sent by bike_sync_invoke as the x-webhook-secret header)
select vault.create_secret('<RANDOM_SECRET>', 'bike_sync_webhook_secret',
  'Webhook secret gating the bike-sync edge function');
```

### 2. Push migrations 0001–0004 (NOT 0005 yet)
```bash
supabase db push          # applies through ...000004; leave ...000005 for step 6
supabase functions deploy bike-sync
```

### 3. Manual run — start with ONE category, then all
```sql
-- one leaf first (722 = e-MTB hardtail), watch it drain:
select public.bike_sync_kickoff('manual', array['722']);

-- inspect (re-run as it drains):
select * from sync_run_summary order by started_at desc limit 3;
select branch, kind, category_id, status, attempts,
       n_fetched, n_upserted, n_models_upserted, n_failed, error
  from sync_units where run_id = '<run_id>' order by branch, created_at;

-- once happy, the full catalog:
select public.bike_sync_kickoff('manual');   -- all 5 leaves
```
The run seeds the SYNC queue (one unit per leaf) and fires the first edge
invocation; each invocation drains one unit and re-fires itself. When the SYNC
branch empties it seeds + runs the AUDIT branch (GraphQL membership →
`in_catalog`; weekly-only soft-delete sweep), then `finalize_sync_run` sets the
run status.

### 4. Audit the run (our DB vs the storefront)
```bash
# token cmds run via `!` so the integration token stays out of Claude's env:
! BB_TOKEN='<BB_INTEGRATION_TOKEN>' python3 scripts/dev/bellabike.py raw
! BB_TOKEN='<BB_INTEGRATION_TOKEN>' python3 scripts/dev/bellabike.py audit <run_id>
```
`audit` prints the Supabase SQL to inspect what we wrote, then runs `verify`
(Magento `is-product-salable/2` vs storefront GraphQL membership over the whole
catalog) as the cross-check.

### 5. Go live — push the schedule
Once a manual run is green:
```bash
supabase db push          # applies ...000005 → pg_cron schedules activate
```
- Mon–Sat 02:00 UTC → `bike_sync_kickoff('daily')` (delta on `updated_at`).
- Sun 02:00 UTC → `bike_sync_kickoff('weekly')` (full reconcile + soft-delete sweep).

Pause later with `select cron.unschedule('bike-sync-daily');` /
`select cron.unschedule('bike-sync-weekly');`.

## Notes / gotchas

- **Publish gating is Phase 2.** Phase 1 is additive: `bikes_with_my_pricing`,
  the benefit/contract flow, the status trigger, and both pricing fns are
  frozen. The publish rule (*show iff `in_catalog AND status=1`*) lands when the
  view flips to the model-join and the duplicated columns drop (mobile-gated).
- **`full_price` stays effective** = `LEAST(list, special-in-window)` — benefit
  math is untouched. `list_price` / `special_price` / `special_from` /
  `special_to` are persisted alongside for the designer.
- **Never hard-delete.** Rows leaving the feed get `active=false` +
  `delisted_at` (weekly sweep); OOS rows stay with `in_stock=false`.
- **Watermark** for the next delta = `MAX(watermark_to) WHERE status='succeeded'`
  — a failed/partial run never advances it, so missed SKUs self-heal.
- **Field mapping** (`_shared/bikeIngest.ts`: `mapModel` / `mapOffer` /
  `bikeType` / `decodeSpecs`) is built from the documented Magento shape — eyeball
  it against the first run's `raw_specs` and adjust the brand source
  (`producatori` vs `manufacturer`) and the type-enum leaf map as needed.
