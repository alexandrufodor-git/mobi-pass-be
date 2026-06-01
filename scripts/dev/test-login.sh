#!/usr/bin/env bash
# ============================================================================
# Smoke-test password login against the linked Supabase project.
#
# Why this exists: the anon JWT has dots / equals / sometimes plus signs and
# zsh/bash chew through it (history expansion, glob, brace expansion). Pasting
# it on the command line breaks roughly half the time. This script fetches the
# key in-process and feeds it to curl as a quoted variable — no copy/paste.
#
# Usage:
#   scripts/dev/test-login.sh                        # uses HR_EMAIL/HR_PASSWORD from create-company.env
#   EMAIL=foo@bar.com PASSWORD=hunter2 scripts/dev/test-login.sh
#   scripts/dev/test-login.sh --legacy               # use legacy anon key (default)
#   scripts/dev/test-login.sh --publishable          # use new sb_publishable_* key
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load create-company.env so HR_EMAIL / HR_PASSWORD are available by default.
CONFIG_FILE="${CREATE_COMPANY_ENV:-$SCRIPT_DIR/create-company.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  set -a; source "$CONFIG_FILE"; set +a
fi

# Per-run overrides take precedence over create-company.env values.
EMAIL="${EMAIL:-${HR_EMAIL:-}}"
PASSWORD="${PASSWORD:-${HR_PASSWORD:-}}"

KEY_KIND="legacy"
for arg in "$@"; do
  case "$arg" in
    --legacy)      KEY_KIND="legacy" ;;
    --publishable) KEY_KIND="publishable" ;;
    -h|--help)
      sed -n '4,17p' "$0"; exit 0 ;;
  esac
done

if [[ -z "$EMAIL" || -z "$PASSWORD" ]]; then
  echo "✗ EMAIL and PASSWORD required (HR_EMAIL/HR_PASSWORD in $CONFIG_FILE or pass inline)" >&2
  exit 1
fi

# Resolve project from `supabase link` state.
PROJECT_REF_FILE="$REPO_ROOT/supabase/.temp/project-ref"
if [[ ! -f "$PROJECT_REF_FILE" ]]; then
  echo "✗ No linked project. Run 'supabase link --project-ref <ref>' first." >&2
  exit 1
fi
PROJECT_REF=$(tr -d '[:space:]' < "$PROJECT_REF_FILE")
SUPABASE_URL="https://${PROJECT_REF}.supabase.co"

# Fetch the requested key flavor. Two pickers because the CLI lists both
# legacy JWT keys and the new sb_publishable_* / sb_secret_* keys.
KEYS_JSON=$(supabase projects api-keys --project-ref "$PROJECT_REF" --output json 2>/dev/null)
case "$KEY_KIND" in
  legacy)
    KEY=$(echo "$KEYS_JSON" | jq -r '.[] | select(.name=="anon" and .type=="legacy") | .api_key')
    ;;
  publishable)
    KEY=$(echo "$KEYS_JSON" | jq -r '.[] | select(.type=="publishable") | .api_key' | head -1)
    ;;
esac
if [[ -z "$KEY" || "$KEY" == "null" ]]; then
  echo "✗ Could not extract $KEY_KIND key. Available:" >&2
  echo "$KEYS_JSON" | jq -r '.[] | "  - \(.name) (\(.type // "-"))"' >&2
  exit 1
fi

echo "→ POST $SUPABASE_URL/auth/v1/token?grant_type=password"
echo "  key:   $KEY_KIND (${KEY:0:14}…)"
echo "  email: $EMAIL"
echo

# Body via jq so escaping is correct even if the password has $ ! { } in it.
BODY=$(jq -nc --arg email "$EMAIL" --arg password "$PASSWORD" \
  '{email: $email, password: $password}')

HTTP_CODE_FILE=$(mktemp)
RESP=$(curl -sS -o >(cat) -w "%{http_code}" \
  "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $KEY" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  --data-raw "$BODY" \
  2> >(cat >&2) ) || true

# Last 3 chars of $RESP are the HTTP status; strip them for the body.
HTTP_CODE="${RESP: -3}"
BODY_OUT="${RESP::${#RESP}-3}"

echo
echo "← HTTP $HTTP_CODE"
echo "$BODY_OUT" | jq . 2>/dev/null || echo "$BODY_OUT"

case "$HTTP_CODE" in
  200) echo; echo "✓ login OK — credentials match. Issue is in the mobile client." ;;
  400) echo; echo "✗ Auth rejected. error_code in body says exactly why (invalid_credentials = wrong pw or email)." ;;
  401) echo; echo "✗ 401 — anon key is wrong/expired (very rare with --legacy)." ;;
esac

rm -f "$HTTP_CODE_FILE"
