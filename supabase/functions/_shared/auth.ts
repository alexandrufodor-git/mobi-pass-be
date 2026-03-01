// supabase/functions/_shared/auth.ts

import { invalidJwt } from "./constants.ts"

// Supabase Auth always issues UUIDs as the subject claim.
// Validating the format blocks any attempt to inject PostgREST operators
// or URL special characters via a crafted JWT sub.
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function decodeJwt(token: string | null): any | null {
  if (!token) return null

  try {
    const raw = token.replace(/^Bearer /i, "")
    const parts = raw.split(".")
    if (parts.length !== 3) return null

    const payload = parts[1]
    const decoded = atob(payload.replace(/-/g, "+").replace(/_/g, "/"))

    return JSON.parse(decoded)
  } catch {
    return null
  }
}

export function requireJwt(req: Request, origin?: string) {
  const authHeader = req.headers.get("authorization")
  const jwt = decodeJwt(authHeader)

  if (!jwt?.sub) {
    throw invalidJwt(undefined, origin)
  }

  return jwt
}

// Extracts and validates the user ID from a decoded JWT.
// Throws invalidJwt if sub is missing or not a valid UUID.
export function extractUserId(jwt: any, origin?: string): string {
  const sub = jwt?.sub
  if (typeof sub !== "string" || !UUID_REGEX.test(sub)) {
    throw invalidJwt(undefined, origin)
  }
  return sub
}

