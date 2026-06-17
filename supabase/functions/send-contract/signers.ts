// Signer construction for the send-contract eSignatures payload.
// Extracted from index.ts so it can be unit-tested without booting Deno.serve.

export interface Signer {
  name: string
  email: string
  company_name?: string
  signing_order: number
}

// Minimal shape buildSigners needs from a profile.
export interface SignerProfile {
  first_name: string
  last_name: string
  email: string
}

export const EMPLOYEE_SIGNING_ORDER = 1
export const HR_SIGNING_ORDER = 2

function toSigner(profile: SignerProfile, signingOrder: number, companyName?: string): Signer {
  return {
    name: `${profile.first_name} ${profile.last_name}`.trim(),
    email: profile.email,
    // company_name labels the employer-side signer (the HR/employer rep signs
    // on behalf of the company). Purely a role marker — verified against the
    // eSignatures sandbox: two signers with the same email are NOT merged with
    // or without it, so the two-signer guarantee does not depend on this.
    ...(companyName ? { company_name: companyName } : {}),
    signing_order: signingOrder,
  }
}

/**
 * Builds the eSignatures signer list for a bike-benefit contract.
 *
 * The contract is a two-party agreement: the employee (beneficiary, order 1)
 * and the company's HR (employer representative, order 2). BOTH signature
 * blocks must always be present — even when the requesting employee is also
 * the company's HR (one user_id holding both the `employee` and `hr` roles,
 * a supported multi-role case). Emitting a single signer in that case drops
 * the employer signature and leaves the contract legally incomplete, so we
 * always produce both entries. Both carry company_name (both parties belong
 * to the company); the order/role is what distinguishes them.
 */
export function buildSigners(
  employee: SignerProfile,
  hr: SignerProfile,
  companyName: string,
): Signer[] {
  const signers: Signer[] = []
  if (employee.email && employee.first_name) {
    signers.push(toSigner(employee, EMPLOYEE_SIGNING_ORDER, companyName))
  }
  if (hr.email && hr.first_name) {
    signers.push(toSigner(hr, HR_SIGNING_ORDER, companyName))
  }
  return signers
}
