// Inserts a row into company_notifications.
// Realtime postgres_changes delivers it to subscribed HR dashboard clients.

import { RestClient } from "./supabaseRest.ts"

export async function sendNotification(
  db: RestClient,
  companyId: string,
  event: string,
  eventType: string,
  payload: Record<string, unknown>,
): Promise<void> {
  const res = await db.post("company_notifications", {
    company_id: companyId,
    event,
    event_type: eventType,
    payload,
  })
  if (!res.ok) {
    const detail = await res.text().catch(() => "")
    console.error("[notifications] insert failed:", res.status, detail)
  }
}
