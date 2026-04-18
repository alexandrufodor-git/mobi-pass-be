// supabase/functions/admin-encrypt-pii/index.ts
//
// One-shot backfill: walks `employee_pii`, encrypts every *_encrypted column
// value that lacks the `enc:v1:` marker. Idempotent — re-running is safe.
//
// Auth: admin role (JWT-verified + DB fallback via requireRole).
//
// Body (all optional):
//   {
//     batch_size?: number,   // default 100, max 500
//     dry_run?:   boolean    // default false — when true, counts but doesn't UPDATE
//   }
//
// Response:
//   {
//     scanned:   number,     // rows read
//     encrypted: number,     // field-level writes actually performed
//     skipped:   number,     // field-level values already encrypted
//     updated_rows: number,  // rows that had at least one field encrypted
//     dry_run:   boolean
//   }

import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { UserRoles, json } from "../_shared/constants.ts"
import { decodeJwt } from "../_shared/auth.ts"
import { requireRole } from "../_shared/guard.ts"
import { makeRestClient } from "../_shared/supabaseRest.ts"
import { encrypt, isEncrypted } from "../_shared/piiCrypto.ts"

const ENCRYPTED_COLUMNS = [
  "national_id_encrypted",
  "date_of_birth_encrypted",
  "phone_encrypted",
  "home_address_encrypted",
  "home_lat_encrypted",
  "home_lon_encrypted",
  "salary_gross_encrypted",
] as const

type EncCol = typeof ENCRYPTED_COLUMNS[number]

interface PiiRow {
  id: string
  national_id_encrypted: string | null
  date_of_birth_encrypted: string | null
  phone_encrypted: string | null
  home_address_encrypted: string | null
  home_lat_encrypted: string | null
  home_lon_encrypted: string | null
  salary_gross_encrypted: string | null
}

async function fetchBatch(
  supabaseUrl: string,
  serviceKey: string,
  limit: number,
  offset: number,
): Promise<PiiRow[]> {
  const cols = ["id", ...ENCRYPTED_COLUMNS].join(",")
  const res = await fetch(
    `${supabaseUrl}/rest/v1/employee_pii?select=${cols}&order=id.asc&limit=${limit}&offset=${offset}`,
    {
      headers: {
        Authorization: `Bearer ${serviceKey}`,
        apikey: serviceKey,
      },
    }
  )
  if (!res.ok) {
    const text = await res.text().catch(() => "")
    throw new Error(`Failed to fetch employee_pii batch: ${res.status} ${text}`)
  }
  return res.json()
}

async function writeRowUpdate(
  supabaseUrl: string,
  serviceKey: string,
  rowId: string,
  patch: Record<string, string>,
): Promise<void> {
  const res = await fetch(
    `${supabaseUrl}/rest/v1/employee_pii?id=eq.${encodeURIComponent(rowId)}`,
    {
      method: "PATCH",
      headers: {
        Authorization: `Bearer ${serviceKey}`,
        apikey: serviceKey,
        "Content-Type": "application/json",
        Prefer: "return=minimal",
      },
      body: JSON.stringify(patch),
    }
  )
  if (!res.ok) {
    const text = await res.text().catch(() => "")
    throw new Error(`Failed to update employee_pii ${rowId}: ${res.status} ${text}`)
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("method_not_allowed", { status: 405 })
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

  const authHeader = req.headers.get("authorization") ?? ""
  const bearer = authHeader.replace(/^Bearer /i, "")
  const isServiceRole =
    bearer === serviceKey || decodeJwt(authHeader)?.role === "service_role"

  if (!isServiceRole) {
    try {
      await requireRole(req, supabaseUrl, serviceKey, [UserRoles.ADMIN])
    } catch (e) {
      if (e instanceof Response) return e
      throw e
    }
  }

  const db = makeRestClient(supabaseUrl, serviceKey)

  let body: { batch_size?: number; dry_run?: boolean } = {}
  try {
    body = await req.json()
  } catch { /* empty body is fine */ }

  const batchSize = Math.min(Math.max(body.batch_size ?? 100, 1), 500)
  const dryRun = body.dry_run === true

  let scanned = 0
  let encrypted = 0
  let skipped = 0
  let updatedRows = 0
  let offset = 0

  while (true) {
    const rows = await fetchBatch(supabaseUrl, serviceKey, batchSize, offset)
    if (rows.length === 0) break
    scanned += rows.length
    offset += rows.length

    for (const row of rows) {
      const patch: Record<string, string> = {}
      for (const col of ENCRYPTED_COLUMNS as readonly EncCol[]) {
        const val = row[col]
        if (val == null || val === "") continue
        if (isEncrypted(val)) { skipped++; continue }
        const ciphertext = await encrypt(db, val)
        patch[col] = ciphertext
        encrypted++
      }
      if (Object.keys(patch).length > 0) {
        if (!dryRun) {
          await writeRowUpdate(supabaseUrl, serviceKey, row.id, patch)
        }
        updatedRows++
      }
    }

    if (rows.length < batchSize) break
  }

  const counts = { scanned, encrypted, skipped, updated_rows: updatedRows, dry_run: dryRun }
  console.log("[admin-encrypt-pii] completed:", JSON.stringify(counts))

  return json(counts, 200)
})
