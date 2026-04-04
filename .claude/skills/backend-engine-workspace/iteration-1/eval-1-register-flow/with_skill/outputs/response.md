# Registering a User: Endpoint and Full Flow

## Prerequisite

The user's email must already exist in the `profile_invites` table. This happens when HR uploads a CSV via the `bulk-create` endpoint. If the email is not invited, registration will fail with a `403`.

---

## Step 1: Request an OTP

**Endpoint:**

```
POST https://<your-supabase-project>.supabase.co/functions/v1/register
```

**Headers:**

```
Content-Type: application/json
```

**Body:**

```json
{
  "email": "employee@company.com"
}
```

**Success response (200):**

```json
{
  "success": true,
  "message": "OTP sent to email",
  "email": "employee@company.com"
}
```

**Error responses:**

| Status | Body | Meaning |
|--------|------|---------|
| 400 | `{ "error": "email_required" }` | No email in request body |
| 403 | `{ "error": "not_invited" }` | Email not found in `profile_invites` |
| 500 | `{ "error": "otp_send_failed", "details": {...} }` | Supabase Auth failed to send the OTP |

At this point, the user receives an email containing a 6-digit OTP code (or a magic link, depending on how the Supabase email template is configured -- in this project it is set up for 6-digit codes).

---

## Step 2: Verify the OTP (Client-Side)

Once the user enters the 6-digit code from their email, your app verifies it directly against the Supabase Auth REST API. There is no custom edge function for this step.

**Endpoint:**

```
POST https://<your-supabase-project>.supabase.co/auth/v1/verify
```

**Headers:**

```
Content-Type: application/json
apikey: <your-supabase-anon-key>
```

**Body:**

```json
{
  "email": "employee@company.com",
  "token": "123456",
  "type": "email"
}
```

**Success response (200):** A session object containing `access_token`, `refresh_token`, and `user`. Store these -- the `access_token` (JWT, valid for 1 hour) is what you pass as `Authorization: Bearer <token>` for all subsequent authenticated requests.

---

## Step 3: What Happens Automatically After Verification

When the OTP is verified, Supabase Auth sets `email_confirmed_at` on the user record. This fires a database trigger (`handle_user_registration`) that does the following automatically -- no client action needed:

1. **Creates a profile** in the `profiles` table, populated from the matching `profile_invites` row (first name, last name, company, department, hire date).
2. **Assigns the `employee` role** in the `user_roles` table.
3. **Updates the invite status** to `active` in `profile_invites`.
4. **Creates a `bike_benefits` row** for the user (starting at the `choose_bike` step).
5. **Posts a `user_update` notification** to `company_notifications`, which HR receives in real time via Supabase Realtime.

After this trigger completes, the user is fully registered and has a profile, a role, and a bike benefit ready to go.

---

## Step 4: What the User Can Do Next

Once registered and holding a valid JWT, the employee can:

- **Read their profile:** `GET /rest/v1/profiles?user_id=eq.<uid>` (RLS scoped to own row)
- **Browse bikes with company pricing:** `GET /rest/v1/bikes_with_my_pricing` (view auto-calculates subsidized pricing based on the employee's company terms)
- **Progress through the bike benefit steps:** Update `bike_benefits` to advance through `choose_bike` -> `book_live_test` -> `commit_to_bike` -> `sign_contract` -> `pickup_delivery`
- **Request a contract:** `POST /functions/v1/send-contract` (no body needed, just the JWT)
- **Upload an avatar:** Upload to the `avatars` storage bucket (filename must be the user's auth UID); a trigger auto-sets `profiles.profile_image_path`
- **Store FCM token:** `PATCH /rest/v1/profiles?user_id=eq.<uid>` with `{ "fcm_token": "<token>" }` so the backend can send push notifications for contract events

---

## Summary Sequence Diagram

```
Mobile App                    Edge Function (/register)          Supabase Auth            Database Trigger
    |                                  |                              |                        |
    |-- POST /register {email} ------->|                              |                        |
    |                                  |-- check profile_invites ---->|                        |
    |                                  |<-- invite found -------------|                        |
    |                                  |-- POST /auth/v1/otp -------->|                        |
    |                                  |<-- OTP sent ----------------|                        |
    |<-- 200 { success: true } --------|                              |                        |
    |                                  |                              |                        |
    |  (user receives email with code)                                |                        |
    |                                  |                              |                        |
    |-- POST /auth/v1/verify {token} -------------------------------->|                        |
    |<-- 200 { access_token, ... } -----------------------------------|                        |
    |                                  |                              |-- email_confirmed_at -->|
    |                                  |                              |   fires trigger:        |
    |                                  |                              |   - create profile      |
    |                                  |                              |   - assign role         |
    |                                  |                              |   - create bike_benefit |
    |                                  |                              |   - notify HR           |
    |                                  |                              |                        |
    |-- (authenticated requests with JWT from here on) -------------------------------------------
```

---

## Important Notes for Mobile

- **Token refresh:** The JWT expires after 1 hour. Use the `refresh_token` from the verify response to get new access tokens via `POST /auth/v1/token?grant_type=refresh_token`.
- **Role in JWT:** The user's role (`employee`) is embedded in the JWT under the `user_role` claim via a custom access token hook. You can decode it client-side if needed.
- **Rate limit:** OTP requests are rate-limited to once per 60 seconds per email.
- **OTP expiry:** Codes expire after 60 seconds by default.
