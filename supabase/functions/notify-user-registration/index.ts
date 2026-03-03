// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { sendBroadcast } from "../_shared/broadcast.ts"

// Called exclusively by the handle_user_registration DB trigger via pg_net.
// Protected by a shared secret (x-webhook-secret header) + Supabase internal URL.
// verify_jwt: false — trigger cannot produce a JWT.

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response(null, { status: 405 })

  // Verify shared secret — rejects any caller that doesn't know it
  const secret = Deno.env.get("BROADCAST_WEBHOOK_SECRET")
  if (!secret || req.headers.get("x-webhook-secret") !== secret) {
    return new Response(null, { status: 401 })
  }

  const { company_id, user_id, employee_name } = await req.json()
  if (!company_id || !user_id || !employee_name) {
    return new Response(JSON.stringify({ error: "missing_fields" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  await sendBroadcast(
    `notifications:${company_id}`,
    "user_update",
    { user_id, employee_name, event_type: "created" },
  )

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  })
})
