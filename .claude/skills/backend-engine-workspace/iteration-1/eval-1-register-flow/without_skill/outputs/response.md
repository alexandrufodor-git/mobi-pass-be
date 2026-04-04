# User Registration Endpoint and Full Flow

## Endpoint

```
POST /functions/v1/register
```

**Headers:**

```
Authorization: Bearer <anon_key>
Content-Type: application/json
```

**Body:**

```json
{ "email": "user@example.com" }
```

**Success response (200):**

```json
{
  "success": true,
  "message": "OTP sent to email",
  "email": "user@example.com"
}
```

**Error responses:**

| Status | Body | Meaning |
|--------|------|---------|
| 400 | `{"error":"email_required"}` | No email in request body |
| 403 | `{"error":"not_invited"}` | No matching row in `profile_invites` |
| 500 | `{"error":"otp_send_failed","details":{...}}` | Supabase Auth OTP call failed |

---

## Full Flow (Step by Step)

### Prerequisites

Before a user can register, an HR or admin user must have created a row in the `profile_invites` table for that email address. The invite carries `company_id`, `first_name`, `last_name`, `description`, `department`, and `hire_date` -- all of which get copied into the user's profile automatically.

### Step 1 -- Client calls the register endpoint

The client sends `POST /functions/v1/register` with the user's email. The edge function:

1. Checks `profile_invites` for a matching email (case-insensitive: `ilike`).
2. If no invite exists, returns `403 not_invited`.
3. If an invite exists, calls the Supabase Auth OTP endpoint (`POST /auth/v1/otp`) with `{ email, create_user: true }`.
4. Returns `200` with `{ success: true }`.

### Step 2 -- User receives OTP

Supabase Auth sends the user an email. Depending on the email template configuration, this is either:
- A **magic link** (default), or
- A **6-digit OTP code** (if the email template uses `{{ .Token }}` instead of a link).

The OTP is valid for 60 seconds by default. Users can request a new one once every 60 seconds (rate limit).

### Step 3 -- Client verifies OTP

The client verifies the OTP by calling the Supabase Auth API directly:

```
POST /auth/v1/verify
Content-Type: application/json

{
  "email": "user@example.com",
  "token": "123456",
  "type": "email"
}
```

On success, this confirms the user's email (`email_confirmed_at` is set) and returns a session with access/refresh tokens.

### Step 4 -- Database trigger fires automatically

When the auth user record is inserted (or updated) with both `email_confirmed_at IS NOT NULL` and `encrypted_password IS NOT NULL`, the `handle_user_registration()` trigger function executes. It does the following in order:

1. **Looks up the invite** -- Reads `company_id`, `first_name`, `last_name`, `description`, `department`, and `hire_date` from `profile_invites` matching the email. Raises an exception if no invite is found.

2. **Creates the profile** -- Inserts a row into `profiles` with `status = 'active'`, the resolved `company_id`, and the employee fields from the invite. Uses `ON CONFLICT (user_id) DO UPDATE` so it is idempotent.

3. **Assigns the employee role** -- Inserts into `user_roles` with `role = 'employee'`. Uses `ON CONFLICT DO NOTHING`.

4. **Marks the invite as active** -- Updates the `profile_invites` row to `status = 'active'`.

5. **Creates a bike benefit** -- Inserts a row into `bike_benefits` for the user. Uses `ON CONFLICT DO NOTHING`.

6. **Inserts an HR notification** -- Writes a row to `company_notifications` with `event = 'user_update'` and `event_type = 'created'`, including the `user_id` and `employee_name` in the payload. This table is added to `supabase_realtime`, so HR dashboard clients subscribed via Realtime `postgres_changes` receive the notification immediately.

### Step 5 -- Client is authenticated

After OTP verification, the client has a valid JWT session. The user's profile, role, company assignment, and bike benefit are all already in place. The client can immediately start making authenticated requests.

---

## Trigger Conditions

Two database triggers call `handle_user_registration()`:

| Trigger | Event | Condition |
|---------|-------|-----------|
| `on_auth_user_created` | `AFTER INSERT ON auth.users` | `email_confirmed_at IS NOT NULL AND encrypted_password IS NOT NULL` |
| `on_auth_user_updated` | `AFTER UPDATE ON auth.users` | `email_confirmed_at IS NOT NULL AND encrypted_password IS NOT NULL AND old.encrypted_password IS DISTINCT FROM new.encrypted_password` |

This means the trigger fires when the user both confirms their email and has a password set, covering the case where these happen in separate steps.

---

## Key Tables Involved

| Table | Role in registration |
|-------|---------------------|
| `profile_invites` | Gate-check (must exist before registration) and source of employee metadata |
| `profiles` | Created automatically by the trigger with `status = 'active'` |
| `user_roles` | Populated with `employee` role by the trigger |
| `bike_benefits` | Empty benefit row created by the trigger |
| `company_notifications` | HR notification inserted by the trigger; delivered via Realtime |
