/// <reference types="https://deno.land/x/types/index.d.ts" />
console.info("bulk-create starting")

import { requireRole } from "../_shared/guard.ts"
import { Errors, badRequest, notFound } from "../_shared/constants.ts"
import { json, getCsvFromRequest, parseCsv } from "../_shared/ioHelpers.ts"

// Main edge function
Deno.serve(async (req: Request) => {
  const url = new URL(req.url)
  const path = url.pathname
  const method = req.method

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

  const jwt = await requireRole(req, SUPABASE_URL, SERVICE_KEY)

  // --- handle bulk-create ---
  if (path === "/bulk-create" && method === "POST") {
    const csv = await getCsvFromRequest(req)
    const rows = parseCsv<{ email: string }>(csv, ["email"])

    const results: Array<{
      email: string
      ok: boolean
      status?: string
      error?: string
      body?: unknown
    }> = []

    for (const r of rows) {
      if (!r.email?.includes("@")) {
        results.push({ email: r.email, ok: false, error: "invalid_email" })
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
        results.push({ email: r.email, ok: true, status: "already_exists" })
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
        }),
      })

      const newProfile = await insertRes.json()
      results.push({
        email: r.email,
        ok: insertRes.ok,
        status: insertRes.ok ? "created" : "error",
        body: newProfile,
      })
    }

    return json({ created: results.length, results })
  }

  return notFound(path)
})
