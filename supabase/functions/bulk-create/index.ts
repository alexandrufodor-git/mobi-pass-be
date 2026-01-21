/// <reference types="https://deno.land/x/types/index.d.ts" />
console.info("bulk-create starting")

import { requireRole } from "../_shared/guard.ts"
import { Errors, badRequest, notFound, json } from "../_shared/constants.ts"
import { getCsvFromRequest, parseCsv, corsResponse } from "../_shared/ioHelpers.ts"

// Main edge function
Deno.serve(async (req: Request) => {
  const url = new URL(req.url)
  const path = url.pathname
  const method = req.method
  const origin = req.headers.get("origin") || undefined

  // Handle CORS preflight
  if (method === "OPTIONS") {
    return corsResponse(origin)
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

  const jwt = await requireRole(req, SUPABASE_URL, SERVICE_KEY, undefined, origin)

  // Fetch the company_id from the logged-in HR user's profile
  const profileRes = await fetch(
    `${SUPABASE_URL}/rest/v1/profiles?user_id=eq.${jwt.sub}&select=company_id`,
    {
      headers: {
        Authorization: `Bearer ${SERVICE_KEY}`,
        apikey: SERVICE_KEY,
      },
    }
  )

  if (!profileRes.ok) {
    return json(Errors.PROFILE_FETCH_FAILED, 500, origin)
  }

  const profiles = await profileRes.json()
  if (!profiles || profiles.length === 0) {
    return json(Errors.PROFILE_NOT_FOUND, 404, origin)
  }

  const companyId = profiles[0].company_id
  if (!companyId) {
    return badRequest(Errors.NO_COMPANY, undefined, origin)
  }

  // --- handle bulk-create ---
  if (path === "/bulk-create" && method === "POST") {
    const csv = await getCsvFromRequest(req)
    const rows = parseCsv<{ email: string }>(csv, ["email"])

    const results: Array<{
      email: string
      invited: boolean,
      status?: string
      error?: string
      body?: unknown
    }> = []

    for (const r of rows) {
      if (!r.email?.includes("@")) {
        results.push({ email: r.email, invited: false, error: "invalid_email" })
        continue
      }

      // --- check if email already exists ---
      const checkRes = await fetch(
        `${SUPABASE_URL}/rest/v1/profile_invites?email=eq.${encodeURIComponent(r.email)}`,
        {
          headers: {
            Authorization: `Bearer ${SERVICE_KEY}`,
            apikey: SERVICE_KEY,
            "Content-Type": "application/json",
          },
        }
      )

      const existing = await checkRes.json()
      if (existing.length > 0) {
        results.push({ email: r.email, invited: false, status: "already_exists" })
        continue
      }

      // --- insert new profile invite ---
      const insertRes = await fetch(`${SUPABASE_URL}/rest/v1/profile_invites`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${SERVICE_KEY}`,
          apikey: SERVICE_KEY,
          "Content-Type": "application/json",
          Prefer: "return=representation",
        },
        body: JSON.stringify({
          email: r.email,
          company_id: companyId
        }),
      })

      const newProfile = await insertRes.json()
      results.push({
        email: r.email,
        invited: true,
        body: newProfile,
      })
    }

    return json({ created: results.length, results }, 200, origin)
  }

  return notFound(path, origin)
})
