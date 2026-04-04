# Contract Status: All States and Transitions

## The States

The `contract_status` field on `bike_benefits` has 7 possible values (plus `NULL`):

| # | Status | Meaning | Progress bar suggestion |
|---|--------|---------|------------------------|
| - | `NULL` | No contract process started yet. The employee hasn't reached the `sign_contract` step. | 0% |
| 1 | `pending` | Contract has been requested but the employee hasn't opened it yet. | 15% |
| 2 | `viewed_by_employee` | Employee opened/viewed the contract document. | 30% |
| 3 | `signed_by_employee` | Employee has signed. Waiting for HR/employer. | 55% |
| 4 | `signed_by_employer` | HR/employer has signed. Approval is imminent. | 80% |
| 5 | `approved` | Both parties signed, contract fully approved. | 100% |
| 6 | `declined_by_employee` | Employee declined to sign. | N/A (error state) |
| 7 | `terminated` | HR manually terminated the contract. | N/A (terminal state) |

## What Triggers Each Transition

The status is **never set directly** by the client. A database trigger (`update_contract_status`) automatically derives it from timestamp columns on the `bike_benefits` row. Here is what sets each timestamp:

### NULL -> `pending`
- **Trigger:** Employee calls `POST /functions/v1/send-contract` (just needs the Authorization header, no body).
- **What happens:** The edge function calls the eSignatures.com API, creates a `contracts` row, and sets `contract_requested_at` on `bike_benefits`. The DB trigger sees `contract_requested_at IS NOT NULL` and sets status to `pending`.

### `pending` -> `viewed_by_employee`
- **Trigger:** eSignatures.com sends a webhook with event `signer-viewed-the-contract`.
- **What happens:** The `esignatures-webhook` edge function sets `contract_viewed_at` on `bike_benefits`. The DB trigger derives `viewed_by_employee`.

### `viewed_by_employee` -> `signed_by_employee`
- **Trigger:** eSignatures.com sends a webhook with event `signer-signed` (from the employee signer).
- **What happens:** Webhook sets `contract_employee_signed_at`. Trigger derives `signed_by_employee`. A Realtime notification is sent to the HR dashboard.

### `signed_by_employee` -> `signed_by_employer`
- **Trigger:** eSignatures.com sends a webhook with event `signer-signed` (from the HR signer, when only employer has signed but `contract_approved_at` is not yet set).
- **What happens:** Webhook sets `contract_employer_signed_at`. Trigger derives `signed_by_employer`. An FCM push notification is sent to the employee.

### `signed_by_employer` -> `approved`
- **Trigger:** eSignatures.com sends a webhook with event `contract-signed` (all parties done).
- **What happens:** Webhook sets both `contract_employer_signed_at` and `contract_approved_at`. Trigger sees all three timestamps (`contract_employee_signed_at`, `contract_employer_signed_at`, `contract_approved_at`) are non-null and derives `approved`. An FCM push notification ("Contract Approved") is sent to the employee.

### Any state -> `declined_by_employee`
- **Trigger:** eSignatures.com sends a webhook with event `signer-declined`.
- **What happens:** Webhook sets `contract_declined_at`. This has the **highest priority** in the trigger -- if `contract_declined_at` is non-null, the status is always `declined_by_employee` regardless of other timestamps.
- **Recoverable:** This is NOT a terminal state. If `contract_declined_at` is cleared (e.g., by re-sending the contract), the status reverts based on the remaining timestamps.

### Any state -> `terminated`
- **Trigger:** HR manually sets `contract_status = 'terminated'` (not via webhook).
- **What happens:** This is a **terminal state**. Once set, the trigger will not overwrite it -- no webhook event can change it. Only direct DB intervention can undo it.

## Resetting the Contract Flow

If the employee's `bike_benefit_step` is reset back to `choose_bike`, the `update_bike_benefit_status` trigger clears ALL contract timestamps and sets `contract_status` to `NULL`. This also deletes related `contracts` and `bike_orders` rows. The employee starts fresh.

## Reading the Status from the Frontend

Query the `bike_benefits` table filtered to the current user:

```
GET /rest/v1/bike_benefits?user_id=eq.{uid}&select=contract_status,contract_requested_at,contract_viewed_at,contract_employee_signed_at,contract_employer_signed_at,contract_approved_at,contract_declined_at
```

RLS ensures employees can only see their own row. You get both the derived `contract_status` enum and all the individual timestamps, so you can show the progress bar state and also display "Signed on {date}" labels if needed.

## Priority Rules (Trigger Logic)

The trigger evaluates timestamps in this priority order (highest first):

1. `contract_declined_at IS NOT NULL` -> `declined_by_employee`
2. All three signed timestamps + `contract_approved_at` -> `approved`
3. `contract_employer_signed_at IS NOT NULL` -> `signed_by_employer`
4. `contract_employee_signed_at IS NOT NULL` -> `signed_by_employee`
5. `contract_viewed_at IS NOT NULL` -> `viewed_by_employee`
6. `contract_requested_at IS NOT NULL` -> `pending`
7. None of the above -> `NULL`

Exception: if the current status is `terminated`, the trigger exits early and does not change it.

## Notifications Your App Can Listen For

| Transition | Who gets notified | Channel |
|---|---|---|
| Contract requested | Employee gets `contract_ready` | FCM push |
| Employee views/signs/declines | HR dashboard | Realtime (`company_notifications` table, event_type `contract_update`) |
| HR signs | Employee gets `contract_signed_hr` | FCM push |
| Contract fully approved | Employee gets `contract_approved` | FCM push |
