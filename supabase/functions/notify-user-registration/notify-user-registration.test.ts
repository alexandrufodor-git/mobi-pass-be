// Unit tests for notify-user-registration edge function.
// Run with: deno test --allow-env supabase/functions/notify-user-registration/notify-user-registration.test.ts

import { assertEquals } from "jsr:@std/assert"
import { stub } from "jsr:@std/testing/mock"

// ─── Helpers ─────────────────────────────────────────────────────────────────

const VALID_SECRET = "test-webhook-secret-abc123"

function makeEnvStub(secret: string | undefined) {
  return stub(Deno.env, "get", (key: string): string | undefined => {
    if (key === "BROADCAST_WEBHOOK_SECRET") return secret
    if (key === "SUPABASE_URL") return "https://test.supabase.co"
    if (key === "SUPABASE_SERVICE_ROLE_KEY") return "test-service-key"
    return undefined
  })
}

function makeRequest(
  body: unknown,
  secret?: string,
  method = "POST",
): Request {
  return new Request("https://test.supabase.co/functions/v1/notify-user-registration", {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(secret ? { "x-webhook-secret": secret } : {}),
    },
    body: JSON.stringify(body),
  })
}

// Import the handler by loading the module. We stub fetch before importing
// so sendBroadcast never hits the network.
async function loadHandler() {
  const mod = await import("./index.ts")
  return mod.default
}

// ─── Tests ───────────────────────────────────────────────────────────────────

Deno.test("notify-user-registration: non-POST returns 405", async () => {
  const envStub = makeEnvStub(VALID_SECRET)
  const fetchStub = stub(globalThis, "fetch", () => {
    throw new Error("fetch must not be called")
  })
  try {
    const { default: handler } = await import("./index.ts")
    const res = await handler(makeRequest({}, VALID_SECRET, "GET"))
    assertEquals(res.status, 405)
  } finally {
    envStub.restore()
    fetchStub.restore()
  }
})

Deno.test("notify-user-registration: missing secret header returns 401", async () => {
  const envStub = makeEnvStub(VALID_SECRET)
  const fetchStub = stub(globalThis, "fetch", () => {
    throw new Error("fetch must not be called")
  })
  try {
    const { default: handler } = await import("./index.ts")
    const res = await handler(makeRequest({ company_id: "c", user_id: "u", employee_name: "Jane" }))
    assertEquals(res.status, 401)
  } finally {
    envStub.restore()
    fetchStub.restore()
  }
})

Deno.test("notify-user-registration: wrong secret returns 401", async () => {
  const envStub = makeEnvStub(VALID_SECRET)
  const fetchStub = stub(globalThis, "fetch", () => {
    throw new Error("fetch must not be called")
  })
  try {
    const { default: handler } = await import("./index.ts")
    const res = await handler(makeRequest(
      { company_id: "c", user_id: "u", employee_name: "Jane" },
      "wrong-secret",
    ))
    assertEquals(res.status, 401)
  } finally {
    envStub.restore()
    fetchStub.restore()
  }
})

Deno.test("notify-user-registration: missing fields returns 400", async () => {
  const envStub = makeEnvStub(VALID_SECRET)
  const fetchStub = stub(globalThis, "fetch", () =>
    Promise.resolve(new Response("{}", { status: 200 }))
  )
  try {
    const { default: handler } = await import("./index.ts")
    const res = await handler(makeRequest(
      { user_id: "u", employee_name: "Jane" }, // missing company_id
      VALID_SECRET,
    ))
    assertEquals(res.status, 400)
    const body = await res.json()
    assertEquals(body.error, "missing_fields")
  } finally {
    envStub.restore()
    fetchStub.restore()
  }
})

Deno.test("notify-user-registration: happy path calls broadcast with correct payload", async () => {
  const envStub = makeEnvStub(VALID_SECRET)
  const broadcastCalls: { url: string; body: unknown }[] = []

  const fetchStub = stub(
    globalThis,
    "fetch",
    (input: unknown, init?: unknown): Promise<Response> => {
      const url = String(input instanceof Request ? input.url : input)
      const options = init as RequestInit | undefined
      broadcastCalls.push({
        url,
        body: options?.body ? JSON.parse(options.body as string) : null,
      })
      return Promise.resolve(new Response("{}", { status: 200 }))
    },
  )

  try {
    const { default: handler } = await import("./index.ts")
    const res = await handler(makeRequest(
      { company_id: "company-uuid-001", user_id: "user-uuid-001", employee_name: "Jane Doe" },
      VALID_SECRET,
    ))

    assertEquals(res.status, 200)
    assertEquals(broadcastCalls.length, 1)
    assertEquals(broadcastCalls[0].url, "https://test.supabase.co/realtime/v1/api/broadcast")

    const msg = (broadcastCalls[0].body as { messages: { topic: string; event: string; payload: Record<string, unknown> }[] })
    assertEquals(msg.messages[0].topic, "notifications:company-uuid-001")
    assertEquals(msg.messages[0].event, "user_update")
    assertEquals(msg.messages[0].payload.event_type, "created")
    assertEquals(msg.messages[0].payload.user_id, "user-uuid-001")
    assertEquals(msg.messages[0].payload.employee_name, "Jane Doe")
  } finally {
    envStub.restore()
    fetchStub.restore()
  }
})

Deno.test("notify-user-registration: returns 200 even when broadcast fetch fails", async () => {
  const envStub = makeEnvStub(VALID_SECRET)
  const fetchStub = stub(
    globalThis,
    "fetch",
    (): Promise<Response> => Promise.resolve(new Response("error", { status: 500 })),
  )
  try {
    const { default: handler } = await import("./index.ts")
    const res = await handler(makeRequest(
      { company_id: "c", user_id: "u", employee_name: "Jane" },
      VALID_SECRET,
    ))
    // sendBroadcast logs on non-ok but does not throw — handler still returns 200
    assertEquals(res.status, 200)
  } finally {
    envStub.restore()
    fetchStub.restore()
  }
})

Deno.test("notify-user-registration: no BROADCAST_WEBHOOK_SECRET env var returns 401", async () => {
  const envStub = makeEnvStub(undefined) // secret not configured
  const fetchStub = stub(globalThis, "fetch", () => {
    throw new Error("fetch must not be called")
  })
  try {
    const { default: handler } = await import("./index.ts")
    const res = await handler(makeRequest(
      { company_id: "c", user_id: "u", employee_name: "Jane" },
      VALID_SECRET,
    ))
    assertEquals(res.status, 401)
  } finally {
    envStub.restore()
    fetchStub.restore()
  }
})
