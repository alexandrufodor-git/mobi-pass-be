// supabase/functions/_shared/guards.ts

import { requireJwt } from "./auth.ts"
import { UserRole, UserRoles, forbidden } from "./constants.ts"

export async function requireRole(
  req: Request,
  supabaseUrl: string,
  serviceKey: string,
  authorisedRoles: UserRole[] = [UserRoles.HR, UserRoles.ADMIN]
) {
  const jwt = requireJwt(req)

  // Check if user's role is in the authorised roles
  const hasRole = authorisedRoles.some(role => role === jwt.user_role)
  if (!hasRole) {
    throw forbidden()
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
    throw forbidden()
  }

  const data = await res.json()
  if (!data.length) {
    throw forbidden()
  }

  return jwt
}
