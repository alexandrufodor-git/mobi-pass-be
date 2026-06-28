#!/usr/bin/env bash
# Focused audit of the REGES bridge state. Read-only.
#
# Usage:
#   ./scripts/dev/show-audit.sh [view]                    # local dev, all companies
#   ./scripts/dev/show-audit.sh <uuid> [view]             # local dev, one company
#   ./scripts/dev/show-audit.sh --prod [view]             # production, all companies
#   ./scripts/dev/show-audit.sh --prod <uuid> [view]      # production, one company
#
# view: all (default) | imports | registers | invites | pii | notifications | diagnose | follow
#
# diagnose: cross-references each FAILED register_attempt against the actual
#           pending invites by name, comparing the date-of-birth hash the caller
#           typed vs the hash stored on the matching invite. This surfaces the
#           "my date was wrong" case that match_pending_invite hides: a wrong
#           date is filtered out before scoring, so the normal audit shows an
#           empty candidate list with no reason.
#
# --prod requires the project to be linked: supabase link --project-ref <ref>

set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────

PROD=false
COMPANY_ID=""
VIEW="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prod)
      PROD=true
      shift
      if [[ "${1:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        COMPANY_ID="$1"
        shift
      fi
      ;;
    all|imports|registers|invites|pii|notifications|diagnose|follow)
      VIEW="$1"
      shift
      ;;
    [0-9a-f]*-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*)
      COMPANY_ID="$1"
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Connection setup ─────────────────────────────────────────────────────────

if $PROD; then
  RUN_SQL() {
    supabase db query --linked -f /dev/stdin
  }
  FOLLOW_INTERVAL=5
  MODE="prod"
else
  if ! supabase status -o env > /dev/null 2>&1; then
    echo "✗ Supabase not running. Use --prod to target production." >&2; exit 1
  fi
  eval "$(supabase status -o env 2>/dev/null)"
  if command -v psql > /dev/null 2>&1; then
    RUN_SQL() { psql "$DB_URL" -X; }
  else
    DB_CONTAINER=$(docker ps --filter "name=supabase_db_" --format "{{.Names}}" | head -1)
    RUN_SQL() { docker exec -i "$DB_CONTAINER" psql -U postgres -X; }
  fi
  FOLLOW_INTERVAL=2
  MODE="local"
fi

# ── Company filter ───────────────────────────────────────────────────────────

if [[ -n "$COMPANY_ID" ]]; then
  CFILTER="company_id = '$COMPANY_ID'"
  EP_CFILTER="ep.company_id = '$COMPANY_ID'"
else
  CFILTER="TRUE"
  EP_CFILTER="TRUE"
fi

bar() { printf '\n%s\n' "── $1 ──────────────────────────────────────────────────"; }

# ── Views ────────────────────────────────────────────────────────────────────

show_imports() {
  bar "REGES imports (operation='import_employee')"
  RUN_SQL <<SQL
SELECT
  to_char(processed_at, 'HH24:MI:SS') AS time,
  company_id,
  result_payload->>'source_ref_id'    AS source_ref,
  result_code                          AS status,
  result_payload->>'invite_status'     AS invite,
  result_payload->>'derived_email_set' AS pattern_used
FROM public.integration_messages
WHERE $CFILTER
  AND integration = 'reges'
  AND operation   = 'import_employee'
ORDER BY processed_at DESC
LIMIT 20;
SQL
}

show_registers() {
  bar "Register attempts (operation='register_attempt')"
  RUN_SQL <<SQL
SELECT
  to_char(processed_at, 'HH24:MI:SS') AS time,
  company_id,
  status,
  result_code                          AS decision,
  result_payload->>'claim_type'        AS claim_type,
  result_payload->>'email_domain'      AS domain,
  result_payload->>'first_norm'        AS first_norm,
  result_payload->>'last_norm'         AS last_norm,
  jsonb_array_length(COALESCE(result_payload->'candidates', '[]'::jsonb)) AS candidates
FROM public.integration_messages
WHERE $CFILTER
  AND integration = 'reges'
  AND operation   = 'register_attempt'
ORDER BY processed_at DESC
LIMIT 20;
SQL

  printf '\nTop candidates for most recent register attempt:\n'
  RUN_SQL <<SQL
SELECT jsonb_pretty(result_payload->'candidates') AS candidates
FROM public.integration_messages
WHERE $CFILTER
  AND operation = 'register_attempt'
ORDER BY processed_at DESC
LIMIT 1;
SQL
}

show_invites() {
  bar "profile_invites (state)"
  RUN_SQL <<SQL
SELECT
  company_id,
  source,
  source_ref_id,
  first_name || ' ' || last_name       AS name,
  CASE WHEN email IS NULL THEN 'pending' ELSE 'claimed' END AS state,
  COALESCE(email, '-')                 AS email,
  COALESCE(derived_email, '-')         AS derived,
  radiat,
  CASE WHEN birth_date_hash IS NULL THEN '-' ELSE left(birth_date_hash, 12) || '…' END AS dob_hash
FROM public.profile_invites
WHERE $CFILTER
ORDER BY company_id, created_at;
SQL
}

show_pii() {
  bar "employee_pii (staged vs linked)"
  RUN_SQL <<SQL
SELECT
  ep.company_id,
  ep.source_ref_id,
  CASE WHEN ep.user_id IS NULL THEN 'staged' ELSE 'linked' END AS state,
  COALESCE(p.email, '-')               AS bound_email,
  CASE WHEN ep.national_id_encrypted   IS NOT NULL THEN '✓' ELSE '-' END AS cnp_enc,
  CASE WHEN ep.home_address_encrypted  IS NOT NULL THEN '✓' ELSE '-' END AS addr_enc,
  CASE WHEN ep.date_of_birth_encrypted IS NOT NULL THEN '✓' ELSE '-' END AS dob_enc,
  CASE WHEN ep.profile_invite_id IS NULL THEN '-' ELSE 'linked' END AS invite_link
FROM public.employee_pii ep
LEFT JOIN public.profiles p ON p.user_id = ep.user_id
WHERE $EP_CFILTER
ORDER BY ep.company_id, ep.created_at;
SQL
}

show_notifications() {
  bar "company_notifications (HR-visible events)"
  RUN_SQL <<SQL
SELECT
  to_char(created_at, 'HH24:MI:SS') AS time,
  company_id,
  event,
  event_type,
  payload->>'employee_name'          AS who,
  payload->>'invite_id'              AS invite_id,
  payload->>'email'                  AS email
FROM public.company_notifications
WHERE $CFILTER
ORDER BY created_at DESC
LIMIT 20;
SQL
}

show_diagnose() {
  bar "Why did claims fail? (typed DOB hash vs. invite DOB hash, by name)"
  printf '%s\n' "Each failed register_attempt is joined to same-company invites whose"
  printf '%s\n' "name is trigram-similar. dob_check tells you if the date was the problem:"
  printf '%s\n' "  DATE MATCH    → date was right (failure was something else: email/ambiguity)"
  printf '%s\n' "  DATE MISMATCH → typed date hashes differently than the invite's stored date"
  printf '%s\n' "  (no typed_dob) → caller sent no date at all"
  RUN_SQL <<SQL
SELECT
  to_char(im.processed_at, 'HH24:MI:SS')                       AS time,
  im.result_code                                               AS decision,
  COALESCE(im.result_payload->>'first_norm','')
    || ' ' || COALESCE(im.result_payload->>'last_norm','')     AS typed_name,
  COALESCE(left(im.result_payload->>'dob_hash', 10), '-')      AS typed_dob,
  pi.first_name || ' ' || pi.last_name                          AS invite_name,
  COALESCE(left(pi.birth_date_hash, 10), '-')                  AS invite_dob,
  CASE
    WHEN im.result_payload->>'dob_hash' IS NULL THEN '(no typed_dob)'
    WHEN pi.birth_date_hash IS NULL              THEN '(invite has no dob)'
    WHEN pi.birth_date_hash = im.result_payload->>'dob_hash' THEN 'DATE MATCH'
    ELSE 'DATE MISMATCH'
  END                                                          AS dob_check,
  -- Plain-English reason THIS name-matched invite did not rescue the attempt.
  -- Mirrors match_pending_invite's gate: an invite is a candidate only while
  -- pending AND (DOB hash matches OR typed email == derived_email). The typed
  -- email is not audited (only its domain), so a DOB mismatch is reported as
  -- gated-out "unless the email matched" — had it matched, this would have been
  -- a candidate and the attempt would not read not_invited on its account.
  CASE
    WHEN pi.email IS NOT NULL
      THEN 'EXCLUDED: invite already claimed (email set)'
    WHEN im.result_payload->>'dob_hash' IS NULL
      THEN 'GATED OUT: no DOB typed → never a candidate'
    WHEN pi.birth_date_hash = im.result_payload->>'dob_hash'
      THEN 'CANDIDATE: DOB ok → failed on email/ambiguity/threshold'
    ELSE 'GATED OUT: DOB mismatch (unless typed email == derived)'
  END                                                          AS verdict,
  round(similarity(lower(pi.first_name),
        COALESCE(im.result_payload->>'first_norm',''))::numeric, 2) AS first_sim,
  round(similarity(lower(pi.last_name),
        COALESCE(im.result_payload->>'last_norm',''))::numeric, 2)  AS last_sim,
  CASE WHEN pi.email IS NULL THEN 'pending' ELSE 'claimed' END  AS invite_state,
  CASE WHEN pi.derived_email IS NOT NULL THEN '✓' ELSE '-' END  AS has_derived
FROM public.integration_messages im
JOIN public.profile_invites pi
  ON pi.company_id = im.company_id
 AND (
       similarity(lower(pi.first_name), COALESCE(im.result_payload->>'first_norm','')) > 0.3
    OR similarity(lower(pi.last_name),  COALESCE(im.result_payload->>'last_norm',''))  > 0.3
     )
WHERE im.integration = 'reges'
  AND im.operation   = 'register_attempt'
  AND im.result_code <> 'claim'
  AND im.company_id IS NOT NULL
  AND ${CFILTER//company_id/im.company_id}
ORDER BY im.processed_at DESC, last_sim DESC NULLS LAST, first_sim DESC NULLS LAST
LIMIT 40;
SQL
}

show_all() {
  show_imports
  show_registers
  show_invites
  show_pii
  show_notifications
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

case "$VIEW" in
  all)            show_all ;;
  imports)        show_imports ;;
  registers)      show_registers ;;
  invites)        show_invites ;;
  pii)            show_pii ;;
  notifications)  show_notifications ;;
  diagnose)       show_diagnose ;;
  follow)
    while :; do
      clear
      echo "REGES audit [$MODE] — $(date +%H:%M:%S) (Ctrl-C to exit)"
      show_all
      sleep "$FOLLOW_INTERVAL"
    done ;;
esac
