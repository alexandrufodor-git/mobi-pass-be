// Supabase Realtime Broadcast helper.
// Sends topic-based messages via the REST API (no client SDK required).

export async function sendBroadcast(
  topic: string,
  event: string,
  payload: Record<string, unknown>,
): Promise<void> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

  const res = await fetch(`${supabaseUrl}/realtime/v1/api/broadcast`, {
    method: "POST",
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      messages: [{ topic, event, payload }],
    }),
  })

  if (!res.ok) {
    const detail = await res.text().catch(() => "")
    console.error("[broadcast] failed:", res.status, detail)
  } else {
    console.log("[broadcast] sent to topic:", topic, "event:", event)
  }
}
