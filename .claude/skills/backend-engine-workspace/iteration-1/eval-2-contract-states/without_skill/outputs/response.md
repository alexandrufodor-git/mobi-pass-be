# Contract Status: All States and Transitions

## The Enum (current, authoritative)

Defined in `supabase/schema.sql` line 125 as `public.contract_status`:

```
pending
viewed_by_employee
signed_by_employee
signed_by_employer
approved
terminated
declined_by_employee
```

## How Status Is Determined

Contract status is **never set directly by application code** (except `terminated`, which HR sets manually). Instead, a PostgreSQL `BEFORE INSERT OR UPDATE` trigger named `update_contract_status_on_change` fires on the `bike_benefits` table and derives the status from timestamp columns using a priority chain.

The trigger function `public.update_contract_status()` (defined in migration `20260225000003_...add_declined_by_employee_contract_status.sql`) evaluates top-to-bottom, first match wins:

| Priority | Condition | Resulting Status |
|----------|-----------|------------------|
| Guard | `OLD.contract_status = 'terminated'` | No change (early return) |
| 1 (highest) | `contract_declined_at IS NOT NULL` | `declined_by_employee` |
| 2 | `contract_employee_signed_at` AND `contract_employer_signed_at` AND `contract_approved_at` all NOT NULL | `approved` |
| 3 | `contract_employer_signed_at IS NOT NULL` | `signed_by_employer` |
| 4 | `contract_employee_signed_at IS NOT NULL` | `signed_by_employee` |
| 5 | `contract_viewed_at IS NOT NULL` | `viewed_by_employee` |
| 6 | `contract_requested_at IS NOT NULL` | `pending` |
| 7 (lowest) | None of the above | `NULL` (no contract yet) |

## Each State in Detail

### `NULL` (no contract exists yet)
- **Meaning**: No contract has been requested for this bike benefit.
- **Trigger**: None of the contract timestamp columns are set.
- **Progress bar**: 0% -- not started.

### `pending`
- **Meaning**: A contract has been created and sent to the employee for signing, but they have not yet opened it.
- **Trigger**: `contract_requested_at` is set. This happens when the `request-contract` edge function calls the eSignatures.com API and stores the resulting contract, setting `contract_requested_at = now()` on the bike benefit.
- **Progress bar**: ~15%.

### `viewed_by_employee`
- **Meaning**: The employee has opened/viewed the contract document but has not signed it yet.
- **Trigger**: `contract_viewed_at` is set. This is driven by the eSignatures webhook receiving the `signer-viewed-the-contract` event, which PATCHes `contract_viewed_at = now()` on the bike benefit row.
- **Progress bar**: ~30%.

### `signed_by_employee`
- **Meaning**: The employee has signed the contract. Waiting for the employer (HR) to countersign.
- **Trigger**: `contract_employee_signed_at` is set. Driven by the eSignatures webhook receiving the `signer-signed` event (where the signer is the employee), which PATCHes `contract_employee_signed_at = now()`.
- **Progress bar**: ~55%.

### `signed_by_employer`
- **Meaning**: The employer/HR has signed the contract. In practice, when HR signs, the eSignatures `contract-signed` event fires, which sets both `contract_employer_signed_at` and `contract_approved_at` simultaneously -- so this state is typically transient or skipped.
- **Trigger**: `contract_employer_signed_at IS NOT NULL` but `contract_approved_at IS NULL`. This would only occur if the employer signed but the contract was not yet finalized (unlikely in the current webhook flow, which sets both at once).
- **Progress bar**: ~75%.

### `approved`
- **Meaning**: Both parties have signed and the contract is fully executed. This is the successful terminal state.
- **Trigger**: All three timestamps -- `contract_employee_signed_at`, `contract_employer_signed_at`, and `contract_approved_at` -- are set. In the webhook, the `contract-signed` event sets the employer and approved timestamps together.
- **Progress bar**: 100%.

### `terminated`
- **Meaning**: The contract has been terminated. This is a manual HR action only.
- **Trigger**: HR directly updates `contract_status = 'terminated'` on the row (with triggers disabled, or via a direct column write). Once set, the trigger guard prevents any automatic overwrite -- it is a permanent terminal state.
- **Progress bar**: N/A -- show as cancelled/terminated indicator, not a progress step.

### `declined_by_employee`
- **Meaning**: The employee actively declined to sign the contract.
- **Trigger**: `contract_declined_at` is set. Driven by the eSignatures webhook receiving the `signer-declined` event, which PATCHes `contract_declined_at = now()`.
- **Important**: Unlike `terminated`, this is NOT a permanent terminal state. The trigger does not guard against overwriting it. A new contract can be re-sent (resetting the timestamps via the `choose_bike` step reset logic), allowing the flow to restart.
- **Progress bar**: N/A -- show as declined indicator with option to restart.

## Transition Diagram (Happy Path)

```
NULL --> pending --> viewed_by_employee --> signed_by_employee --> approved
```

The typical flow skips `signed_by_employer` because the webhook sets employer-signed and approved timestamps together.

## Transition Diagram (All Paths)

```
                                  +-- terminated (HR manual, permanent)
                                  |
NULL --> pending --> viewed_by_employee --> signed_by_employee --> signed_by_employer --> approved
                          |                       |
                          |                       +-- declined_by_employee (webhook)
                          |                                    |
                          +-- declined_by_employee             +--> (can restart from NULL
                                                                     via choose_bike reset)
```

## Reset Mechanism

When the `step` column on `bike_benefits` is changed back to `choose_bike`, the `update_bike_benefit_status()` trigger **clears all contract timestamps** to NULL:

- `contract_requested_at`
- `contract_viewed_at`
- `contract_employee_signed_at`
- `contract_employer_signed_at`
- `contract_approved_at`
- `contract_declined_at`
- `contract_status` (set to NULL)

This allows the full contract flow to restart from scratch.

## Progress Bar Recommendation

For the employee-facing progress bar, use 5 steps on the happy path:

| Step | Status | Label | Complete? |
|------|--------|-------|-----------|
| 1 | `pending` | Contract Sent | Yes if status >= pending |
| 2 | `viewed_by_employee` | Viewed | Yes if status >= viewed |
| 3 | `signed_by_employee` | You Signed | Yes if status >= signed_by_employee |
| 4 | `approved` | Approved | Yes if status = approved |

Show `declined_by_employee` and `terminated` as overlay/alert states that replace the progress bar with an explanatory message.

## Key Source Files

- Enum definition: `/Users/machita/cod/mobi-pass-be/supabase/schema.sql` (line 125)
- Trigger function (authoritative): `/Users/machita/cod/mobi-pass-be/supabase/migrations/20260225000003_20260225000004_add_declined_by_employee_contract_status.sql` (line 62)
- Webhook handler (sets timestamps): `/Users/machita/cod/mobi-pass-be/supabase/functions/esignatures-webhook/index.ts`
- Event constants: `/Users/machita/cod/mobi-pass-be/supabase/functions/_shared/constants.ts` (EsigEvents, line 31)
- Terminal state tests: `/Users/machita/cod/mobi-pass-be/supabase/tests/00003_terminal_states.test.sql`
