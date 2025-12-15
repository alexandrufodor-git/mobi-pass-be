// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { requireRole } from "../_shared/guard.ts"
import { Errors, UserRoles, badRequest, json } from "../_shared/constants.ts"
import { corsResponse } from "../_shared/ioHelpers.ts"

/**
 * Register Edge Function - Passwordless Sign-in via OTP
 * 
 * This function implements passwordless authentication using OTP (One-Time Password).
 * 
 * Flow:
 * 1. User provides their email
 * 2. System checks if user has an invite in profile_invites table
 * 3. If invited, sends an OTP to their email (magic link OR 6-digit code)
 * 4. User receives email with OTP
 * 5. User verifies OTP on client side using supabase.auth.verifyOtp()
 * 
 * IMPORTANT - To send 6-digit OTP codes instead of magic links:
 * 1. Go to: Supabase Dashboard → Authentication → Email Templates
 * 2. Edit the "Magic Link" template
 * 3. Replace the magic link with: {{ .Token }}
 * 
 * Example email template for OTP codes:
 * ```html
 * <h2>Your Login Code</h2>
 * <p>Enter this code to sign in: <strong>{{ .Token }}</strong></p>
 * <p>This code expires in 60 seconds.</p>
 * ```
 * 
 * Client-side verification example:
 * ```javascript
 * const { data, error } = await supabase.auth.verifyOtp({
 *   email: 'user@example.com',
 *   token: '123456', // 6-digit code from email
 *   type: 'email'
 * })
 * ```
 * 
 * Configuration:
 * - OTP codes are valid for 60 seconds by default (configurable in Dashboard)
 * - Users can request OTP once every 60 seconds (rate limit)
 * - Emails are sent via your configured email provider in Supabase
 */

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || undefined

  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return corsResponse(origin)
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

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
  // By default this sends a magic link, but if you configure the email template
  // to include {{ .Token }}, it will send a 6-digit OTP code instead
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

  const otpData = await otpRes.json()

  return json({ 
    success: true, 
    message: "OTP sent to email",
    email: email,
    // Note: The actual OTP is only sent via email for security
    // It will be either a magic link or 6-digit code depending on your email template
  }, 200, origin)
})

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/register' \
    --header 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0' \
    --header 'Content-Type: application/json' \
    --data '{"email":"user@example.com"}'

  Expected response:
  {
    "success": true,
    "message": "OTP code sent to email",
    "email": "user@example.com"
  }

  The user will receive a 6-digit OTP code in their email.
  They can then verify it using the Supabase client:
  
  supabase.auth.verifyOtp({ email, token, type: 'email' })

*/
