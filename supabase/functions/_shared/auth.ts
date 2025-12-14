// supabase/functions/_shared/auth.ts

import { invalidJwt } from "./constants.ts"

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

