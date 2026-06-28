#!/usr/bin/env bash
# ============================================================================
# Backfill commute distances + seed the first correct company CO₂ stats.
# ============================================================================
#
# Why this exists:
#   The CO₂ engine derives employee_pii.commute_distance_km in the EDGE runtime
#   (that is the only place home coords are decrypted). The aggregation migration
#   (20260627000002) seeds company_co2_stats at deploy time — but that runs
#   BEFORE any distance exists, so every company's first week was written as 0.
#
#   This script invokes the recompute-commute-distances edge function, which:
#     1. decrypts each home coord, computes the distance, writes the scalar; then
#     2. chains refresh_company_co2_stats() for the current ISO week (the exact
#        SQL the Mon–Fri cron runs).
#   One call → distances backfilled AND the first CO₂ correct. The cron keeps it
#   fresh from there. Idempotent: safe to re-run (unchanged rows are skipped).
#
# No secrets in this file or the repo: like create-company.sh, the service-role
# key is fetched at runtime from the `supabase link` state (or `supabase status`
# for local), never hardcoded.
#
# Usage:
#   Dry run first (no writes — just counts what WOULD change):
#     DRY_RUN=true ./scripts/dev/backfill-co2.sh
#
#   Real run (all companies):
#     ./scripts/dev/backfill-co2.sh
#
#   Scope to one company (e.g. after an office move):
#     COMPANY_ID=44444444-4444-4444-4444-444444444444 ./scripts/dev/backfill-co2.sh
#
#   Local docker stack instead of the linked project:
#     TARGET=local ./scripts/dev/backfill-co2.sh
#
# Env vars (all optional):
#   TARGET        — linked (default) | local | prod
#                   linked → derives URL + key from supabase/.temp/project-ref
#                   local  → uses `supabase status`
#                   prod   → requires SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY
#   DRY_RUN       — "true" to compute counts without writing (default: false)
#   COMPANY_ID    — restrict to a single company (default: all companies)
#   BATCH_SIZE    — rows per page, 1–1000 (default: function default 200)
#   MIN_INTERVAL_MS — throttle between ORS routed calls; 0 to disable for
#                     self-hosted ORS (default: function default 1600)
#   AUTO_CONFIRM  — "true" to skip the linked/prod [y/N] prompt (CI use)
#
# Requires: curl, jq. For TARGET=local: a running `supabase start` stack.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET="${TARGET:-linked}"
DRY_RUN="${DRY_RUN:-false}"
COMPANY_ID="${COMPANY_ID:-}"
BATCH_SIZE="${BATCH_SIZE:-}"
MIN_INTERVAL_MS="${MIN_INTERVAL_MS:-}"

# ── Sanity checks ───────────────────────────────────────────────────────────

if ! command -v jq > /dev/null; then
  echo "✗ jq is required (brew install jq)" >&2; exit 1
fi
if ! command -v curl > /dev/null; then
  echo "✗ curl is required" >&2; exit 1
fi

# ── Resolve SUPABASE_URL + SERVICE_ROLE_KEY (no secrets stored) ──────────────

case "$TARGET" in
  local)
    if ! supabase status -o env > /dev/null 2>&1; then
      echo "✗ Supabase not running. Start it first: supabase start" >&2; exit 1
    fi
    eval "$(supabase status -o env 2>/dev/null)"
    SUPABASE_URL="${API_URL:-http://127.0.0.1:54321}"
    SUPABASE_SERVICE_ROLE_KEY="${SERVICE_ROLE_KEY:-}"
    if [[ -z "$SUPABASE_SERVICE_ROLE_KEY" ]]; then
      echo "✗ SERVICE_ROLE_KEY missing from supabase status output." >&2; exit 1
    fi
    ;;
  linked)
    PROJECT_REF_FILE="$(cd "$SCRIPT_DIR/../.." && pwd)/supabase/.temp/project-ref"
    if [[ ! -f "$PROJECT_REF_FILE" ]]; then
      echo "✗ TARGET=linked but no linked project found." >&2
      echo "  Run \`supabase link --project-ref <ref>\` first, then retry." >&2
      exit 1
    fi
    PROJECT_REF=$(tr -d '[:space:]' < "$PROJECT_REF_FILE")
    if [[ -z "$PROJECT_REF" ]]; then
      echo "✗ $PROJECT_REF_FILE is empty." >&2; exit 1
    fi
    SUPABASE_URL="https://${PROJECT_REF}.supabase.co"
    echo "Fetching service-role key for linked project '$PROJECT_REF'..."
    KEYS_JSON=$(supabase projects api-keys --project-ref "$PROJECT_REF" --output json 2>/dev/null) || {
      echo "✗ \`supabase projects api-keys\` failed." >&2
      echo "  Are you logged in? Try \`supabase login\` and retry." >&2
      exit 1
    }
    SUPABASE_SERVICE_ROLE_KEY=$(echo "$KEYS_JSON" \
      | jq -r 'map(select(.id == "service_role" or (.name == "service_role" and .type == "legacy"))) | .[0].api_key // empty')
    if [[ -z "$SUPABASE_SERVICE_ROLE_KEY" || "$SUPABASE_SERVICE_ROLE_KEY" == "null" ]]; then
      echo "✗ Could not extract service_role key from CLI output." >&2; exit 1
    fi
    ;;
  prod)
    : "${SUPABASE_URL:?SUPABASE_URL is required for TARGET=prod}"
    : "${SUPABASE_SERVICE_ROLE_KEY:?SUPABASE_SERVICE_ROLE_KEY is required for TARGET=prod}"
    ;;
  *)
    echo "✗ TARGET must be 'local', 'linked', or 'prod' (got '$TARGET')" >&2; exit 1
    ;;
esac

SUPABASE_URL="${SUPABASE_URL%/}"

# ── Build the request body (skip empty fields) ──────────────────────────────

BODY=$(jq -nc \
  --argjson dry_run "$([[ "$DRY_RUN" == "true" ]] && echo true || echo false)" \
  --arg company_id "$COMPANY_ID" \
  --arg batch_size "$BATCH_SIZE" \
  --arg min_interval_ms "$MIN_INTERVAL_MS" \
  '
  { dry_run: $dry_run }
  + (if $company_id      != "" then {company_id: $company_id} else {} end)
  + (if $batch_size      != "" then {batch_size: ($batch_size|tonumber)} else {} end)
  + (if $min_interval_ms != "" then {min_interval_ms: ($min_interval_ms|tonumber)} else {} end)
  ')

echo "Target:       $TARGET"
echo "Supabase URL: $SUPABASE_URL"
echo "Scope:        ${COMPANY_ID:-all companies}"
echo "Dry run:      $DRY_RUN"
echo

# ── Confirm before a real write to a remote project ─────────────────────────

if [[ "$DRY_RUN" != "true" && "$TARGET" != "local" && "${AUTO_CONFIRM:-false}" != "true" ]]; then
  read -rp "Write commute distances + refresh CO₂ on '$TARGET'? [y/N] " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "  aborted." >&2; exit 1
  fi
  echo
fi

# ── Invoke the function (it backfills distances, then chains the refresh) ────

RESP=$(curl -sS -X POST "$SUPABASE_URL/functions/v1/recompute-commute-distances" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY")

# A well-formed run returns {scanned, computed, cleared, unchanged, refreshed, dry_run}.
if ! echo "$RESP" | jq -e 'has("scanned")' > /dev/null 2>&1; then
  echo "✗ unexpected response:" >&2
  echo "$RESP" >&2
  exit 1
fi

echo "Result:"
echo "$RESP" | jq .
echo

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run — nothing written. Re-run without DRY_RUN=true to apply."
elif [[ "$(echo "$RESP" | jq -r '.refreshed')" == "true" ]]; then
  echo "✓ Distances written and company_co2_stats refreshed for the current week."
  echo "  The HR console now shows the first correct CO₂. The Mon–Fri cron keeps it fresh."
else
  echo "✓ No distance changes (nothing to refresh). Stats already reflect reality."
fi
