// Unit tests for the send-contract broadcast behaviour.
// Run with: deno test --allow-env supabase/functions/send-contract/send-contract.test.ts

import { assertEquals } from "jsr:@std/assert"
import { stub } from "jsr:@std/testing/mock"
import { sendBroadcast } from "../_shared/broadcast.ts"

// ─── Helpers ─────────────────────────────────────────────────────────────────

/** Captures fetch calls made by sendBroadcast. */
function captureBroadcastFetch(): {
  calls: { url: string; body: unknown }[]
  stub: ReturnType<typeof stub>
} {
  const calls: { url: string; body: unknown }[] = []
  const fetchStub = stub(
    globalThis,
    "fetch",
    (input: unknown, init?: unknown): Promise<Response> => {
      const url = String(input instanceof Request ? input.url : input)
      const options = init as RequestInit | undefined
      calls.push({ url, body: options?.body ? JSON.parse(options.body as string) : null })
      return Promise.resolve(new Response("{}", { status: 200 }))
    },
  )
  return { calls, stub: fetchStub }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

Deno.test("sendBroadcast: sends contract_update with event_type 'created' and correct contract_id", async () => {
  // Provide env vars expected by sendBroadcast
  const envStubs = [
    stub(Deno.env, "get", (key: string) => {
      if (key === "SUPABASE_URL") return "https://test.supabase.co"
      if (key === "SUPABASE_SERVICE_ROLE_KEY") return "test-service-key"
      return undefined
    }),
  ]

  const { calls, stub: fetchStub } = captureBroadcastFetch()
  try {
    await sendBroadcast(
      "notifications:company-uuid-001",
      "contract_update",
      {
        user_id: "user-uuid-001",
        employee_name: "Jane Doe",
        event_type: "created",
        contract_id: "contract-uuid-001",
      },
    )

    assertEquals(calls.length, 1)
    assertEquals(calls[0].url, "https://test.supabase.co/realtime/v1/api/broadcast")

    const body = calls[0].body as { messages: { topic: string; event: string; payload: Record<string, unknown> }[] }
    assertEquals(body.messages.length, 1)
    assertEquals(body.messages[0].topic, "notifications:company-uuid-001")
    assertEquals(body.messages[0].event, "contract_update")
    assertEquals(body.messages[0].payload.event_type, "created")
    assertEquals(body.messages[0].payload.contract_id, "contract-uuid-001")
    assertEquals(body.messages[0].payload.user_id, "user-uuid-001")
  } finally {
    fetchStub.restore()
    for (const s of envStubs) s.restore()
  }
})

Deno.test("sendBroadcast: broadcast error does not propagate when caught with .catch()", async () => {
  const envStubs = [
    stub(Deno.env, "get", (key: string) => {
      if (key === "SUPABASE_URL") return "https://test.supabase.co"
      if (key === "SUPABASE_SERVICE_ROLE_KEY") return "test-service-key"
      return undefined
    }),
  ]

  const fetchStub = stub(
    globalThis,
    "fetch",
    (_input: unknown, _init?: unknown): Promise<Response> => {
      return Promise.resolve(new Response("Internal Server Error", { status: 500 }))
    },
  )

  try {
    // sendBroadcast logs on non-ok but does not throw — must complete without error
    await sendBroadcast(
      "notifications:company-uuid-002",
      "contract_update",
      { user_id: "u", employee_name: "Test", event_type: "created", contract_id: "c" },
    ).catch(() => { /* swallowed, as in send-contract handler */ })
  } finally {
    fetchStub.restore()
    for (const s of envStubs) s.restore()
  }
  // If we reach here without throwing, the test passes
})
