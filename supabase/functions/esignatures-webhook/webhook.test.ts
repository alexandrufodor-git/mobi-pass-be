// Unit tests for EsigToContractStatus mapping used in esignatures-webhook.
// Run with: deno test --allow-env supabase/functions/esignatures-webhook/webhook.test.ts

import { assertEquals } from "jsr:@std/assert"
import { EsigToContractStatus, EsigEvents } from "../_shared/constants.ts"

Deno.test("EsigToContractStatus: signer-viewed-the-contract maps to viewed_by_employee", () => {
  assertEquals(EsigToContractStatus[EsigEvents.VIEWED], "viewed_by_employee")
})

Deno.test("EsigToContractStatus: signer-signed maps to signed_by_employee", () => {
  assertEquals(EsigToContractStatus[EsigEvents.SIGNED], "signed_by_employee")
})

Deno.test("EsigToContractStatus: signer-declined maps to declined_by_employee", () => {
  assertEquals(EsigToContractStatus[EsigEvents.DECLINED], "declined_by_employee")
})

Deno.test("EsigToContractStatus: unknown event falls back to raw event string", () => {
  const raw = "some-unknown-event"
  const result = EsigToContractStatus[raw] ?? raw
  assertEquals(result, raw)
})

Deno.test("EsigToContractStatus: contract-signed is not mapped (HR-only event)", () => {
  assertEquals(EsigToContractStatus[EsigEvents.CONTRACT_SIGNED], undefined)
})

Deno.test("EsigToContractStatus: contract-withdrawn is not mapped (logged only)", () => {
  assertEquals(EsigToContractStatus[EsigEvents.WITHDRAWN], undefined)
})
