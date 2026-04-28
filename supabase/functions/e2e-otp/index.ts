// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts"

/**
 * e2e-otp — Returns a usable OTP for a test email.
 *
 * Request: POST with X-E2E-Secret header.
 *   Body: { email: "e2e-register@mobipass.test" }
 *
 * Implementation: calls Supabase admin `generate_link` (type: magiclink),
 * which returns a fresh `email_otp` the client can verify with verifyOtp().
 * This invalidates any previous OTP issued for the same email — which is
 * fine for tests that only care about the last-issued code.
 *
 * Allowlist: email must end with @mobipass.test. Any other email → 403.
 *
 * Vault secret: e2e_secret (matches X-E2E-Secret header).
 */

const TEST_DOMAIN = "mobipass.test"

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

async function getVaultSecret(name: string): Promise<string | null> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_vault_secret`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      apikey: SERVICE_ROLE_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ secret_name: name }),
  })
  if (!res.ok) return null
  return (await res.json()) as string | null
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  })

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405)

  const E2E_SECRET = (await getVaultSecret("e2e_secret")) ?? ""
  if (!E2E_SECRET) return json({ error: "e2e_not_configured" }, 503)
  if (req.headers.get("X-E2E-Secret") !== E2E_SECRET) {
    return json({ error: "forbidden" }, 403)
  }

  let body: { email?: string }
  try { body = await req.json() } catch { return json({ error: "invalid_json" }, 400) }

  const email = body.email?.trim().toLowerCase()
  if (!email) return json({ error: "email_required" }, 400)
  if (!email.endsWith(`@${TEST_DOMAIN}`)) {
    return json({ error: "email_not_allowlisted" }, 403)
  }

  // Generate a fresh OTP via admin API. The response includes email_otp as plaintext.
  const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/generate_link`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      apikey: SERVICE_ROLE_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ type: "magiclink", email }),
  })

  if (!res.ok) {
    const details = await res.text()
    console.error("[e2e-otp] generate_link failed:", res.status, details)
    return json({ error: "generate_link_failed", status: res.status }, 500)
  }

  const data = await res.json() as {
    properties?: { email_otp?: string; hashed_token?: string; action_link?: string }
  }
  const otp = data.properties?.email_otp
  if (!otp) {
    console.error("[e2e-otp] no email_otp in response:", data)
    return json({ error: "otp_not_returned" }, 500)
  }

  return json({ email, otp })
})
