// TBI Bank eCommerce API client — credential loading, payload building, API submission.

import type { RestClient } from "./supabaseRest.ts"

// ─── Vault secret names ─────────────────────────────────────────────────────

export const TBI_VAULT_KEYS = {
  USERNAME: "tbi_username",
  PASSWORD: "tbi_password",
  STORE_ID: "tbi_store_id",           // same value used as providerCode per TBI docs
  PUBLIC_KEY: "tbi_public_key",
  PRIVATE_KEY: "tbi_private_key",
} as const

// ─── Types ──────────────────────────────────────────────────────────────────
// Matches TBI eCommerce API Documentation (2. eCommerce - API Documentation.doc)

export interface TbiCredentials {
  username: string
  password: string
  storeId: string            // same value as providerCode per TBI docs
}

export interface TbiCustomer {
  fname: string              // mandatory
  lname: string              // mandatory
  cnp: string                // national ID (CNP) — mandatory
  email: string              // mandatory
  phone: string              // mandatory
  billing_address: string
  billing_city: string
  billing_county: string
  shipping_address: string
  shipping_city: string
  shipping_county: string
  instalments: string        // number of instalments as string
  promo: number              // 0 or 1 — whether product has interest
}

export interface TbiOrderItem {
  name: string               // mandatory
  qty: string                // quantity as string (TBI format)
  price: number              // mandatory
  category: string           // product category
  sku: string                // product SKU
  imagelink: string          // product image URL (visible on internet)
}

export interface TbiOrderData {
  store_id: string           // must match providerCode
  order_id: string
  back_ref: string           // webhook callback URL
  order_total: string        // total as string (TBI format)
  username: string
  password: string
  customer: TbiCustomer
  items: TbiOrderItem[]
}

export interface TbiCancelData {
  orderId: string            // TBI uses camelCase for cancel
  statusId: string           // always "1" per TBI docs
  username: string
  password: string
}

// ─── Credential loading ─────────────────────────────────────────────────────
// Production: env vars first. Staging/local: Vault fallback.

async function getSecret(db: RestClient, envKey: string, vaultKey: string): Promise<string | null> {
  const envVal = Deno.env.get(envKey)
  if (envVal) return envVal
  return db.rpc<string | null>("get_vault_secret", { secret_name: vaultKey })
}

export async function loadTbiCredentials(db: RestClient): Promise<TbiCredentials> {
  const [username, password, storeId] = await Promise.all([
    getSecret(db, "TBI_USERNAME", TBI_VAULT_KEYS.USERNAME),
    getSecret(db, "TBI_PASSWORD", TBI_VAULT_KEYS.PASSWORD),
    getSecret(db, "TBI_STORE_ID", TBI_VAULT_KEYS.STORE_ID),
  ])

  if (!username || !password || !storeId) {
    throw new Error("Missing TBI credentials — check env vars or Vault secrets")
  }

  return { username, password, storeId }
}

export async function loadTbiPublicKey(db: RestClient): Promise<string> {
  const key = await db.rpc<string | null>("get_vault_secret", { secret_name: TBI_VAULT_KEYS.PUBLIC_KEY })
  if (!key) throw new Error("TBI public key not found in Vault")
  return key
}

export async function loadTbiPrivateKey(db: RestClient): Promise<string> {
  const key = await db.rpc<string | null>("get_vault_secret", { secret_name: TBI_VAULT_KEYS.PRIVATE_KEY })
  if (!key) throw new Error("TBI private key not found in Vault")
  return key
}

// ─── Payload builders ───────────────────────────────────────────────────────

export interface TbiProfileData {
  first_name: string
  last_name: string
  email: string
  phone: string
  cnp: string                // national ID from employee_pii
  home_address?: string      // for billing/shipping
  home_city?: string
  home_county?: string
}

export function buildTbiPayload(
  credentials: TbiCredentials,
  profile: TbiProfileData,
  bikeName: string,
  orderTotal: number,
  orderId: string,
  instalments: number,
  webhookUrl: string,
): TbiOrderData {
  return {
    store_id: credentials.storeId,
    order_id: orderId,
    back_ref: webhookUrl,
    order_total: String(orderTotal),
    username: credentials.username,
    password: credentials.password,
    customer: {
      fname: profile.first_name,
      lname: profile.last_name,
      cnp: profile.cnp,
      email: profile.email,
      phone: profile.phone,
      billing_address: profile.home_address ?? "",
      billing_city: profile.home_city ?? "",
      billing_county: profile.home_county ?? "",
      shipping_address: profile.home_address ?? "",
      shipping_city: profile.home_city ?? "",
      shipping_county: profile.home_county ?? "",
      instalments: String(instalments),
      promo: 0,
    },
    items: [{
      name: bikeName,
      qty: "1",
      price: orderTotal,
      category: "2",
      sku: orderId,
      imagelink: "",
    }],
  }
}

export function buildTbiCancelPayload(
  credentials: TbiCredentials,
  orderId: string,
): TbiCancelData {
  return {
    orderId,
    statusId: "1",
    username: credentials.username,
    password: credentials.password,
  }
}

// ─── API submission ─────────────────────────────────────────────────────────

function getTbiApiUrl(): string {
  return Deno.env.get("TBI_API_URL") ?? "https://ecommerce.tbibank.ro/Api/LoanApplication"
}

export async function submitLoanApplication(
  encryptedData: string,
  storeId: string,
): Promise<{ redirectUrl: string }> {
  const apiUrl = `${getTbiApiUrl()}/Finalize`

  // TBI docs: params are "order_data" and "providerCode"
  // providerCode = store_id (same value per docs)
  const res = await fetch(apiUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    redirect: "manual",
    body: `order_data=${encodeURIComponent(encryptedData)}&providerCode=${encodeURIComponent(storeId)}`,
  })

  // TBI returns 301 with redirect URL in Location header
  if (res.status === 301 || res.status === 302) {
    const redirectUrl = res.headers.get("location")
    if (!redirectUrl) throw new Error("TBI returned redirect without Location header")
    return { redirectUrl }
  }

  if (res.status === 401) {
    throw new Error("TBI API: 401 Unauthorized — credentials missing or wrong (case sensitive)")
  }

  const detail = await res.text().catch(() => "")
  throw new Error(`TBI API error: ${res.status} ${detail}`)
}

export async function submitCancellation(
  encryptedData: string,
  storeId: string,
): Promise<{ isSuccess: boolean; error: string | null }> {
  const apiUrl = `${getTbiApiUrl()}/CanceledByCustomer`

  // TBI cancel docs: params are "orderData" and "encryptCode"
  // encryptCode = store_id/providerCode (same value)
  const res = await fetch(apiUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `orderData=${encodeURIComponent(encryptedData)}&encryptCode=${encodeURIComponent(storeId)}`,
  })

  if (!res.ok) {
    const detail = await res.text().catch(() => "")
    return { isSuccess: false, error: `TBI cancel error: ${res.status} ${detail}` }
  }

  const data = await res.json().catch(() => ({}))
  return { isSuccess: data.isSuccess ?? true, error: data.error ?? null }
}

// ─── Status mapping ─────────────────────────────────────────────────────────

export type TbiLoanStatus = "pending" | "approved" | "rejected" | "canceled"

export function mapTbiStatus(statusId: number, motiv?: string): TbiLoanStatus {
  if (statusId === 1) return "approved"
  if (statusId === 0 && motiv) return "rejected"
  if (statusId === 0) return "canceled"
  if (statusId === 2) return "pending"
  return "pending"
}

export function loanStatusMessage(status: TbiLoanStatus, motiv?: string): string {
  switch (status) {
    case "approved": return "Your loan has been approved! Your e-bike is on its way."
    case "rejected": return motiv ? `Loan not approved: ${motiv}` : "Your loan application was not approved."
    case "canceled": return "Your loan application has been canceled."
    case "pending": return "Your loan application is being processed."
  }
}
