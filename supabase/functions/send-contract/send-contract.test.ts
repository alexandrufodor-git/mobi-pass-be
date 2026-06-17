// Unit tests for send-contract signer construction.
// Run with: deno test --allow-env supabase/functions/send-contract/send-contract.test.ts

import { assertEquals } from "jsr:@std/assert"
import { buildSigners, SignerProfile } from "./signers.ts"

// ─── Helpers ─────────────────────────────────────────────────────────────────

function profile(over: Partial<SignerProfile> = {}): SignerProfile {
  return {
    first_name: "Jane",
    last_name: "Doe",
    email: "jane@company.com",
    ...over,
  }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

Deno.test("buildSigners: distinct employee and HR → two signers in order", () => {
  const employee = profile({ first_name: "Jane", last_name: "Doe", email: "jane@company.com" })
  const hr = profile({ first_name: "Hank", last_name: "Ross", email: "hr@company.com" })

  const signers = buildSigners(employee, hr, "BigTech1")

  assertEquals(signers.length, 2)
  assertEquals(signers[0].email, "jane@company.com")
  assertEquals(signers[0].signing_order, 1)
  assertEquals(signers[0].company_name, "BigTech1") // both parties belong to the company
  assertEquals(signers[1].email, "hr@company.com")
  assertEquals(signers[1].signing_order, 2)
  assertEquals(signers[1].company_name, "BigTech1")
})

Deno.test("buildSigners: employee IS the HR (same account) → still two signers, differentiated", () => {
  const same = profile({ first_name: "Jane", last_name: "Doe", email: "jane@company.com" })

  // Both roles resolve to the same person/email (multi-role user).
  const signers = buildSigners(same, same, "BigTech1")

  // The legal requirement: both the beneficiary and the employer signature
  // blocks must exist even though one human holds both roles.
  assertEquals(signers.length, 2)
  assertEquals(signers[0].signing_order, 1)
  assertEquals(signers[1].signing_order, 2)
  // Same inbox, two signing roles. eSignatures keeps both same-email signers
  // (verified against the sandbox), so the employer signature block survives.
  assertEquals(signers[0].email, signers[1].email)
  assertEquals(signers[0].company_name, "BigTech1")
  assertEquals(signers[1].company_name, "BigTech1")
})

Deno.test("buildSigners: signer missing email/first_name is skipped", () => {
  const employee = profile({ email: "jane@company.com" })
  const hr = profile({ first_name: "", email: "" })

  const signers = buildSigners(employee, hr, "BigTech1")

  assertEquals(signers.length, 1)
  assertEquals(signers[0].email, "jane@company.com")
})

Deno.test("buildSigners: name is trimmed first+last", () => {
  const employee = profile({ first_name: "Jane", last_name: "Doe" })
  const hr = profile({ first_name: "Hank", last_name: "Ross", email: "hr@company.com" })

  const signers = buildSigners(employee, hr, "BigTech1")

  assertEquals(signers[0].name, "Jane Doe")
  assertEquals(signers[1].name, "Hank Ross")
})
