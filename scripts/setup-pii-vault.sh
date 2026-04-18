#!/bin/bash
# Generate a 32-byte AES-256 key and insert it into Supabase Vault as
# `pii_encryption_key`. Used by supabase/functions/_shared/piiCrypto.ts
# for application-level encryption of employee_pii fields.
#
# Usage:
#   ./scripts/setup-pii-vault.sh                # local dev (docker container)
#   PII_KEY=<base64> ./scripts/setup-pii-vault.sh   # reuse an existing key
#
# For staging/prod: generate the key with `openssl rand -base64 32`,
# then insert it via the Supabase dashboard SQL editor:
#   SELECT vault.create_secret('<base64-key>', 'pii_encryption_key');
# Store the key in a password manager and share with at least one other
# person. Losing it = losing all encrypted PII.

set -euo pipefail

CONTAINER="supabase_db_mobi-pass-be"
SECRET_NAME="pii_encryption_key"

# Generate or reuse key
if [[ -n "${PII_KEY:-}" ]]; then
  KEY="$PII_KEY"
  echo "Using supplied PII_KEY (${#KEY} chars)"
else
  KEY=$(openssl rand -base64 32 | tr -d '\n')
  echo "Generated new 32-byte AES-256 key"
  echo
  echo "  $KEY"
  echo
  echo "Save this key in a password manager. If you lose it, all encrypted PII is unrecoverable."
  echo
fi

# Upsert: delete any existing secret with this name, then create.
echo "Removing any existing '$SECRET_NAME' in Vault..."
docker exec "$CONTAINER" psql -U postgres -c \
  "DELETE FROM vault.secrets WHERE name = '$SECRET_NAME';" > /dev/null

echo "Inserting '$SECRET_NAME' into Vault..."
docker exec "$CONTAINER" psql -U postgres -c \
  "SELECT vault.create_secret('$KEY', '$SECRET_NAME');" > /dev/null

echo "Verifying..."
docker exec "$CONTAINER" psql -U postgres -c \
  "SELECT name, LENGTH(decrypted_secret) AS len FROM vault.decrypted_secrets WHERE name = '$SECRET_NAME';"

echo "Done."
