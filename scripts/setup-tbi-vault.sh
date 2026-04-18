#!/bin/bash
# Insert TBI RSA keys into Supabase Vault (local dev)

CONTAINER="supabase_db_mobi-pass-be"
KEY_DIR="/Users/machita/Downloads/DOCUMENTATIE TEST API"

PUB_KEY=$(cat "${KEY_DIR}/Chei_Comerciant_tbitestapi_ro/pub.pem")
PRIV_KEY=$(cat "${KEY_DIR}/Chei_SFTL_tbitestapi_ro/priv_key.pem")

echo "Inserting tbi_public_key into Vault..."
docker exec "$CONTAINER" psql -U postgres -c "SELECT vault.create_secret(\$\$${PUB_KEY}\$\$, 'tbi_public_key');"

echo "Inserting tbi_private_key into Vault..."
docker exec "$CONTAINER" psql -U postgres -c "SELECT vault.create_secret(\$\$${PRIV_KEY}\$\$, 'tbi_private_key');"

echo "Verifying..."
docker exec "$CONTAINER" psql -U postgres -c "SELECT name FROM vault.decrypted_secrets WHERE name IN ('tbi_public_key', 'tbi_private_key');"
