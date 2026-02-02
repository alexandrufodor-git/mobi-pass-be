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
  // When deployed, the path is "/" but locally it might be "/bulk-create"
  if ((path === "/bulk-create" || path === "/") && method === "POST") {
    const csv = await getCsvFromRequest(req)
    
    // Define the CSV row type with all possible fields
    interface CsvRow {
      email: string
      firstName: string
      lastName: string
      description?: string
      department?: string
      hireDate?: string
    }
    
    // Parse CSV - email, firstName, and lastName are required
    const rows = parseCsv<CsvRow>(csv, ["email", "firstName", "lastName"])

    const results: Array<{
      email: string
      invited: boolean,
      status?: string
      error?: string
      body?: unknown
    }> = []

    for (const r of rows) {
      // Validate email format
      if (!r.email?.includes("@")) {
        results.push({ email: r.email, invited: false, error: "invalid_email" })
        continue
      }

      // Validate required fields
      if (!r.firstName?.trim()) {
        results.push({ email: r.email, invited: false, error: "missing_first_name" })
        continue
      }
      if (!r.lastName?.trim()) {
        results.push({ email: r.email, invited: false, error: "missing_last_name" })
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

      // --- prepare invite data ---
      // Convert hireDate string to bigint (epoch milliseconds)
      let hireDateValue: number | null = null
      if (r.hireDate && r.hireDate.trim()) {
        const dateStr = r.hireDate.trim()
        
        // Try parsing as epoch timestamp first
        const parsedNum = parseInt(dateStr, 10)
        if (!isNaN(parsedNum) && parsedNum > 0) {
          hireDateValue = parsedNum
        } else {
          // Try parsing as date string (e.g., "1 Jan 2020", "2020-01-01")
          const parsedDate = new Date(dateStr)
          if (!isNaN(parsedDate.getTime())) {
            hireDateValue = parsedDate.getTime()
          }
        }
      }

      // Build the invite payload - firstName and lastName are required
      const inviteData: Record<string, unknown> = {
        email: r.email,
        company_id: companyId,
        first_name: r.firstName.trim(),
        last_name: r.lastName.trim()
      }

      // Add optional fields only if they have values
      if (r.description && r.description.trim()) {
        inviteData.description = r.description.trim()
      }
      if (r.department && r.department.trim()) {
        inviteData.department = r.department.trim()
      }
      if (hireDateValue !== null) {
        inviteData.hire_date = hireDateValue
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
        body: JSON.stringify(inviteData),
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
