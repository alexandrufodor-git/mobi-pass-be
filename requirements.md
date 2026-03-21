# mobi-pass Backend Requirements

## Overview
Supabase backend for a company bike benefit platform. Employees select, test, and commit to a subsidised e-bike. The process is tracked end-to-end from invite to delivery.

**Stack:** PostgreSQL · Edge Functions (Deno) · Supabase Vault

---

## Authentication
- Passwordless login via email OTP (magic link or 6-digit code).
- Employees must be pre-invited before they can register.
- Edge function: `register` — mobile app only, no CORS.

---

## User Management

### Roles
| Role | Access |
|------|--------|
| `admin` | Full access |
| `hr` | Manage employees, view all benefits, set terminal statuses |
| `employee` | Own data only |

Roles are stored in `user_roles` (FK → `profiles.user_id`). A profile must exist before a role can be assigned. The registration trigger creates the profile first, then inserts the `employee` role. HR roles are assigned manually.

### Profile Fields
`first_name`, `last_name`, `email`, `department`, `hire_date`, `description`, `company_id`, `onboarding_status`

### Bulk Invite
- HR uploads a CSV to create employee invites.
- Edge function: `bulk-create` — web frontend only, CORS required.

---

## Dealers
- Dealer info is stored in a separate `dealers` table (`name`, `address`, `location_coords`, `phone`).
- Each bike references a dealer via `dealer_id` (NOT NULL FK).
- The `bikes_with_my_pricing` view JOINs `dealers` to expose `dealer_name`, `dealer_address`, `dealer_location_coords`, and `dealer_phone`.
- RLS: all authenticated users can SELECT dealers (needed for test ride / pickup info).

## Bike Catalogue
- Bikes have: name, brand, type, full price, images, specs, `dealer_id` (FK → `dealers`).
- Employee price is calculated from company subsidy: `full_price − (monthly_subsidy × contract_months)`.

---

## Bike Benefit Workflow

### Steps
`choose_bike` → `book_live_test` → `commit_to_bike` → `sign_contract` → `pickup_delivery`

Resetting to `choose_bike` clears all subsequent timestamps and prices, **deletes** all related `bike_orders` and `contracts` rows, and resets `profiles.onboarding_status` to `false`.

### Benefit Status (trigger-derived)
| Status | Condition |
|--------|-----------|
| `inactive` | No step started |
| `searching` | `choose_bike` or `book_live_test` |
| `testing` | `commit_to_bike` + WhatsApp sent |
| `active` | `sign_contract` or later + committed |
| `insurance_claim` | Manual — HR only |
| `terminated` | Manual — HR only |

### Pricing Snapshot
`employee_full_price`, `employee_monthly_price`, `employee_contract_months` are calculated and locked at `commit_to_bike`. Cleared on reset to `choose_bike`.

### Onboarding Status
- `profiles.onboarding_status` (boolean, default `false`) tracks whether the employee has completed the bike benefit flow.
- Set to `true` when `delivered_at` transitions from NULL to non-NULL (bike delivered).
- Reset to `false` when the benefit is reset to `choose_bike`.

---

## Contract Management

### Flow
1. Employee calls `send-contract` (mobile app).
2. Backend calls eSignatures.com with employee and bike data.
3. Employee signs via link received by email.
4. eSignatures.com sends webhook events to `esignatures-webhook`.
5. Webhook sets timestamps on `bike_benefits`; triggers derive `contract_status`.

### Contract Status (trigger-derived from timestamps)
| Status | Timestamp set |
|--------|---------------|
| `pending` | `contract_requested_at` |
| `viewed_by_employee` | `contract_viewed_at` |
| `signed_by_employee` | `contract_employee_signed_at` |
| `signed_by_employer` | `contract_employer_signed_at` |
| `approved` | all three signed timestamps present |
| `declined_by_employee` | `contract_declined_at` — **not terminal**, new contract can be re-sent |
| `terminated` | Manual — HR only, **terminal** |

### Webhook Event Mapping
| eSignatures event | Timestamp set |
|-------------------|---------------|
| `signer-viewed-the-contract` | `contract_viewed_at` |
| `signer-signed` | `contract_employee_signed_at` |
| `signer-declined` | `contract_declined_at` |
| `contract-withdrawn` | — (logged only) |
| `contract-signed` | — (logged only) |

All events update `last_webhook_event` + `last_webhook_payload` on the `contracts` row.

**Payload structure:** `{ status, data: { contract: { id } } }` — contract ID is at `data.contract.id`, not top-level.

### Contract Record
Each `send-contract` call creates a row in the `contracts` table storing the eSignatures contract ID, signer ID, signing URL, full API response, and latest webhook payload.

### `send-contract` Implementation Notes
- Guards: bike selected, pricing committed (`employee_full_price` set), no existing `contract_requested_at`.
- Signers: employee (order 1) + HR of same company (order 2).
- On success: sets `contract_requested_at`, advances `step` to `pickup_delivery`, returns `sign_page_url` to app.
- Inserts into `company_notifications` with `event_type: "created"` so HR dashboard is notified immediately.
- Currently calls eSignatures in **test mode** (`test: true` hardcoded).

### eSignatures Placeholder Fields
`first_name`, `last_name`, `email`, `department`, `hire_date`, `company_name`, `bike_name`, `bike_brand`, `bike_full_price`, `employee_full_price`, `employee_monthly_price`, `contract_months`, `currency`

---

## Notifications

### Push Notifications (FCM)
- Uses **Firebase Cloud Messaging HTTP v1 API** (no SDK, just fetch).
- Service account JSON stored in Supabase Vault as `firebase_service_account`.
- `firebase_project_id` stored in Supabase Vault as `firebase_project_id`.
- Employee's FCM token stored in `profiles.fcm_token` — updated by mobile app, cleared on logout.

### Notification Events (`notification_event` enum)
| Event | Trigger | Recipient | Channel |
|-------|---------|-----------|---------|
| `contract_ready` | `send-contract` called | Employee | FCM |
| `contract_signed_hr` | Webhook: HR signs | Employee | FCM |
| `contract_approved` | Webhook: contract fully signed | Employee | FCM |
| `contract_update` | `send-contract` called | HR dashboard | `company_notifications` + Realtime |
| `contract_update` | Webhook: Employee views/signs/declines | HR dashboard | `company_notifications` + Realtime |
| `user_update` | User registration trigger | HR dashboard | `company_notifications` + Realtime |

### FCM Data Payload
All FCM messages include a `data` field with `event` (notification type for localization) and `bike_benefit_id` so the mobile client can reload the relevant bike benefit screen in real time. The `notification` field provides English fallback text only.

### Realtime Notifications (Web)
- Notifications are persisted in the `company_notifications` table. Realtime `postgres_changes` on that table pushes each INSERT to subscribed HR dashboard clients automatically — no manual broadcast call needed.
- **`company_notifications` schema:** `id`, `company_id`, `event` (text), `event_type` (text), `payload` (jsonb), `created_at`.
- **`contract_update`** event: payload `{ user_id, employee_name, contract_id }`.
  - `event_type` values: `"created"` (new contract sent), `"viewed_by_employee"`, `"signed_by_employee"`, `"declined_by_employee"` (mapped via `EsigToContractStatus`).
  - Inserted by: `send-contract` (on creation) and `esignatures-webhook` (on employee action).
- **`user_update`** event: payload `{ user_id, employee_name }`, `event_type: "created"`.
  - Inserted directly by `handle_user_registration` trigger (no edge function hop needed).
- HR dashboard subscribes via `postgres_changes` filter `company_id=eq.{company_id}` and switches on `notification.event` / `notification.event_type`.
- RLS policy `hr_admin_select_own_company_notifications`: only `hr` and `admin` roles can SELECT rows matching their own `company_id`.

### Signer Identification
Webhook payload `data.signer.email` is matched against `profiles` + `user_roles` to determine role and route the notification accordingly.

---

## Edge Functions

| Function | Caller | CORS | Auth |
|----------|--------|------|------|
| `register` | Mobile app | No | Public (invite check) |
| `bulk-create` | Web frontend | Yes | JWT + HR/Admin role |
| `send-contract` | Mobile app | No | JWT (employee) |
| `esignatures-webhook` | eSignatures.com | No | HMAC-SHA256 |

---

## Security
- RLS enabled on all tables. Edge function writes use `service_role`.
- `update_bike_benefit_status` trigger runs as `SECURITY DEFINER` (owner: `postgres`) so it can delete `bike_orders` and `contracts` rows on reset, bypassing RLS (no DELETE policies exist on those tables).
- `jwt.sub` validated as UUID before use in any query.
- eSignatures webhook authenticated via HMAC-SHA256 (`X-Signature-SHA256` header).
- API key stored in Supabase Vault — never in code or config files.
- CORS enforced via `ALLOWED_ORIGINS` env var — never falls back to `*`.

---

## Image Upload

### Storage Buckets
| Bucket | Public | Max size | MIME types |
|--------|--------|----------|------------|
| `avatars` | Yes | 2 MB | jpeg, png, webp |
| `company-logos` | Yes | 2 MB | jpeg, png, webp, svg+xml |

### Path Convention
- Avatar: `{user_id}` — one file per user, overwrites on re-upload.
- Company logo: `{company_id}` — one file per company, overwrites on re-upload.

### DB Columns
- `profiles.profile_image_path` — storage path of the employee's avatar.
- `companies.logo_image_path` — storage path of the company logo.

Both columns are exposed in `profile_invites_with_details`.

### RLS
- **avatars**: any authenticated user can upload/replace/delete their own avatar (`name = auth.uid()`).
- **company-logos**: `hr` or `admin` can upload/replace/delete their company's logo (`name = auth_company_id()`).
- Both buckets are public for SELECT (no auth required to display images in the app).

### Client Usage (Supabase JS)
```ts
// Upload avatar
const { data, error } = await supabase.storage
  .from('avatars')
  .upload(userId, file, { upsert: true });

// Upload company logo (HR/admin)
const { data, error } = await supabase.storage
  .from('company-logos')
  .upload(companyId, file, { upsert: true });

// Get public URL
const { data: { publicUrl } } = supabase.storage
  .from('avatars')
  .getPublicUrl(userId);
```

---

## Configuration

| Key | Where | Used by |
|-----|-------|---------|
| `esignature_api_key` | Supabase Vault | `send-contract`, `esignatures-webhook` |
| `firebase_service_account` | Supabase Vault | `send-contract`, `esignatures-webhook` (FCM) |
| `firebase_project_id` | Supabase Vault | `send-contract`, `esignatures-webhook` (FCM) |
| `ALLOWED_ORIGINS` | Supabase secrets | `bulk-create` |
| `esignatures_template_id` | `companies` table | `send-contract` |
