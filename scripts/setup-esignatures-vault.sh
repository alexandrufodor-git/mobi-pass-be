#!/bin/bash
# Insert the eSignatures.com SANDBOX API token into the local Supabase Vault as
# `esignature_api_key`. Used by supabase/functions/send-contract/index.ts
# (loadApiKey → get_vault_secret) and esignatures-webhook for HMAC.
#
# send-contract always sends `test: true`, so this MUST be a sandbox token —
# no live contracts are created. Get the sandbox token from the eSignatures.com
# dashboard (Settings → API) under the mobipass account.
#
# Usage — pass the token inline so it is NEVER written to disk; it only ever
# lands in Vault (encrypted at rest, wiped by `supabase db reset`):
#   ESIGNATURES_API_KEY='<sandbox-token>' ./scripts/setup-esignatures-vault.sh
#
# Do NOT persist the token in supabase/.env.local or any other file. The
# send-contract function reads it from Vault (get_vault_secret), not from env,
# so a file copy buys nothing and is just a long-lived plaintext secret.
#
# For staging/prod the token is set manually via the dashboard SQL editor:
#   SELECT vault.create_secret('<token>', 'esignature_api_key');

set -euo pipefail

CONTAINER="supabase_db_mobi-pass-be"
SECRET_NAME="esignature_api_key"

# Token comes from the environment only — never read from a file on disk.
TOKEN="${ESIGNATURES_API_KEY:-}"
if [[ -z "$TOKEN" ]]; then
  echo "✗ no token. Run as: ESIGNATURES_API_KEY='<sandbox-token>' $0" >&2
  exit 1
fi

echo "Using eSignatures SANDBOX token (${#TOKEN} chars)"

# Upsert: delete any existing secret with this name, then create.
echo "Removing any existing '$SECRET_NAME' in Vault..."
docker exec "$CONTAINER" psql -U postgres -c \
  "DELETE FROM vault.secrets WHERE name = '$SECRET_NAME';" > /dev/null

echo "Inserting '$SECRET_NAME' into Vault..."
docker exec "$CONTAINER" psql -U postgres -c \
  "SELECT vault.create_secret('$TOKEN', '$SECRET_NAME');" > /dev/null

echo "Verifying..."
docker exec "$CONTAINER" psql -U postgres -c \
  "SELECT name, LENGTH(decrypted_secret) AS len FROM vault.decrypted_secrets WHERE name = '$SECRET_NAME';"

echo "Done."
