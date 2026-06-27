// scripts/dev/ors-check.ts
//
// Tier-1 smoke test for the CO₂ engine's distance routing. Exercises the REAL
// code path the edge functions use (routeDistanceKm / haversineKm / estimateRouteKm
// from _shared/commute.ts) against a sample home→office pair, so it validates
// the OpenRouteService key, reachability, response parsing, and that the routed
// distance is sane vs the haversine fallback.
//
// The key is read from the env var only — never hard-code it:
//   read -s ORS_KEY && OPENROUTESERVICE_API_KEY=$ORS_KEY \
//     deno run --allow-net --allow-env scripts/dev/ors-check.ts
//
// Optionally override the test coords:
//   --home=<lat,lon> --office=<lat,lon>

import {
  routeDistanceKm,
  haversineKm,
  estimateRouteKm,
} from "../../supabase/functions/_shared/commute.ts"

function coordArg(name: string, fallback: [number, number]): [number, number] {
  const raw = Deno.args.find((a) => a.startsWith(`--${name}=`))?.split("=")[1]
  if (!raw) return fallback
  const [lat, lon] = raw.split(",").map(Number)
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
    console.error(`bad --${name} (expected lat,lon): ${raw}`)
    Deno.exit(1)
  }
  return [lat, lon]
}

const key = Deno.env.get("OPENROUTESERVICE_API_KEY")
if (!key) {
  console.error("OPENROUTESERVICE_API_KEY not set. Run:\n  read -s ORS_KEY && OPENROUTESERVICE_API_KEY=$ORS_KEY deno run --allow-net --allow-env scripts/dev/ors-check.ts")
  Deno.exit(1)
}

// Defaults: a Cluj-Napoca home → office pair.
const [hLat, hLon] = coordArg("home", [46.7600, 23.5800])
const [oLat, oLon] = coordArg("office", [46.7712, 23.6236])

const straight = haversineKm(hLat, hLon, oLat, oLon)
const estimate = estimateRouteKm(straight)
const routed = await routeDistanceKm(key, hLat, hLon, oLat, oLon)

console.log("home   :", hLat, hLon)
console.log("office :", oLat, oLon)
console.log("─".repeat(40))
console.log("haversine (straight) km :", +straight.toFixed(3))
console.log("estimate  (×1.3)     km :", +estimate.toFixed(3))
console.log("routed    (ORS car)  km :", routed == null ? "NULL (ORS failed → would fall back)" : +routed.toFixed(3))
console.log("─".repeat(40))

if (routed == null) {
  console.error("❌ ORS returned no route — check the key / quota / coords.")
  Deno.exit(2)
}
const ratio = routed / straight
console.log(`✅ routing works. routed/straight = ${ratio.toFixed(2)} (expect ~1.2–1.6 for real roads)`)
