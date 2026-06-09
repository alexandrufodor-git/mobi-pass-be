// Shared confidence-scoring for REGES pending-invite claims.
//
// Extracted from register/index.ts so /register AND sso-claim-record use ONE
// source of truth for the weights + threshold (and one place to tune them).
//
// Tuning notes: the weights sum to 1.0 in the best case. A derived-email + DOB
// hit caps at 1.0; a name + DOB hit (no derived email) lands around 0.55 —
// comfortably above the 0.50 claim threshold but with room to widen.

// Weight coefficients sum to 1.0 in the best case. Clamped to [0, 1].
const W_EMAIL_DERIVED = 0.45
const W_DOB           = 0.30
const W_FIRST         = 0.15
const W_LAST          = 0.10

export const CLAIM_THRESHOLD = 0.50

// One row of match_pending_invite output (a candidate invite + its sub-scores).
export interface MatchCandidate {
  id:                  string
  radiat:              boolean
  email_derived_match: boolean
  dob_matched:         boolean
  first_score:         number
  last_score:          number
}

// Weighted sum of the candidate's match signals, clamped to [0, 1].
export function score(c: MatchCandidate): number {
  let s = 0
  if (c.email_derived_match) s += W_EMAIL_DERIVED
  if (c.dob_matched)         s += W_DOB
  s += Math.max(0, Math.min(1, c.first_score)) * W_FIRST
  s += Math.max(0, Math.min(1, c.last_score))  * W_LAST
  return Math.min(1, s)
}
