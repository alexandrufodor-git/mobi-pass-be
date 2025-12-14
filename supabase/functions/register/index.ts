// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { requireRole } from "../_shared/guard.ts"
import { Errors, UserRoles, badRequest, json } from "../_shared/constants.ts"
import { corsResponse } from "../_shared/ioHelpers.ts"

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || undefined

  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return corsResponse(origin)
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

  // Only employees can register
  await requireRole(req, SUPABASE_URL, SERVICE_KEY, [UserRoles.EMPLOYEE], origin)

  // Get email from request body
  const { email } = await req.json()
  if (!email) {
    return badRequest(Errors.EMAIL_REQUIRED, undefined, origin)
  }

  // Check if invite exists (case-insensitive)
  const inviteRes = await fetch(
    `${SUPABASE_URL}/rest/v1/profile_invites?email=ilike.${encodeURIComponent(email)}`,
    {
      headers: {
        Authorization: `Bearer ${SERVICE_KEY}`,
        apikey: SERVICE_KEY,
      },
    }
  )

  const invites = await inviteRes.json()
  if (!invites.length) {
    return json(Errors.NOT_INVITED, 403, origin)
  }

  // Send OTP via Supabase Auth
  const otpRes = await fetch(`${SUPABASE_URL}/auth/v1/otp`, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      email,
      create_user: true,
    }),
  })

  if (!otpRes.ok) {
    const error = await otpRes.json()
    return json({ ...Errors.OTP_FAILED, details: error }, 500, origin)
  }

  return json({ success: true, message: "OTP sent" }, 200, origin)
})

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/register' \
    --header 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0' \
    --header 'Content-Type: application/json' \
    --data '{"email":"user@example.com"}'

*/
