# Test Ride Reservation Flow — Team Proposal

**Date:** 2026-03-30
**Status:** Draft for team discussion
**Audience:** Dev team + UI/UX designer

---

## Problem

The `book_live_test` step exists but has no structured scheduling. Currently the app just opens a WhatsApp deep link to the dealer. There's no way to:
- Know when the test ride is scheduled
- Confirm in the app that a date was agreed
- Track the test ride status on the HR dashboard

## Proposed Flow

**Email-based negotiation + in-app date confirmation.**

The employee and dealer negotiate via a regular email thread (powered by Brevo). Once they agree on a date, the employee enters it in the app. The dealer gets an automated confirmation email.

```
┌─────────────────────────────────────────────────────────┐
│ 1. Employee taps "Request Test Ride" in app             │
│    └─→ Edge function sends Brevo email to dealer        │
│        (bike info, employee name, reply-to = employee)  │
│                                                         │
│ 2. Dealer replies to email → normal email thread        │
│    Employee and dealer negotiate date/time               │
│                                                         │
│ 3. Employee enters agreed date in app (date picker)     │
│    └─→ test_ride_confirmed_at = selected datetime       │
│    └─→ Brevo sends confirmation email to dealer:        │
│        "Employee X confirmed for April 3 at 14:00"      │
│    └─→ HR notified via Realtime                         │
│                                                         │
│ 4. Employee goes to dealer, tests bike                  │
│                                                         │
│ 5. Employee taps "I completed my test" in app           │
│    └─→ live_test_checked_in_at = now()                  │
│    └─→ Step advances to commit_to_bike                  │
└─────────────────────────────────────────────────────────┘
```

## App States (book_live_test step)

The step has internal sub-states driven by timestamps:

| # | State | Condition | What the user sees |
|---|---|---|---|
| 1 | **ready** | `test_ride_requested_at IS NULL` | Dealer info card (name, address, map) + **"Request Test Ride"** button |
| 2 | **waiting** | `requested_at SET`, `confirmed_at NULL` | "Email sent to dealer! Check your inbox for their reply." + dealer contact info + **"Enter agreed date"** button (date picker) + option to re-send email |
| 3 | **confirmed** | `test_ride_confirmed_at SET` | Confirmed date/time card + dealer name/address/map + **"I completed my test"** button |
| 4 | **tested** | `live_test_checked_in_at SET` | Success state → "Next" advances to `commit_to_bike` |

## Emails (HTML mockups for UI/UX review)

### Email 1: Test Ride Request (sent to dealer)

**From:** MobiPass \<noreply@mobipass.app\>
**Reply-To:** {employee_email}
**To:** {dealer_email}
**Subject:** Test Ride Request — {bike_name}

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #f5f5f5;
      margin: 0;
      padding: 20px;
      color: #1a1a1a;
    }
    .container {
      max-width: 520px;
      margin: 0 auto;
      background: #ffffff;
      border-radius: 16px;
      overflow: hidden;
      box-shadow: 0 2px 8px rgba(0,0,0,0.08);
    }
    .header {
      background: #1B3B5A;
      color: #ffffff;
      padding: 24px 32px;
    }
    .header h1 {
      margin: 0;
      font-size: 20px;
      font-weight: 600;
    }
    .header p {
      margin: 8px 0 0;
      font-size: 14px;
      opacity: 0.85;
    }
    .body {
      padding: 32px;
    }
    .bike-card {
      background: #f8f9fa;
      border-radius: 12px;
      padding: 20px;
      margin-bottom: 24px;
    }
    .bike-card .label {
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      color: #6b7280;
      margin-bottom: 4px;
    }
    .bike-card .value {
      font-size: 16px;
      font-weight: 600;
      margin-bottom: 12px;
    }
    .bike-card .value:last-child {
      margin-bottom: 0;
    }
    .message {
      font-size: 15px;
      line-height: 1.6;
      color: #374151;
    }
    .cta {
      margin-top: 24px;
      padding: 16px 20px;
      background: #f0fdf4;
      border-left: 4px solid #22c55e;
      border-radius: 0 8px 8px 0;
      font-size: 14px;
      color: #166534;
    }
    .footer {
      padding: 20px 32px;
      background: #f9fafb;
      font-size: 12px;
      color: #9ca3af;
      text-align: center;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>Test Ride Request</h1>
      <p>An employee would like to test a bike at your shop</p>
    </div>
    <div class="body">
      <div class="bike-card">
        <div class="label">Bike</div>
        <div class="value">{bike_brand} {bike_name}</div>
        <div class="label">Requested by</div>
        <div class="value">{employee_first_name}</div>
      </div>
      <div class="message">
        <p>Hi {dealer_name},</p>
        <p><strong>{employee_first_name}</strong> from <strong>{company_name}</strong> would like
          to schedule a test ride for the <strong>{bike_brand} {bike_name}</strong>.</p>
        <p>Please reply to this email to discuss available dates and times.</p>
      </div>
      <div class="cta">
        💡 Just hit <strong>Reply</strong> — your response goes directly to {employee_first_name}'s inbox.
      </div>
    </div>
    <div class="footer">
      Sent via MobiPass · Bike Benefit Program
    </div>
  </div>
</body>
</html>
```

### Email 2: Confirmation (sent to dealer after employee picks date)

**From:** MobiPass \<noreply@mobipass.app\>
**Reply-To:** {employee_email}
**To:** {dealer_email}
**Subject:** Confirmed: Test Ride — {bike_name} on {date}

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #f5f5f5;
      margin: 0;
      padding: 20px;
      color: #1a1a1a;
    }
    .container {
      max-width: 520px;
      margin: 0 auto;
      background: #ffffff;
      border-radius: 16px;
      overflow: hidden;
      box-shadow: 0 2px 8px rgba(0,0,0,0.08);
    }
    .header {
      background: #166534;
      color: #ffffff;
      padding: 24px 32px;
    }
    .header h1 {
      margin: 0;
      font-size: 20px;
      font-weight: 600;
    }
    .body {
      padding: 32px;
    }
    .confirmation-card {
      background: #f0fdf4;
      border: 2px solid #bbf7d0;
      border-radius: 12px;
      padding: 20px;
      margin-bottom: 24px;
      text-align: center;
    }
    .confirmation-card .checkmark {
      font-size: 32px;
      margin-bottom: 8px;
    }
    .confirmation-card .date {
      font-size: 20px;
      font-weight: 700;
      color: #166534;
      margin-bottom: 4px;
    }
    .confirmation-card .time {
      font-size: 16px;
      color: #15803d;
    }
    .details {
      font-size: 14px;
      line-height: 1.6;
      color: #374151;
    }
    .details .row {
      display: flex;
      padding: 8px 0;
      border-bottom: 1px solid #f3f4f6;
    }
    .details .label {
      width: 100px;
      color: #6b7280;
      font-size: 13px;
    }
    .details .value {
      font-weight: 500;
    }
    .footer {
      padding: 20px 32px;
      background: #f9fafb;
      font-size: 12px;
      color: #9ca3af;
      text-align: center;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>✓ Test Ride Confirmed</h1>
    </div>
    <div class="body">
      <div class="confirmation-card">
        <div class="checkmark">✅</div>
        <div class="date">{formatted_date}</div>
        <div class="time">{formatted_time}</div>
      </div>
      <div class="details">
        <div class="row">
          <span class="label">Employee</span>
          <span class="value">{employee_first_name}</span>
        </div>
        <div class="row">
          <span class="label">Bike</span>
          <span class="value">{bike_brand} {bike_name}</span>
        </div>
        <div class="row">
          <span class="label">Company</span>
          <span class="value">{company_name}</span>
        </div>
      </div>
    </div>
    <div class="footer">
      Need to reschedule? Reply to this email to contact {employee_first_name} directly.<br><br>
      Sent via MobiPass · Bike Benefit Program
    </div>
  </div>
</body>
</html>
```

---

## DB Changes

### New columns on `bike_benefits`

| Column | Type | Purpose |
|---|---|---|
| `test_ride_requested_at` | timestamptz | When the request email was sent |
| `test_ride_confirmed_at` | timestamptz | The agreed date/time for the test ride |

### New column on `dealers`

| Column | Type | Purpose |
|---|---|---|
| `email` | text | Dealer email address for Brevo emails |

### Trigger updates

Reset these new columns when step goes back to `choose_bike`:
```sql
NEW.test_ride_requested_at := NULL;
NEW.test_ride_confirmed_at := NULL;
```

---

## New Edge Function

### `request-test-ride`

**One edge function, two actions** (controlled by request body):

| Action | When | What it does |
|---|---|---|
| `request` | User taps "Request Test Ride" | Sends Brevo email #1 to dealer, sets `test_ride_requested_at` |
| `confirm` | User enters agreed date | Sends Brevo confirmation email #2 to dealer, sets `test_ride_confirmed_at`, notifies HR |

**Caller:** Mobile app
**Auth:** JWT (employee)
**External dependency:** Brevo transactional email API (API key in Vault)

Request body:
```json
// Action: request
{ "action": "request" }

// Action: confirm
{ "action": "confirm", "confirmed_datetime": "2026-04-03T14:00:00Z" }
```

Response:
```json
{ "success": true }
```

### Brevo Integration

Uses Brevo's **Send Transactional Email** API (`POST https://api.brevo.com/v3/smtp/email`).

- API key stored in Supabase Vault as `brevo_api_key`
- Sends raw HTML (built in the edge function, no Brevo template needed)
- `reply-to` set to employee's email so dealer replies go directly to them
- `from` set to `MobiPass <noreply@mobipass.app>` (or whatever verified sender domain)

---

## What This Does NOT Include

- **No dealer web form** — dates are negotiated via email thread, not a structured form
- **No `test_ride_slots` table** — employee enters one confirmed date, not picking from multiple
- **No WhatsApp** — replaced entirely by email (can be re-added later if needed)
- **No token/link system** — dealer just replies to email like a normal person

## What's Needed Before Building

1. **Brevo account** with transactional email enabled + API key
2. **Verified sender domain** in Brevo (so emails don't land in spam)
3. **`dealers.email`** populated for all dealers
4. **UI/UX designer** review of the HTML email mockups above + the 4 app states
5. **Team alignment** on this approach

## Comparison to Alternatives

| | This proposal (Email thread) | Web form approach | WhatsApp deep link (current) |
|---|---|---|---|
| **Dealer effort** | Reply to email (zero friction) | Click link, fill form | Open WhatsApp, type |
| **Date entry** | Employee enters in app | Employee picks from dealer-proposed slots | None (no tracking) |
| **Emails** | 2 (request + confirmation) | 1 (or 0 if WhatsApp) | 0 |
| **New tables** | None | `test_ride_slots` | None |
| **New edge functions** | 1 (`request-test-ride`) | 2-3 | 0 |
| **External dependency** | Brevo API | Brevo API or none | None |
| **Scheduling visibility** | Confirmed date in DB | Proposed slots + confirmed in DB | None |
| **Effort** | Medium | Large | Small (already built) |

---

## Open Questions for Team

1. Do we need a **reminder notification** to the employee on the day of the test ride?
2. Should HR see the scheduled date on their dashboard, or just the status?
3. What happens if the employee needs to **reschedule**? (Reset `test_ride_confirmed_at` and re-enter?)
4. Should we keep the WhatsApp option as a **fallback** if dealer has no email?
5. Brevo sender domain — which domain do we verify? (`mobipass.app`? `mobi-pass.com`?)

---

*This document is for team discussion. Implementation begins after team alignment.*
