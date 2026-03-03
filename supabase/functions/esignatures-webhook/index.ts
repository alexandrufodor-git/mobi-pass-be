// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { ESIGNATURES_VAULT_KEY, EsigEvents, EsigToContractStatus, NotificationEvent, UserRoles } from "../_shared/constants.ts"
import { makeRestClient, RestClient } from "../_shared/supabaseRest.ts"
import { sendFcm } from "../_shared/fcm.ts"
import { sendBroadcast } from "../_shared/broadcast.ts"

// Deployed with verify_jwt: false — authentication is via HMAC-SHA256 signature.

// ─── Constants ────────────────────────────────────────────────────────────────

// Maps eSignatures.com event names to the bike_benefit timestamp column(s) to set.
// Triggers derive contract_status automatically from these timestamps.
// terminated is not here — it is set manually by HR only.
const EVENT_TIMESTAMP_MAP: Record<string, Record<string, string>> = {
  [EsigEvents.VIEWED]:          { contract_viewed_at: "now" },
  [EsigEvents.SIGNED]:          { contract_employee_signed_at: "now" },
  [EsigEvents.DECLINED]:        { contract_declined_at: "now" },
  [EsigEvents.CONTRACT_SIGNED]: { contract_employer_signed_at: "now", contract_approved_at: "now" },
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

async function computeHmac(body: string, apiKey: string): Promise<string> {
  const encoder = new TextEncoder()
  const keyData = await crypto.subtle.importKey(
    "raw",
    encoder.encode(apiKey),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  )
  const sigBuffer = await crypto.subtle.sign("HMAC", keyData, encoder.encode(body))
  return Array.from(new Uint8Array(sigBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
}

function parsePayload(body: string): { event: string; contractId: string; signerEmail: string | null } | null {
  try {
    const payload = JSON.parse(body)
    const event      = payload?.status as string | undefined
    const contractId = payload?.data?.contract?.id as string | undefined
    const signerEmail = (payload?.data?.signer?.email as string | undefined) ?? null
    if (!event || !contractId) return null
    return { event, contractId, signerEmail }
  } catch {
    return null
  }
}

// ─── Notifications ───────────────────────────────────────────────────────────

async function sendWebhookNotifications(
  db: RestClient,
  event: string,
  signerEmail: string,
  contract: { id: string; bike_benefit_id: string; user_id: string },
): Promise<void> {
  const signer = await db.getOne<{ user_id: string; company_id: string; first_name: string; last_name: string; user_roles: { role: string }[] }>(
    "profiles",
    `email=eq.${encodeURIComponent(signerEmail)}`,
    "user_id,company_id,first_name,last_name,user_roles(role)"
  )
  if (!signer) return

  const role = signer.user_roles?.[0]?.role

  if (role === UserRoles.HR) {
    // HR signed → notify employee via FCM only
    const notification = event === EsigEvents.SIGNED
      ? { title: "Contract Signed", body: "HR has signed your contract.", event: NotificationEvent.CONTRACT_SIGNED_HR, bikeBenefitId: contract.bike_benefit_id }
      : event === EsigEvents.CONTRACT_SIGNED
      ? { title: "Contract Approved", body: "Your contract has been fully approved!", event: NotificationEvent.CONTRACT_APPROVED, bikeBenefitId: contract.bike_benefit_id }
      : null

    if (notification) {
      sendFcm(db, contract.user_id, notification)
        .catch((err) => console.error("[webhook] fcm error:", err))
    }
  } else if (role === UserRoles.EMPLOYEE && signer.company_id) {
    // Employee acted → broadcast to HR dashboard only
    sendBroadcast(
      `notifications:${signer.company_id}`,
      "contract_update",
      {
        user_id: contract.user_id,
        employee_name: `${signer.first_name} ${signer.last_name}`.trim(),
        event_type: EsigToContractStatus[event] ?? event,
        contract_id: contract.id,
      },
    ).catch((err) => console.error("[webhook] broadcast error:", err))
  }
}

// ─── Handler ─────────────────────────────────────────────────────────────────

// Always return 200 to prevent eSignatures.com from retrying
const ok = () => new Response(JSON.stringify({ ok: true }), {
  status: 200,
  headers: { "Content-Type": "application/json" },
})

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response(null, { status: 405 })

  const db       = makeRestClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!)
  const bodyText = await req.text()

  // 1. Fetch API key from Vault
  const apiKey = await db.rpc<string | null>("get_vault_secret", { secret_name: ESIGNATURES_VAULT_KEY })
  if (!apiKey) {
    console.error("[webhook] vault secret not found:", ESIGNATURES_VAULT_KEY)
    return ok()
  }

  // 2. Verify HMAC signature
  const sigHeader = req.headers.get("x-signature-sha256") ?? ""
  const expectedHmac = await computeHmac(bodyText, apiKey)
  // eSignatures may send raw hex or "sha256=hex" — accept both
  const valid = sigHeader === expectedHmac || sigHeader === `sha256=${expectedHmac}`
  if (!valid) {
    console.error("[webhook] HMAC mismatch — received:", sigHeader.slice(0, 20) + "...", "expected:", expectedHmac.slice(0, 20) + "...")
    return ok()
  }

  // 3. Parse event + contract ID
  const parsed = parsePayload(bodyText)
  if (!parsed) {
    console.error("[webhook] could not parse payload:", bodyText.slice(0, 200))
    return ok()
  }
  console.log("[webhook] event:", parsed.event, "contractId:", parsed.contractId)

  // 4. Look up contract row
  const contract = await db.getOne<{ id: string; bike_benefit_id: string; user_id: string }>(
    "contracts",
    `esignatures_contract_id=eq.${encodeURIComponent(parsed.contractId)}`,
    "id,bike_benefit_id,user_id"
  )
  if (!contract) {
    console.error("[webhook] contract not found for esignatures_contract_id:", parsed.contractId)
    return ok()
  }

  // 5. Always log the event on the contracts row
  await db.patch("contracts", `id=eq.${contract.id}`, {
    last_webhook_event:   parsed.event,
    last_webhook_payload: JSON.parse(bodyText),
  })

  // 6. Set timestamp(s) on bike_benefits if this event maps to any
  const columns = EVENT_TIMESTAMP_MAP[parsed.event]
  if (columns) {
    const now = new Date().toISOString()
    const updates: Record<string, string> = {}
    for (const col of Object.keys(columns)) {
      updates[col] = now
    }
    await db.patch("bike_benefits", `id=eq.${contract.bike_benefit_id}`, updates)
    console.log("[webhook] updated bike_benefits columns:", Object.keys(updates).join(", "))
  } else {
    console.log("[webhook] event logged only (no timestamp mapping):", parsed.event)
  }

  // 7. Send notifications based on signer role
  if (parsed.signerEmail) {
    sendWebhookNotifications(db, parsed.event, parsed.signerEmail, contract)
      .catch((err) => console.error("[webhook] notification error:", err))
  }

  return ok()
})
