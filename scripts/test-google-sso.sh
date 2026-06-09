#!/usr/bin/env bash
# ============================================================================
# Google Workspace SSO — Integration Test Script
# ============================================================================
# Prerequisites:
#   supabase start && supabase db reset
#   scripts/setup-pii-vault.sh   (provides pii_encryption_key in Vault)
#
# Focuses on the sso-claim-record EDGE FUNCTION + the get-employee-details
# claim block. The trigger Google branch and promote_sso_claim RPC are already
# covered exhaustively by pgTAP 00016_sso_bridge.test.sql, so this layer tests
# the HTTP surface: JWT auth, body validation, match → auto-promote vs HR
# review, DOB encryption, and the unified profile claim block.
# ============================================================================

set -euo pipefail

echo "╭──────────────────────────────────────────────────────╮"
echo "│ Google Workspace SSO — Integration Tests             │"
echo "╰──────────────────────────────────────────────────────╯"

if ! supabase status -o env > /dev/null 2>&1; then
  echo "✗ Supabase not running. Run: supabase start && supabase db reset"
  exit 1
fi
eval "$(supabase status -o env 2>/dev/null)"

DB_CONTAINER=$(docker ps --filter "name=supabase_db_" --format "{{.Names}}" | head -1)
PSQL="docker exec -i $DB_CONTAINER psql -U postgres -qtAX"
FN="$API_URL/functions/v1/sso-claim-record"
GED="$API_URL/functions/v1/get-employee-details"

PASS=0; FAIL=0; TOTAL=0
check() {
  TOTAL=$((TOTAL + 1)); local label="$1" result="$2"
  if [ "$result" = "true" ] || [ "$result" = "1" ] || [ "$result" = "PASS" ]; then
    PASS=$((PASS + 1)); echo "  ✓ $label"
  else
    FAIL=$((FAIL + 1)); echo "  ✗ $label  (got: '$result')"
  fi
}
section() { echo ""; echo "── $1 ──"; }

make_jwt() {
  local user_id="$1" role="$2" now exp payload h p s
  now=$(date +%s); exp=$((now + 3600))
  payload="{\"sub\":\"$user_id\",\"role\":\"authenticated\",\"user_role\":\"$role\",\"iss\":\"supabase-demo\",\"iat\":$now,\"exp\":$exp}"
  h=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | base64 | tr -d '=' | tr '+/' '-_' | tr -d '\n')
  p=$(printf '%s' "$payload" | base64 | tr -d '=' | tr '+/' '-_' | tr -d '\n')
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | base64 | tr -d '=' | tr '+/' '-_' | tr -d '\n')
  echo "${h}.${p}.${s}"
}

# DOB blind index — mirrors _shared/piiLookup.ts::birthDateHash exactly so a
# fixture invite's birth_date_hash matches what the edge function computes.
PII_KEY_B64=$($PSQL -c "SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='pii_encryption_key';")
HEXKEY=$(printf '%s' "$PII_KEY_B64" | openssl base64 -d -A | od -An -v -tx1 | tr -d ' \n')
dob_hash() {
  printf '%s' "pii_lookup:dob:v1:$1" \
    | openssl dgst -sha256 -mac HMAC -macopt hexkey:"$HEXKEY" -binary \
    | openssl base64 -A | tr '+/' '-_' | tr -d '='
}

call() {  # call <jwt> <json> → writes body to /tmp/sso.body, echoes HTTP code
  local jwt="$1" body="$2"
  curl -s -o /tmp/sso.body -w "%{http_code}" -X POST "$FN" \
    -H "Authorization: Bearer $jwt" -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" -d "$body"
}

# ── Fixtures ────────────────────────────────────────────────────────────────
section "Fixture setup"

CO=$(uuidgen | tr 'A-Z' 'a-z')
INV_MATCH=$(uuidgen | tr 'A-Z' 'a-z')
INV_A1=$(uuidgen | tr 'A-Z' 'a-z')
INV_A2=$(uuidgen | tr 'A-Z' 'a-z')
U_AUTO=$(uuidgen | tr 'A-Z' 'a-z')
U_AMB=$(uuidgen | tr 'A-Z' 'a-z')
U_NOM=$(uuidgen | tr 'A-Z' 'a-z')
H_MATCH=$(dob_hash "1990-05-20")
H_AMB=$(dob_hash "1985-03-10")

# Helper to mint a Google OAuth signup (fires on_auth_user_created → pending claim)
gins() {  # gins <uuid> <email>
  $PSQL <<SQL
INSERT INTO auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token,
  raw_user_meta_data, raw_app_meta_data
) VALUES (
  '$1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
  '$2', NULL, now(), now(), now(), '', '', '', '',
  jsonb_build_object('hd','ssoshell.test','given_name','Goog','family_name','User','email','$2'),
  '{"provider":"google","providers":["google"]}'
);
SQL
}

$PSQL <<SQL
-- Idempotent slate: clear any leftover from a previously-crashed run.
DELETE FROM auth.users WHERE email LIKE '%@ssoshell.test';
DELETE FROM public.profile_invites      WHERE company_id IN (SELECT id FROM public.companies WHERE email_domain='ssoshell.test');
DELETE FROM public.integration_messages WHERE company_id IN (SELECT id FROM public.companies WHERE email_domain='ssoshell.test');
DELETE FROM public.company_notifications WHERE company_id IN (SELECT id FROM public.companies WHERE email_domain='ssoshell.test');
DELETE FROM public.companies WHERE email_domain='ssoshell.test';

INSERT INTO public.companies (id, name, monthly_benefit_subsidy, contract_months, currency, email_domain, sso_kind, sso_hd_required)
VALUES ('$CO', 'sso-shell-co', 50.00, 24, 'EUR', 'ssoshell.test', 'google_oidc', true);

-- Single high-confidence target (name + DOB) → auto-promote
INSERT INTO public.profile_invites (id, email, company_id, first_name, last_name, birth_date_hash)
VALUES ('$INV_MATCH', NULL, '$CO', 'Autopromote', 'Winner', '$H_MATCH');

-- Two equally-strong invites → ambiguous
INSERT INTO public.profile_invites (id, email, company_id, first_name, last_name, birth_date_hash)
VALUES ('$INV_A1', NULL, '$CO', 'Ambig', 'Twin', '$H_AMB'),
       ('$INV_A2', NULL, '$CO', 'Ambig', 'Twin', '$H_AMB');
SQL

gins "$U_AUTO" "auto@ssoshell.test"   > /dev/null
gins "$U_AMB"  "amb@ssoshell.test"    > /dev/null
gins "$U_NOM"  "nomatch@ssoshell.test" > /dev/null

JWT_AUTO=$(make_jwt "$U_AUTO" employee)
JWT_AMB=$(make_jwt "$U_AMB" employee)
JWT_NOM=$(make_jwt "$U_NOM" employee)

CLAIMS=$($PSQL -c "SELECT count(*) FROM sso_pending_claims WHERE company_id='$CO' AND status='awaiting_user_info';")
check "3 pending claims created by trigger" "$([ "$CLAIMS" = "3" ] && echo true)"

# ── Section 1 — validation + no-claim ────────────────────────────────────────
section "Section 1 — validation"

CODE=$(call "$JWT_NOM" '{"first_name":"X"}')
check "1.1 missing date_of_birth → 400" "$([ "$CODE" = "400" ] && echo true)"
grep -q "name_required_for_claim" /tmp/sso.body && check "1.1 error code name_required_for_claim" true || check "1.1 error code" false

# ── Section 2 — auto-promote single match ────────────────────────────────────
section "Section 2 — auto-promote"

CODE=$(call "$JWT_AUTO" '{"first_name":"Autopromote","last_name":"Winner","date_of_birth":"1990-05-20"}')
BODY=$(cat /tmp/sso.body)
check "2.1 auto-promote → 200" "$([ "$CODE" = "200" ] && echo true)"
echo "$BODY" | grep -q '"claim":"auto_promoted"' && check "2.1 claim=auto_promoted" true || check "2.1 claim=auto_promoted" false
ST=$($PSQL -c "SELECT status FROM profiles WHERE user_id='$U_AUTO';")
check "2.1 profile now active" "$([ "$ST" = "active" ] && echo true)"
ROLE=$($PSQL -c "SELECT count(*) FROM user_roles WHERE user_id='$U_AUTO' AND role='employee';")
check "2.1 employee role assigned" "$([ "$ROLE" = "1" ] && echo true)"
CST=$($PSQL -c "SELECT status FROM sso_pending_claims WHERE user_id='$U_AUTO';")
check "2.1 claim approved" "$([ "$CST" = "approved" ] && echo true)"
LINK=$($PSQL -c "SELECT (profile_invite_id='$INV_MATCH') FROM profiles WHERE user_id='$U_AUTO';")
check "2.1 canonical profile_invite_id linked" "$([ "$LINK" = "t" ] && echo true)"

CODE=$(call "$JWT_AUTO" '{"first_name":"Autopromote","last_name":"Winner","date_of_birth":"1990-05-20"}')
check "2.2 re-submit after approval → 404 no_pending_claim" "$([ "$CODE" = "404" ] && echo true)"

# ── Section 3 — ambiguous + no-match → HR review ─────────────────────────────
section "Section 3 — HR review queue"

CODE=$(call "$JWT_AMB" '{"first_name":"Ambig","last_name":"Twin","date_of_birth":"1985-03-10"}')
BODY=$(cat /tmp/sso.body)
check "3.1 ambiguous → 200" "$([ "$CODE" = "200" ] && echo true)"
echo "$BODY" | grep -q '"status":"pending_review"' && check "3.1 status=pending_review" true || check "3.1 status=pending_review" false
echo "$BODY" | grep -q '"reason":"ambiguous"' && check "3.1 reason=ambiguous" true || check "3.1 reason=ambiguous" false
ST=$($PSQL -c "SELECT status FROM profiles WHERE user_id='$U_AMB';")
check "3.1 profile stays pending_sso_claim" "$([ "$ST" = "pending_sso_claim" ] && echo true)"
ROLE=$($PSQL -c "SELECT count(*) FROM user_roles WHERE user_id='$U_AMB';")
check "3.1 no role assigned yet" "$([ "$ROLE" = "0" ] && echo true)"
ENC=$($PSQL -c "SELECT date_of_birth_encrypted LIKE 'enc:v1:%' FROM sso_pending_claims WHERE user_id='$U_AMB';")
check "3.1 DOB stored encrypted (enc:v1:)" "$([ "$ENC" = "t" ] && echo true)"

CODE=$(call "$JWT_NOM" '{"first_name":"Nobody","last_name":"Here","date_of_birth":"2000-01-01"}')
BODY=$(cat /tmp/sso.body)
check "3.2 no-match → 200 pending_review" "$([ "$CODE" = "200" ] && echo true)"
echo "$BODY" | grep -q '"reason":"no_match"' && check "3.2 reason=no_match" true || check "3.2 reason=no_match" false

# ── Section 4 — get-employee-details claim block ─────────────────────────────
section "Section 4 — get-employee-details"

curl -s -o /tmp/ged.body -X POST "$GED" -H "Authorization: Bearer $JWT_AMB" -H "apikey: $ANON_KEY" -d '{}'
grep -q '"profile_status":"pending_sso_claim"' /tmp/ged.body && check "4.1 pending user → profile_status pending_sso_claim" true || check "4.1 profile_status" false
grep -q '"submitted":true' /tmp/ged.body && check "4.1 sso_claim.submitted=true (after review submit)" true || check "4.1 sso_claim.submitted" false

curl -s -o /tmp/ged2.body -X POST "$GED" -H "Authorization: Bearer $JWT_AUTO" -H "apikey: $ANON_KEY" -d '{}'
grep -q '"profile_status":"active"' /tmp/ged2.body && check "4.2 promoted user → profile_status active" true || check "4.2 profile_status active" false
grep -q '"sso_claim":null' /tmp/ged2.body && check "4.2 active user → sso_claim null" true || check "4.2 sso_claim null" false

# ── Section 5 — audit log ────────────────────────────────────────────────────
section "Section 5 — audit"

AUD=$($PSQL -c "SELECT count(*) FROM integration_messages WHERE company_id='$CO' AND operation='sso_claim_submitted';")
check "5.1 sso_claim_submitted audit rows written" "$([ "$AUD" -ge "3" ] && echo true)"
AUTOAUD=$($PSQL -c "SELECT count(*) FROM integration_messages WHERE company_id='$CO' AND result_code='auto_promoted';")
check "5.1 auto_promoted audit row exists" "$([ "$AUTOAUD" = "1" ] && echo true)"

# ── Cleanup (children before the company FK; never let teardown mask results) ─
$PSQL -c "DELETE FROM auth.users WHERE id IN ('$U_AUTO','$U_AMB','$U_NOM');" > /dev/null || true
$PSQL -c "DELETE FROM public.profile_invites WHERE company_id='$CO';" > /dev/null || true
$PSQL -c "DELETE FROM public.integration_messages WHERE company_id='$CO';" > /dev/null || true
$PSQL -c "DELETE FROM public.company_notifications WHERE company_id='$CO';" > /dev/null || true
$PSQL -c "DELETE FROM public.companies WHERE id='$CO';" > /dev/null || true

echo ""
echo "╭──────────────────────────────────────────────────────╮"
printf "│ Results: %s passed, %s failed, %s total\n" "$PASS" "$FAIL" "$TOTAL"
echo "╰──────────────────────────────────────────────────────╯"
[ "$FAIL" -eq 0 ]
