// supabase/functions/_shared/commute.ts
//
// Commute distance estimation for the company CO₂ / CSRD engine.
//
// This is the ONLY place the distance is computed. It runs in the edge runtime
// because it needs the employee's *plaintext* home coordinates, which are only
// decryptable here (Vault `pii_encryption_key`, see piiCrypto.ts). Postgres
// never sees plaintext coords, so the recurring CO₂ aggregation works off the
// derived scalar `employee_pii.commute_distance_km` this module produces.
//
// Distance source:
//   • DEFAULT — `estimated`: haversine × DETOUR_FACTOR. No external dependency,
//     no API caps, $0, infinitely scalable. Identical to mobile's calc
//     (mobi-pass `RouteEstimations.kt`). This sits in the GHG-Protocol-accepted
//     estimation tier for Scope-3 Cat-7 and is the v1 default.
//   • OPT-IN — `routed`: real road distance from an OpenRouteService endpoint,
//     used ONLY when `ors_base_url` is configured (Vault or env). Intended for a
//     SELF-HOSTED ORS (no caps); the public hosted ORS works too but is rate-
//     limited (40/min, 2000/day). When no base URL is set, routing is off and
//     every distance is `estimated` — so there is no external dependency by
//     default. Flip the whole fleet to routed later by setting one config value.
//
// The chosen source is recorded per row in employee_pii.commute_distance_source
// for CSRD auditability. The remaining factors (round-trip ×2, workdays/month,
// emission factor) are applied later in the SQL aggregation, not here — this
// module owns ONLY the one-way distance.

import type { RestClient } from "./supabaseRest.ts"

/** Straight-line → road-distance multiplier for the estimate. Mirrors mobile's DETOUR_FACTOR. */
export const DETOUR_FACTOR = 1.3

const EARTH_RADIUS_KM = 6371

// OpenRouteService (opt-in). Routing is enabled iff a base URL is configured;
// point it at a self-hosted instance to avoid the public-tier caps.
const ORS_PROFILE = "driving-car"
const ORS_BASE_VAULT = "ors_base_url"
const ORS_KEY_VAULT = "ors_api_key"
const ORS_KEY_VAULT_LEGACY = "openrouteservice_api_key"
const ORS_BASE_ENV = "ORS_BASE_URL"
const ORS_KEY_ENV = "ORS_API_KEY"

export type CommuteSource = "routed" | "estimated"
export interface CommuteResult {
  km: number
  source: CommuteSource
}

function toRad(deg: number): number {
  return (deg * Math.PI) / 180
}

function round3(n: number): number {
  return Math.round(n * 1000) / 1000
}

/** Great-circle distance between two WGS84 points, in kilometres. */
export function haversineKm(aLat: number, aLon: number, bLat: number, bLon: number): number {
  const dLat = toRad(bLat - aLat)
  const dLon = toRad(bLon - aLon)
  const lat1 = toRad(aLat)
  const lat2 = toRad(bLat)

  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.sin(dLon / 2) ** 2 * Math.cos(lat1) * Math.cos(lat2)
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.sqrt(h))
}

/** Apply the detour factor to a straight-line distance → estimated road distance. */
export function estimateRouteKm(straightLineKm: number): number {
  return straightLineKm * DETOUR_FACTOR
}

interface OrsConfig {
  baseUrl: string
  apiKey: string | null
}

/**
 * ORS endpoint config, or `null` when routing is disabled (no base URL set).
 * Base URL: Vault `ors_base_url` → env `ORS_BASE_URL`. Optional key:
 * Vault `ors_api_key` (legacy `openrouteservice_api_key`) → env `ORS_API_KEY`.
 */
async function loadOrsConfig(db: RestClient): Promise<OrsConfig | null> {
  const baseUrl =
    (await db.rpc<string | null>("get_vault_secret", { secret_name: ORS_BASE_VAULT })) ??
    Deno.env.get(ORS_BASE_ENV) ??
    null
  if (!baseUrl) return null // routing off → estimate

  const apiKey =
    (await db.rpc<string | null>("get_vault_secret", { secret_name: ORS_KEY_VAULT })) ??
    (await db.rpc<string | null>("get_vault_secret", { secret_name: ORS_KEY_VAULT_LEGACY })) ??
    Deno.env.get(ORS_KEY_ENV) ??
    null

  return { baseUrl: baseUrl.replace(/\/+$/, ""), apiKey }
}

/**
 * Road distance (km) home→office from an ORS endpoint, or `null` on any failure
 * (so the caller falls back to the estimate). ORS expects lon,lat order.
 */
export async function routeDistanceKm(
  cfg: OrsConfig,
  aLat: number,
  aLon: number,
  bLat: number,
  bLon: number,
): Promise<number | null> {
  const url = new URL(`${cfg.baseUrl}/v2/directions/${ORS_PROFILE}`)
  url.searchParams.set("start", `${aLon},${aLat}`)
  url.searchParams.set("end", `${bLon},${bLat}`)
  if (cfg.apiKey) url.searchParams.set("api_key", cfg.apiKey)
  try {
    const res = await fetch(url, { headers: { Accept: "application/geo+json" } })
    if (!res.ok) {
      console.warn(`[commute] ORS ${res.status} — falling back to estimate`)
      return null
    }
    const gj = await res.json()
    const meters = gj?.features?.[0]?.properties?.summary?.distance
    return typeof meters === "number" ? meters / 1000 : null
  } catch (e) {
    console.warn("[commute] ORS request failed — falling back to estimate:", e)
    return null
  }
}

/**
 * One-way commute distance (km) home→office with its provenance, or `null` if
 * any coordinate is missing. Uses the haversine×detour estimate by default;
 * routes via ORS only when an endpoint is configured (and falls back to the
 * estimate if that call fails). Exactly what gets persisted to
 * employee_pii.commute_distance_km (+ _source).
 */
export async function commuteDistanceKm(
  db: RestClient,
  homeLat: number | null | undefined,
  homeLon: number | null | undefined,
  officeLat: number | null | undefined,
  officeLon: number | null | undefined,
): Promise<CommuteResult | null> {
  if (homeLat == null || homeLon == null || officeLat == null || officeLon == null) {
    return null
  }

  const cfg = await loadOrsConfig(db)
  if (cfg) {
    const routed = await routeDistanceKm(cfg, homeLat, homeLon, officeLat, officeLon)
    if (routed != null) return { km: round3(routed), source: "routed" }
  }

  return { km: round3(estimateRouteKm(haversineKm(homeLat, homeLon, officeLat, officeLon))), source: "estimated" }
}
