// Mobile ClaimRecord screen → resolve a pending SSO claim.
//
// A Google SSO user who matched no invite at sign-in lands on
// status='pending_sso_claim'. They submit first_name + last_name +
// date_of_birth here; we score them against the company's pending REGES/CSV
// invites (same weights as /register, via _shared/regesScoring.ts) and either:
//   - exactly one candidate ≥ threshold and not radiat → AUTO-PROMOTE
//     (promote_sso_claim, service_role) and the user is onboarded, OR
//   - ambiguous / none / radiat-only / promote-conflict → store suggestions,
//     set status='pending_review', and leave the claim for HR.
//
// Deliberately NO check_details (422) gate like /register: the Google email is
// already verified and there is no OTP delivery target to protect.

import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { Errors, badRequest, json } from "../_shared/constants.ts"
import { corsResponse } from "../_shared/ioHelpers.ts"
import { requireJwt, extractUserId } from "../_shared/auth.ts"
import { makeRestClient, type RestClient } from "../_shared/supabaseRest.ts"
import { birthDateHash } from "../_shared/piiLookup.ts"
import { encrypt } from "../_shared/piiCrypto.ts"
import { normalizeName } from "../_shared/regesMapping.ts"
import { score, CLAIM_THRESHOLD, type MatchCandidate } from "../_shared/regesScoring.ts"

interface ClaimBody {
  first_name?:    string
  last_name?:     string
  date_of_birth?: string  // ISO YYYY-MM-DD
}

interface PendingClaim {
  id:         string
  company_id: string
  email:      string
}

type ScoredCandidate = MatchCandidate & { total: number }

async function audit(
  db: RestClient,
  claim: PendingClaim,
  resultCode: string,
  extra: Record<string, unknown>,
): Promise<void> {
  try {
    await db.post("integration_messages", {
      company_id:     claim.company_id,
      integration:    "sso",
      operation:      "sso_claim_submitted",
      entity_type:    "sso_pending_claims",
      entity_id:      claim.id,
      direction:      "inbound",
      status:         resultCode === "auto_promoted" ? "success" : "pending",
      result_code:    resultCode,
      result_payload: extra,
      processed_at:   new Date().toISOString(),
    })
  } catch (err) {
    console.error("[sso-claim-record] audit write failed:", err)
  }
}

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || undefined
  if (req.method === "OPTIONS") return corsResponse(origin)

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!
    const serviceKey  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    const db = makeRestClient(supabaseUrl, serviceKey)

    const jwt    = requireJwt(req, origin)
    const userId = extractUserId(jwt, origin)

    const body = await req.json().catch(() => ({})) as ClaimBody
    const firstNorm = normalizeName(body.first_name)
    const lastNorm  = normalizeName(body.last_name)
    const dob       = (body.date_of_birth || "").trim() || null
    if (!firstNorm || !lastNorm || !dob) {
      return badRequest(Errors.NAME_REQUIRED_FOR_CLAIM, undefined, origin)
    }

    // 1. Load this user's active pending claim (service_role; scoped by user_id).
    const claim = await db.getOne<PendingClaim>(
      "sso_pending_claims",
      `user_id=eq.${encodeURIComponent(userId)}&status=in.(awaiting_user_info,pending_review)`,
      "id,company_id,email",
    )
    if (!claim) return json(Errors.NO_PENDING_CLAIM, 404, origin)

    // 2. Hash + encrypt the DOB; lower the (already-verified) Google email.
    const dobHash  = await birthDateHash(db, dob)
    const dobEnc   = await encrypt(db, dob)
    const emailLow = claim.email.toLowerCase()

    // 3. Match against the company's pending invites (same RPC as /register).
    const raw = await db.rpc<MatchCandidate[]>("match_pending_invite", {
      p_company_id:  claim.company_id,
      p_dob_hash:    dobHash,
      p_first_norm:  firstNorm,
      p_last_norm:   lastNorm,
      p_email_lower: emailLow,
    })
    const scored: ScoredCandidate[] = raw.map((c) => ({ ...c, total: score(c) }))
    const above = scored.filter((c) => c.total >= CLAIM_THRESHOLD)

    // 4. Persist submitted details + suggestions on the claim row.
    await db.patch("sso_pending_claims", `id=eq.${claim.id}`, {
      first_name:              body.first_name,
      last_name:               body.last_name,
      date_of_birth_encrypted: dobEnc,
      birth_date_hash:         dobHash,
      suggested_invite_ids:    scored.map((c) => c.id),
      suggested_scores:        scored.map((c) => ({
        id: c.id, total: c.total, dob_matched: c.dob_matched,
        email_derived_match: c.email_derived_match,
        first_score: c.first_score, last_score: c.last_score, radiat: c.radiat,
      })),
      updated_at: new Date().toISOString(),
    })

    // 5. Auto-promote a single high-confidence, active match. promote_sso_claim
    //    may still refuse (e.g. the invite's email is already bound to someone
    //    else) — in that case fall through to HR review rather than lie.
    let promoteRefused = false
    if (above.length === 1 && !above[0].radiat) {
      const winner = above[0]
      const result = await db.rpc<{ approved?: boolean }>("promote_sso_claim", {
        p_claim_id:  claim.id,
        p_invite_id: winner.id,
      })
      if (result?.approved) {
        await audit(db, claim, "auto_promoted", { invite_id: winner.id, confidence: winner.total })
        return json({ success: true, claim: "auto_promoted", confidence: winner.total }, 200, origin)
      }
      promoteRefused = true
    }

    // 6. Otherwise queue for HR review.
    await db.patch("sso_pending_claims", `id=eq.${claim.id}`, {
      status:     "pending_review",
      updated_at: new Date().toISOString(),
    })
    const resultCode =
      promoteRefused          ? "promote_conflict"
      : above.length > 1      ? "ambiguous"
      : above.length === 1    ? "inactive"          // single match but radiat
      : scored.length === 0   ? "no_match"
                              : "below_threshold"
    await audit(db, claim, resultCode, { candidates_count: scored.length })
    return json({ success: true, status: "pending_review", reason: resultCode }, 200, origin)
  } catch (e) {
    if (e instanceof Response) return e
    throw e
  }
})
