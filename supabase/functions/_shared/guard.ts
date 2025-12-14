// supabase/functions/_shared/guards.ts

import { requireJwt } from "./auth.ts"
import { UserRole, UserRoles, forbidden } from "./constants.ts"

export async function requireRole(
  req: Request,
  supabaseUrl: string,
  serviceKey: string,
  authorisedRoles: UserRole[] = [UserRoles.HR, UserRoles.ADMIN],
  origin?: string
) {
  const jwt = requireJwt(req, origin)

  // Check if user's role is in the authorised roles
  const hasRole = authorisedRoles.some(role => role === jwt.user_role)
  if (!hasRole) {
    throw forbidden(undefined, origin)
  }

  // DB verification fallback (user has 1 role)
  const roles = authorisedRoles.join(",")
  const res = await fetch(
    `${supabaseUrl}/rest/v1/user_roles?user_id=eq.${jwt.sub}&role=in.(${roles})`,
    {
      headers: {
        Authorization: `Bearer ${serviceKey}`,
        apikey: serviceKey,
      },
    }
  )

  if (!res.ok) {
    throw forbidden(undefined, origin)
  }

  const data = await res.json()
  if (!data.length) {
    throw forbidden(undefined, origin)
  }

  return jwt
}
