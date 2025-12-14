// supabase/functions/_shared/constants.ts

export const UserRoles = {
  ADMIN: "admin",
  HR: "hr",
  EMPLOYEE: "employee",
} as const

export type UserRole = typeof UserRoles[keyof typeof UserRoles]

// Centralized error responses
export const Errors = {
  // Auth errors
  FORBIDDEN: { error: "forbidden", reason: "no_permission_to_access_this_data" },
  INVALID_JWT: { error: "invalid_jwt" },
  ROLE_LOOKUP_FAILED: { error: "role_lookup_failed" },
  // IO/parsing errors
  MISSING_BOUNDARY: { error: "missing_boundary" },
  NO_FILE: { error: "no_file" },
  EMPTY_CSV: { error: "empty_csv" },
  NO_ROWS: { error: "no_rows" },
  MISSING_HEADER: { error: "missing_header" },
  // General
  NOT_FOUND: { error: "not_found" },
  // Registration
  NOT_INVITED: { error: "not_invited" },
  EMAIL_REQUIRED: { error: "email_required" },
  OTP_FAILED: { error: "otp_send_failed" },
} as const

export function forbidden(error = Errors.FORBIDDEN): Response {
  return new Response(
    JSON.stringify({ error: error.error, reason: error.reason }),
    { status: 403, headers: { "content-type": "application/json" } }
  )
}

export function invalidJwt(error = Errors.INVALID_JWT): Response {
  return new Response(
    JSON.stringify({ error: error.error }),
    { status: 401, headers: { "content-type": "application/json" } }
  )
}

export function roleLookupFailed(error = Errors.ROLE_LOOKUP_FAILED): Response {
  return new Response(
    JSON.stringify({ error: error.error }),
    { status: 500, headers: { "content-type": "application/json" } }
  )
}

export function badRequest(error: { error: string }, extra?: Record<string, unknown>): Response {
  return new Response(
    JSON.stringify({ ...error, ...extra }),
    { status: 400, headers: { "content-type": "application/json" } }
  )
}

export function notFound(path?: string): Response {
  return new Response(
    JSON.stringify({ ...Errors.NOT_FOUND, ...(path && { path }) }),
    { status: 404, headers: { "content-type": "application/json" } }
  )
}

export function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  })
}