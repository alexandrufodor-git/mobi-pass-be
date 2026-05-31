# MobiPass Backend

Supabase backend for MobiPass — Postgres schema/migrations, Edge Functions, RLS,
PII encryption, and the REGES employee bridge.

## Local Development & Testing

### 1. Start / stop the stack

```bash
supabase start          # boot Postgres, Auth, Storage, Studio, etc.
supabase stop           # shut everything down
supabase stop && supabase start   # full restart (clears Vault — see step 3)
```

Studio: http://127.0.0.1:54323 · API: http://127.0.0.1:54321 · Mailpit (OTP inbox): http://127.0.0.1:54324

### 2. Reset the database (apply migrations + seed)

```bash
supabase db reset       # re-runs all migrations, then supabase/seed.sql
```

The seed creates demo companies and users, including the **RegesGmail** company
(`44444444-…-444444444444`, `email_domain=gmail.com`) and its HR user
`hr-reges@gmail.com` — wired so curl-driven REGES uploads work without OTP.
The seed does **not** create any REGES invites; those are produced at runtime by
the upload in step 4.

### 3. Set up Vault secrets (required after every restart)

The Vault is cleared whenever the containers restart, so re-run these after
`supabase start` / `supabase stop && supabase start`:

```bash
./scripts/setup-pii-vault.sh    # inserts pii_encryption_key (PII encryption)
./scripts/setup-e2e-vault.sh    # E2E secrets; also (re)starts `functions serve`
```

> `setup-e2e-vault.sh` starts `supabase functions serve` in the background by
> default (logs: `.supabase-functions-serve.log`). If you'd rather run it
> yourself, pass `--no-serve` and start it manually:
>
> ```bash
> supabase functions serve --env-file supabase/.env.local
> ```

### 4. Upload REGES data (creates employee invites)

Posts a REGES JSON export to `/functions/v1/bulk-create`, authenticated as the
seeded RegesGmail HR user. This is how REGES invites + PII get created locally.

```bash
./scripts/dev/upload-reges.sh /Users/machita/Downloads/raport.json
./scripts/dev/upload-reges.sh raport.json | jq .     # pretty-print response
```

The file extension doesn't matter — the script always sends
`Content-Type: application/json`. Each record returns `created` or a reason
(e.g. `invalid_cnp:checksum_mismatch` for an invalid Romanian CNP).

### 5. Inspect the result (read-only audit)

```bash
./scripts/dev/show-audit.sh                 # local, all companies, all views
./scripts/dev/show-audit.sh <company-uuid>  # local, scoped to one company
./scripts/dev/show-audit.sh imports         # one view: imports | registers |
                                            #   invites | pii | notifications | follow
./scripts/dev/show-audit.sh --prod          # production (requires supabase link)
```

Views: REGES imports, register attempts (with candidate matching), profile
invites, staged-vs-linked employee PII, and HR-visible company notifications.

### Typical end-to-end loop

Copy-paste the whole block into your terminal — it's one `&&` chain, so it stops
at the first failure:

```bash
supabase stop && supabase start && \
  supabase db reset && \
  ./scripts/setup-pii-vault.sh && \
  ./scripts/setup-e2e-vault.sh && \
  ./scripts/dev/upload-reges.sh /Users/machita/Downloads/raport.json && \
  ./scripts/dev/show-audit.sh 44444444-4444-4444-4444-444444444444
```

Step by step: restart the stack (Vault clears on restart) → re-apply migrations +
seed → insert the PII encryption key → set up E2E secrets and serve functions →
create REGES invites from the upload → inspect the result.

## Other scripts

| Script | Purpose |
| --- | --- |
| `scripts/dev/upload-reges.sh` | Upload a REGES JSON file as the seeded HR user |
| `scripts/dev/show-audit.sh` | Read-only audit of the REGES bridge state |
| `scripts/setup-pii-vault.sh` | Insert the PII encryption key into Vault |
| `scripts/setup-e2e-vault.sh` | Set up E2E secrets and serve functions |
| `scripts/setup-tbi-vault.sh` | Set up TBI integration secrets |
| `scripts/deploy-functions.sh` | Deploy edge functions |
| `scripts/test-reges-bridge.sh` | REGES bridge test flow |
| `scripts/test-pii-foundation.sh` | PII foundation test flow |
| `scripts/test-flows.sh` | General flow tests |

## Layout

```
supabase/
  functions/        edge functions (_shared, register, bulk-create, …)
  migrations/       SQL migrations (immutable history)
  schema.sql        canonical full schema (kept up to date)
  seed.sql          local seed data
  tests/            pgTAP tests
scripts/            dev & setup scripts (see table above)
database/           triggers and DB docs
```
