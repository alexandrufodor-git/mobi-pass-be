#!/bin/bash
# One-shot setup for the Maestro E2E test harness.
#
# Does all three phases in order:
#   1. Vault secrets   — e2e_secret, e2e_default_password, e2e_bike_id
#   2. Deploy          — pushes e2e-seed + e2e-otp edge functions
#   3. Bootstrap       — creates E2E Test Co company + 4 test accounts
#
# Usage (local):
#   ./scripts/setup-e2e-vault.sh
#
# Usage (reuse existing values):
#   E2E_SECRET=<hex> E2E_DEFAULT_PASSWORD=<pw> E2E_BIKE_ID=<uuid> \
#     ./scripts/setup-e2e-vault.sh
#
# For prod: the script targets local Supabase (docker container). Prod Vault
# setup is manual via dashboard SQL — recipe printed at the end.

set -euo pipefail

CONTAINER="supabase_db_mobi-pass-be"
LOCAL_FUNCTIONS_URL="http://127.0.0.1:54321/functions/v1"

# ─── Phase 1: Vault secrets ──────────────────────────────────────────────────

echo "═══ Phase 1: Vault secrets ═══"

if [[ -n "${E2E_SECRET:-}" ]]; then
  SECRET="$E2E_SECRET"
  echo "Using supplied E2E_SECRET (${#SECRET} chars)"
else
  SECRET=$(openssl rand -hex 32)
  echo "Generated new E2E_SECRET:"
  echo "  $SECRET"
fi

if [[ -n "${E2E_DEFAULT_PASSWORD:-}" ]]; then
  PASSWORD="$E2E_DEFAULT_PASSWORD"
  echo "Using supplied E2E_DEFAULT_PASSWORD"
else
  PASSWORD=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)
  echo "Generated new E2E_DEFAULT_PASSWORD:"
  echo "  $PASSWORD"
fi

if [[ -n "${E2E_BIKE_ID:-}" ]]; then
  BIKE_ID="$E2E_BIKE_ID"
  echo "Using supplied E2E_BIKE_ID: $BIKE_ID"
else
  echo "Looking up first bike in local DB..."
  BIKE_ID=$(docker exec "$CONTAINER" psql -U postgres -At -c \
    "SELECT id FROM public.bikes ORDER BY created_at LIMIT 1;")
  if [[ -z "$BIKE_ID" ]]; then
    echo "✗ no bikes in DB — run seed data, then re-run with E2E_BIKE_ID=<uuid>" >&2
    exit 1
  fi
  echo "Using first bike: $BIKE_ID"
fi

upsert_secret() {
  local name=$1 value=$2
  docker exec "$CONTAINER" psql -U postgres -c \
    "DELETE FROM vault.secrets WHERE name = '$name';" > /dev/null
  docker exec "$CONTAINER" psql -U postgres -c \
    "SELECT vault.create_secret('$value', '$name');" > /dev/null
  echo "  ✓ $name"
}

echo
upsert_secret "e2e_secret"           "$SECRET"
upsert_secret "e2e_default_password" "$PASSWORD"
upsert_secret "e2e_bike_id"          "$BIKE_ID"

docker exec "$CONTAINER" psql -U postgres -c \
  "SELECT name, LENGTH(decrypted_secret) AS len
   FROM vault.decrypted_secrets
   WHERE name LIKE 'e2e_%' ORDER BY name;"

# ─── Phase 2: Deploy edge functions ──────────────────────────────────────────

echo
echo "═══ Phase 2: Deploy functions ═══"

if command -v supabase > /dev/null; then
  supabase functions deploy e2e-seed --no-verify-jwt
  supabase functions deploy e2e-otp  --no-verify-jwt
else
  echo "! supabase CLI not found — skip deploy (install: brew install supabase/tap/supabase)"
fi

# ─── Phase 3: Bootstrap test accounts ────────────────────────────────────────

echo
echo "═══ Phase 3: Bootstrap accounts ═══"

BOOTSTRAP=$(curl -sS -X POST "$LOCAL_FUNCTIONS_URL/e2e-seed" \
  -H "X-E2E-Secret: $SECRET" \
  -H "Content-Type: application/json" \
  -d '{"command":"bootstrap"}')
echo "$BOOTSTRAP"
if [[ "$BOOTSTRAP" != *'"ok":true'* ]]; then
  echo "✗ bootstrap failed — see function logs" >&2
  exit 1
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo
echo "═══ Done — export these in your shell for the runner ═══"
echo
echo "export SUPABASE_URL=\"http://127.0.0.1:54321\""
echo "export E2E_SECRET=\"$SECRET\""
echo "export E2E_DEFAULT_PASSWORD=\"$PASSWORD\""
echo
echo "Run a flow:"
echo "  cd ../mobi-pass && ./testing/maestro/run.sh onboarding-1-to-4 --platform=android"
echo

# ─── Prod recipe ─────────────────────────────────────────────────────────────

cat <<EOF
═══ For prod ═══

1. Dashboard SQL editor:
   SELECT vault.create_secret('<E2E_SECRET>',           'e2e_secret');
   SELECT vault.create_secret('<E2E_DEFAULT_PASSWORD>', 'e2e_default_password');
   SELECT vault.create_secret('<E2E_BIKE_ID_UUID>',     'e2e_bike_id');

2. Deploy (from linked prod project):
   supabase functions deploy e2e-seed --no-verify-jwt
   supabase functions deploy e2e-otp  --no-verify-jwt

3. Bootstrap:
   curl -sS -X POST "\$SUPABASE_URL/functions/v1/e2e-seed" \\
     -H "X-E2E-Secret: \$E2E_SECRET" \\
     -H "Content-Type: application/json" \\
     -d '{"command":"bootstrap"}'

To rotate secrets:
   DELETE FROM vault.secrets WHERE name = 'e2e_secret';
   SELECT vault.create_secret('<new>', 'e2e_secret');
EOF
