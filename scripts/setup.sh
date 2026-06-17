#!/bin/bash
# One-shot local sandbox setup for send-contract / edge-function testing.
# Chains the steps that otherwise need running by hand each session.
#
# Usage:
#   ESIGNATURES_API_KEY='<sandbox-token>' ./scripts/setup.sh          # setup only
#   ESIGNATURES_API_KEY='<sandbox-token>' ./scripts/setup.sh --test   # + run test
#
# Token is passed inline only — never written to disk (lives in Vault,
# wiped by `supabase db reset`). Idempotent; safe to re-run.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
EDGE="supabase_edge_runtime_mobi-pass-be"

echo "▶ 1/3  Supabase running?"
if ! supabase status >/dev/null 2>&1; then
  echo "  starting…"; supabase start
else
  echo "  ✓ up"
fi

echo "▶ 2/3  Seed eSignatures sandbox token into Vault"
./scripts/setup-esignatures-vault.sh >/dev/null
echo "  ✓ esignature_api_key set"

echo "▶ 3/3  Restart edge runtime (serve latest function code) + wait ready"
docker restart "$EDGE" >/dev/null
for i in $(seq 1 30); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 3 -X POST \
    "http://127.0.0.1:54321/functions/v1/send-contract" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo 000)
  [ "$CODE" = "401" ] && { echo "  ✓ ready (${i}s)"; break; }
  printf '.'; sleep 1
done

if [[ "${1:-}" == "--test" ]]; then
  echo; echo "▶ Running send-contract multi-role test"
  ./scripts/test-send-contract.sh
fi

echo; echo "✓ Ready. Run the test with: ./scripts/test-send-contract.sh"
