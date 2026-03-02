// Unit tests for the FCM helper (supabase/functions/_shared/fcm.ts).
// Run with: deno test --allow-env supabase/functions/_shared/fcm.test.ts

import { assertEquals } from "jsr:@std/assert"
import { stub } from "jsr:@std/testing/mock"
import { sendFcm, type FcmNotification } from "./fcm.ts"
import type { RestClient } from "./supabaseRest.ts"

// ─── Test helpers ────────────────────────────────────────────────────────────

/**
 * Generates a minimal service account JSON string with a real RSA-2048 key
 * so that the JWT signing path in getAccessToken() can execute without error.
 */
async function makeServiceAccountJson(tokenUri = "https://oauth2.googleapis.com/token"): Promise<string> {
  const kp = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]) },
    true,
    ["sign", "verify"],
  )
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", kp.privateKey)
  const b64 = btoa(String.fromCharCode(...new Uint8Array(pkcs8)))
  return JSON.stringify({
    client_email: "svc@test-proj.iam.gserviceaccount.com",
    token_uri: tokenUri,
    private_key: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----`,
  })
}

/**
 * Builds a mock RestClient where rpc() returns values in call order:
 *   call 0 → firebase_project_id vault secret (or null)
 *   call 1 → firebase_service_account vault secret (or null)
 */
function makeMockDb(
  rpcReturns: (string | null)[],
  getOneReturn: unknown = null,
): RestClient {
  let rpcCall = 0
  return {
    getOne: () => Promise.resolve(getOneReturn as never),
    post: () => Promise.resolve(new Response(null, { status: 201 })),
    patch: () => Promise.resolve(),
    rpc: () => {
      const val = rpcReturns[rpcCall++] ?? null
      return Promise.resolve(val as never)
    },
  }
}

const NOTIFICATION: FcmNotification = {
  title: "Contract Ready",
  body: "Your contract is ready to sign.",
  event: "contract_ready",
  bikeBenefitId: "benefit-uuid-001",
}

// ─── Tests ───────────────────────────────────────────────────────────────────

Deno.test("sendFcm: returns early when firebase_project_id vault secret is missing", async () => {
  const fetchStub = stub(
    globalThis,
    "fetch",
    (_input: unknown, _init?: unknown) => { throw new Error("fetch must not be called") },
  )
  try {
    // rpc returns null for firebase_project_id
    const db = makeMockDb([null])
    await sendFcm(db, "user-uuid", NOTIFICATION) // must not throw
  } finally {
    fetchStub.restore()
  }
})

Deno.test("sendFcm: returns early when profile is not found", async () => {
  const fetchStub = stub(
    globalThis,
    "fetch",
    (_input: unknown, _init?: unknown) => { throw new Error("fetch must not be called") },
  )
  try {
    // rpc returns project ID; getOne returns null (no profile)
    const db = makeMockDb(["test-project"], null)
    await sendFcm(db, "user-uuid", NOTIFICATION)
  } finally {
    fetchStub.restore()
  }
})

Deno.test("sendFcm: returns early when fcm_token is null", async () => {
  const fetchStub = stub(
    globalThis,
    "fetch",
    (_input: unknown, _init?: unknown) => { throw new Error("fetch must not be called") },
  )
  try {
    const db = makeMockDb(["test-project"], { fcm_token: null })
    await sendFcm(db, "user-uuid", NOTIFICATION)
  } finally {
    fetchStub.restore()
  }
})

Deno.test("sendFcm: returns early when firebase_service_account vault secret is missing", async () => {
  const fetchStub = stub(
    globalThis,
    "fetch",
    (_input: unknown, _init?: unknown) => { throw new Error("fetch must not be called") },
  )
  try {
    // rpc: project ID ok, service account null
    const db = makeMockDb(["test-project", null], { fcm_token: "device-token" })
    await sendFcm(db, "user-uuid", NOTIFICATION)
  } finally {
    fetchStub.restore()
  }
})

Deno.test("sendFcm: returns early when firebase_service_account vault secret is not valid JSON", async () => {
  const fetchStub = stub(
    globalThis,
    "fetch",
    (_input: unknown, _init?: unknown) => { throw new Error("fetch must not be called") },
  )
  try {
    // Simulate vault storing only the raw PEM key instead of the full service account JSON
    const db = makeMockDb(["test-project", "-----BEGIN PRIVATE KEY-----\nnotvalidjson"], { fcm_token: "device-token" })
    await sendFcm(db, "user-uuid", NOTIFICATION)
  } finally {
    fetchStub.restore()
  }
})

Deno.test("sendFcm: returns early when Google token exchange fails", async () => {
  const svcAccount = await makeServiceAccountJson()
  let fcmCalled = false

  const fetchStub = stub(
    globalThis,
    "fetch",
    (input: unknown, _init?: unknown): Promise<Response> => {
      const url = String(input instanceof Request ? input.url : input)
      if (url.includes("oauth2.googleapis.com")) {
        return Promise.resolve(new Response("Unauthorized", { status: 401 }))
      }
      fcmCalled = true
      return Promise.resolve(new Response("{}", { status: 200 }))
    },
  )
  try {
    const db = makeMockDb(["test-project", svcAccount], { fcm_token: "device-token" })
    await sendFcm(db, "user-uuid", NOTIFICATION)
    assertEquals(fcmCalled, false, "FCM endpoint must not be called when token exchange fails")
  } finally {
    fetchStub.restore()
  }
})

Deno.test("sendFcm: sends push with correct payload on happy path", async () => {
  const svcAccount = await makeServiceAccountJson()
  const fcmCalls: { url: string; headers: Record<string, string>; body: unknown }[] = []

  const fetchStub = stub(
    globalThis,
    "fetch",
    (input: unknown, init?: unknown): Promise<Response> => {
      const url = String(input instanceof Request ? input.url : input)
      const options = init as RequestInit | undefined
      if (url.includes("oauth2.googleapis.com")) {
        return Promise.resolve(
          new Response(JSON.stringify({ access_token: "ya29.test-token" }), { status: 200 }),
        )
      }
      if (url.includes("fcm.googleapis.com")) {
        fcmCalls.push({
          url,
          headers: Object.fromEntries(new Headers(options?.headers as HeadersInit).entries()),
          body: options?.body ? JSON.parse(options.body as string) : null,
        })
        return Promise.resolve(new Response("{}", { status: 200 }))
      }
      throw new Error(`Unexpected fetch call: ${url}`)
    },
  )
  try {
    const db = makeMockDb(["test-project", svcAccount], { fcm_token: "device-token-xyz" })
    await sendFcm(db, "user-uuid", NOTIFICATION)

    assertEquals(fcmCalls.length, 1, "FCM must be called exactly once")
    assertEquals(
      fcmCalls[0].url,
      "https://fcm.googleapis.com/v1/projects/test-project/messages:send",
    )
    assertEquals(fcmCalls[0].headers["authorization"], "Bearer ya29.test-token")

    const msg = (fcmCalls[0].body as { message: Record<string, unknown> }).message
    assertEquals(msg.token, "device-token-xyz")
    assertEquals((msg.notification as Record<string, string>).title, NOTIFICATION.title)
    assertEquals((msg.notification as Record<string, string>).body, NOTIFICATION.body)
    assertEquals((msg.data as Record<string, string>).event, "contract_ready")
    assertEquals((msg.data as Record<string, string>).bike_benefit_id, "benefit-uuid-001")
  } finally {
    fetchStub.restore()
  }
})

Deno.test("sendFcm: handles FCM API error gracefully without throwing", async () => {
  const svcAccount = await makeServiceAccountJson()

  const fetchStub = stub(
    globalThis,
    "fetch",
    (input: unknown, _init?: unknown): Promise<Response> => {
      const url = String(input instanceof Request ? input.url : input)
      if (url.includes("oauth2.googleapis.com")) {
        return Promise.resolve(
          new Response(JSON.stringify({ access_token: "ya29.test-token" }), { status: 200 }),
        )
      }
      // FCM returns UNREGISTERED — stale token
      return Promise.resolve(new Response("UNREGISTERED", { status: 404 }))
    },
  )
  try {
    const db = makeMockDb(["test-project", svcAccount], { fcm_token: "stale-token" })
    // Must complete without throwing
    await sendFcm(db, "user-uuid", NOTIFICATION)
  } finally {
    fetchStub.restore()
  }
})
