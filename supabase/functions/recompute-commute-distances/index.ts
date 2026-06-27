// supabase/functions/recompute-commute-distances/index.ts
//
// Recomputes employee_pii.commute_distance_km in bulk. Two uses:
//   1. Backfill — populate the scalar for employees whose home coords predate
//      the CO₂ engine (Phase 2, one-shot after deploy).
//   2. Office move — when a company's address_lat/lon changes, every employee's
//      stored distance is stale; pass { company_id } to recompute just that
//      tenant.
//
// Like update-employee-pii, this is the only place the distance is derived: it
// decrypts each home coord in-runtime (Vault key), computes against the
// company office coords, and persists the scalar. Plaintext coords are never
// logged or returned.
//
// Auth: admin role (JWT) or service_role bearer. Idempotent.
//
// Distance defaults to the haversine estimate (no external calls). If ORS
// routing is enabled (ors_base_url configured), this loop self-throttles the
// routed calls via min_interval_ms (default ~37/min) to respect the public ORS
// free-tier cap (40/min, 2000/day). Self-hosted ORS has no caps → pass
// min_interval_ms: 0. The throttle is a no-op while routing is off.
//
// Body (all optional):
//   { company_id?: string, batch_size?: number, dry_run?: boolean, min_interval_ms?: number }
//
// Response:
//   { scanned, computed, cleared, unchanged, dry_run }
//     computed   = rows written with a numeric distance
//     cleared    = rows written NULL (missing home or office coords)
//     unchanged  = rows whose distance already matched (no write)

import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { UserRoles, json } from "../_shared/constants.ts"
import { decodeJwt } from "../_shared/auth.ts"
import { requireRole } from "../_shared/guard.ts"
import { makeRestClient } from "../_shared/supabaseRest.ts"
import { decrypt } from "../_shared/piiCrypto.ts"
import { commuteDistanceKm } from "../_shared/commute.ts"

interface PiiRow {
  id: string
  company_id: string
  commute_distance_km: number | null
  home_lat_encrypted: string | null
  home_lon_encrypted: string | null
}

interface CompanyCoords {
  id: string
  address_lat: number | null
  address_lon: number | null
}

const authHeaders = (serviceKey: string) => ({
  Authorization: `Bearer ${serviceKey}`,
  apikey: serviceKey,
})

async function decryptCoord(db: ReturnType<typeof makeRestClient>, enc: string | null): Promise<number | null> {
  if (enc == null || enc === "") return null
  const n = parseFloat(await decrypt(db, enc))
  return Number.isFinite(n) ? n : null
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method_not_allowed", { status: 405 })

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

  const authHeader = req.headers.get("authorization") ?? ""
  const bearer = authHeader.replace(/^Bearer /i, "")
  const isServiceRole = bearer === serviceKey || decodeJwt(authHeader)?.role === "service_role"
  if (!isServiceRole) {
    try {
      await requireRole(req, supabaseUrl, serviceKey, [UserRoles.ADMIN])
    } catch (e) {
      if (e instanceof Response) return e
      throw e
    }
  }

  const db = makeRestClient(supabaseUrl, serviceKey)

  let body: { company_id?: string; batch_size?: number; dry_run?: boolean; min_interval_ms?: number } = {}
  try { body = await req.json() } catch { /* empty body is fine */ }

  const batchSize = Math.min(Math.max(body.batch_size ?? 200, 1), 1000)
  const dryRun = body.dry_run === true
  // Throttle ORS Directions calls to stay under the free-tier 40 req/min cap.
  // Default 1600ms between routed calls ≈ 37/min. 0 disables (e.g. self-hosted ORS).
  const minIntervalMs = Math.min(Math.max(body.min_interval_ms ?? 1600, 0), 10000)
  const companyFilter = body.company_id
    ? `&company_id=eq.${encodeURIComponent(body.company_id)}`
    : ""

  // Office coords for every (filtered) company, fetched once.
  const companyQs = body.company_id ? `&id=eq.${encodeURIComponent(body.company_id)}` : ""
  const companiesRes = await fetch(
    `${supabaseUrl}/rest/v1/companies?select=id,address_lat,address_lon${companyQs}`,
    { headers: authHeaders(serviceKey) },
  )
  if (!companiesRes.ok) {
    const text = await companiesRes.text().catch(() => "")
    throw new Error(`Failed to fetch companies: ${companiesRes.status} ${text}`)
  }
  const offices = new Map<string, CompanyCoords>()
  for (const c of (await companiesRes.json()) as CompanyCoords[]) offices.set(c.id, c)

  let scanned = 0, computed = 0, cleared = 0, unchanged = 0, offset = 0

  while (true) {
    const cols = "id,company_id,commute_distance_km,home_lat_encrypted,home_lon_encrypted"
    const res = await fetch(
      `${supabaseUrl}/rest/v1/employee_pii?select=${cols}&user_id=not.is.null${companyFilter}` +
        `&order=id.asc&limit=${batchSize}&offset=${offset}`,
      { headers: authHeaders(serviceKey) },
    )
    if (!res.ok) {
      const text = await res.text().catch(() => "")
      throw new Error(`Failed to fetch employee_pii batch: ${res.status} ${text}`)
    }
    const rows = (await res.json()) as PiiRow[]
    if (rows.length === 0) break
    scanned += rows.length
    offset += rows.length

    for (const row of rows) {
      const office = offices.get(row.company_id)
      const homeLat = await decryptCoord(db, row.home_lat_encrypted)
      const homeLon = await decryptCoord(db, row.home_lon_encrypted)
      const result = await commuteDistanceKm(db, homeLat, homeLon, office?.address_lat ?? null, office?.address_lon ?? null)
      const km = result?.km ?? null

      // Pace actual ORS calls to respect the 40 req/min free-tier limit.
      if (result?.source === "routed" && minIntervalMs > 0) {
        await new Promise((r) => setTimeout(r, minIntervalMs))
      }

      // Skip the write when the stored value already matches (cheap re-run).
      const same = (km == null && row.commute_distance_km == null) ||
        (km != null && row.commute_distance_km != null &&
          Math.abs(km - Number(row.commute_distance_km)) < 1e-9)
      if (same) { unchanged++; continue }

      if (!dryRun) {
        await db.patch("employee_pii", `id=eq.${encodeURIComponent(row.id)}`, {
          commute_distance_km: km,
          commute_distance_source: result?.source ?? null,
          commute_distance_computed_at: new Date().toISOString(),
        })
      }
      if (km == null) cleared++; else computed++
    }

    if (rows.length < batchSize) break
  }

  const counts = { scanned, computed, cleared, unchanged, dry_run: dryRun }
  console.log("[recompute-commute-distances] completed:", JSON.stringify(counts))
  return json(counts, 200)
})
