// Firebase Cloud Messaging HTTP v1 helper.
// Uses service account JSON stored in Supabase Vault (no SDK required).

import { FIREBASE_VAULT_KEY, type NotificationEventType } from "./constants.ts"
import type { RestClient } from "./supabaseRest.ts"

// ─── Google OAuth2 token from service account ────────────────────────────────

function base64url(input: Uint8Array): string {
  let binary = ""
  for (const byte of input) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

async function getAccessToken(db: RestClient): Promise<string | null> {
  const raw = await db.rpc<string | null>("get_vault_secret", { secret_name: FIREBASE_VAULT_KEY })
  if (!raw) {
    console.error("[fcm] vault secret not found:", FIREBASE_VAULT_KEY)
    return null
  }

  let sa: Record<string, string>
  try {
    sa = typeof raw === "string" ? JSON.parse(raw) : raw as Record<string, string>
  } catch {
    console.error("[fcm] firebase_service_account vault secret is not valid JSON — store the full service account JSON downloaded from Google Cloud Console")
    return null
  }

  const now = Math.floor(Date.now() / 1000)
  const header = base64url(new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })))
  const claims = base64url(new TextEncoder().encode(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: sa.token_uri,
    iat: now,
    exp: now + 3600,
  })))

  // Import RSA private key
  const pemBody = sa.private_key
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s/g, "")
  const keyBytes = Uint8Array.from(atob(pemBody), (c: string) => c.charCodeAt(0))
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  )

  const sigInput = new TextEncoder().encode(`${header}.${claims}`)
  const sig = base64url(new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", cryptoKey, sigInput)))
  const jwt = `${header}.${claims}.${sig}`

  // Exchange JWT for access token
  const res = await fetch(sa.token_uri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  })

  if (!res.ok) {
    console.error("[fcm] token exchange failed:", res.status, await res.text())
    return null
  }

  const data = await res.json()
  return data.access_token as string
}

// ─── Send FCM push ──────────────────────────────────────────────────────────

export interface FcmNotification {
  title: string
  body: string
  event: NotificationEventType
  bikeBenefitId: string
}

export async function sendFcm(
  db: RestClient,
  userId: string,
  notification: FcmNotification,
): Promise<void> {
  const projectId = await db.rpc<string | null>("get_vault_secret", { secret_name: "firebase_project_id" })
  if (!projectId) {
    console.error("[fcm] firebase_project_id vault secret not found")
    return
  }

  // Look up FCM token
  const profile = await db.getOne<{ fcm_token: string | null }>(
    "profiles",
    `user_id=eq.${encodeURIComponent(userId)}`,
    "fcm_token",
  )
  if (!profile?.fcm_token) {
    console.log("[fcm] no fcm_token for user:", userId)
    return
  }

  const accessToken = await getAccessToken(db)
  if (!accessToken) return

  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token: profile.fcm_token,
          notification: { title: notification.title, body: notification.body },
          data: { event: notification.event, bike_benefit_id: notification.bikeBenefitId },
        },
      }),
    },
  )

  if (!res.ok) {
    const detail = await res.text().catch(() => "")
    console.error("[fcm] send failed:", res.status, detail)
  } else {
    console.log("[fcm] sent to user:", userId)
  }
}
