#!/bin/bash
# ============================================================
# send-contract — multi-role (employee IS HR) signer verification
# ============================================================
# Reproduces the real prod scenario where ONE person holds both the
# `employee` and `hr` roles in the Mobipass Gmail company, requests their own
# bike-benefit contract, and must end up with TWO signers (beneficiary +
# employer) even though both resolve to the same email.
#
# Fixture values mirror prod (read via `supabase db query --linked`):
#   company  44444444… (local mirror of "Mobipass Gmail", email_domain gmail.com)
#   user     5347b0f5… fodor.horatiu.alexandru@gmail.com  roles {hr, employee}
#   template 6c9db750… (real eSignatures "ACORD-CADRU … eBike")
#
# Prereqs:
#   supabase start
#   ESIGNATURES_API_KEY='<sandbox-token>' ./scripts/setup-esignatures-vault.sh
#
# send-contract sends test:true → eSignatures sandbox; no live contract, no
# email actually delivered. Re-run `supabase db reset` (+ re-seed vault) for a
# clean slate.
# ============================================================
set -euo pipefail

DB_CONTAINER="supabase_db_mobi-pass-be"
FUNCTIONS_URL="http://127.0.0.1:54321/functions/v1"
JWT_SECRET="super-secret-jwt-token-with-at-least-32-characters-long"

USER_ID="5347b0f5-3f3b-4e5d-bd63-5c6276edde5d"
EMAIL="fodor.horatiu.alexandru@gmail.com"
COMPANY_ID="44444444-4444-4444-4444-444444444444"
TEMPLATE_ID="6c9db750-f9f9-4f63-8a98-ada842cbc5bd"

db() { docker exec -i "$DB_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -tAc "$1"; }

echo "═══ 1. Fixture (mirrors prod Mobipass Gmail multi-role user) ═══"
db "
BEGIN;
-- Control the inserts ourselves; bypass ALL triggers (incl. the auth
-- on_auth_user_created registration trigger we don't own) for this session.
SET LOCAL session_replication_role = replica;

-- Auth user (FK target for profiles.user_id).
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
VALUES ('00000000-0000-0000-0000-000000000000', '${USER_ID}', 'authenticated',
        'authenticated', '${EMAIL}', '', now(), now(), now(),
        '{\"provider\":\"email\",\"providers\":[\"email\"]}', '{}')
ON CONFLICT (id) DO NOTHING;

-- Company: point local gmail mirror at the real template + address.
UPDATE public.companies
   SET esignatures_template_id = '${TEMPLATE_ID}',
       address = 'Strada Avram Iancu 22, Cluj-Napoca 400117'
 WHERE id = '${COMPANY_ID}';

-- Profile for the multi-role person.
INSERT INTO public.profiles (user_id, email, first_name, last_name, company_id)
VALUES ('${USER_ID}', '${EMAIL}', 'ALEXANDRU-HORATIU', 'FODOR', '${COMPANY_ID}')
ON CONFLICT (user_id) DO UPDATE
   SET email = EXCLUDED.email, company_id = EXCLUDED.company_id,
       first_name = EXCLUDED.first_name, last_name = EXCLUDED.last_name;

-- Make THIS user the company's sole HR so loadHR resolves to them (== the
-- employee) — the exact same-account collision that triggers the bug.
-- (user_roles has no unique on (user_id,role); delete-then-insert for idempotency.)
DELETE FROM public.user_roles
 WHERE role = 'hr'
   AND user_id IN (SELECT user_id FROM public.profiles WHERE company_id = '${COMPANY_ID}');
DELETE FROM public.user_roles WHERE user_id = '${USER_ID}';
INSERT INTO public.user_roles (user_id, role) VALUES
  ('${USER_ID}', 'employee'), ('${USER_ID}', 'hr');

-- Benefit at sign_contract, with a real local bike + pricing, no prior request.
-- (no unique on user_id; delete-then-insert.)
DELETE FROM public.bike_benefits WHERE user_id = '${USER_ID}';
INSERT INTO public.bike_benefits
       (user_id, bike_id, step, employee_full_price, employee_monthly_price,
        employee_contract_months, employee_currency, contract_requested_at)
SELECT '${USER_ID}', id, 'sign_contract', 13750.00, 382.00, 36, 'RON', NULL
FROM public.bikes ORDER BY created_at LIMIT 1;

-- Clear any prior contract row so the run is repeatable.
DELETE FROM public.contracts WHERE user_id = '${USER_ID}';

COMMIT;
" > /dev/null
echo "  ✓ fixture ready (user is employee + sole HR of the company)"

echo
echo "═══ 2. Mint employee JWT + call send-contract ═══"
HEADER='{"alg":"HS256","typ":"JWT"}'
NOW=$(date +%s); EXP=$((NOW + 3600))
PAYLOAD="{\"sub\":\"${USER_ID}\",\"role\":\"authenticated\",\"user_role\":\"employee\",\"aud\":\"authenticated\",\"exp\":${EXP},\"iat\":${NOW}}"
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
H=$(printf '%s' "$HEADER" | b64)
P=$(printf '%s' "$PAYLOAD" | b64)
S=$(printf '%s' "${H}.${P}" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64)
JWT="${H}.${P}.${S}"

RESP=$(curl -s -w "\n%{http_code}" -X POST "${FUNCTIONS_URL}/send-contract" \
  -H "Authorization: Bearer ${JWT}" -H "Content-Type: application/json" -d '{}')
STATUS=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
echo "  HTTP ${STATUS}"
echo "  ${BODY}"

echo
echo "═══ 3. Assert eSignatures echoed TWO signers (same email, differentiated) ═══"
docker exec "$DB_CONTAINER" psql -U postgres -tAc "
  SELECT jsonb_array_length(api_response->'data'->'contract'->'signers')
  FROM public.contracts WHERE user_id='${USER_ID}'
  ORDER BY created_at DESC LIMIT 1;" | {
  read -r COUNT
  echo "  signer_count = ${COUNT:-<none>}"
  docker exec "$DB_CONTAINER" psql -U postgres -tAc "
    SELECT string_agg(
             coalesce(s->>'name','?') || ' <' || coalesce(s->>'email','?') || '> ' ||
             'company=' || coalesce(s->>'company_name','-') || ' order=' || coalesce(s->>'signing_order','?'),
             E'\n           ')
    FROM public.contracts c,
         jsonb_array_elements(c.api_response->'data'->'contract'->'signers') s
    WHERE c.user_id='${USER_ID}'
      AND c.created_at=(SELECT max(created_at) FROM public.contracts WHERE user_id='${USER_ID}');" \
    | sed 's/^/           /'
  if [ "${COUNT:-0}" = "2" ]; then
    echo "  ✅ PASS — two signers present (employer signature block preserved)"
  else
    echo "  ❌ FAIL — expected 2 signers, got ${COUNT:-<none>}"
    exit 1
  fi
}
