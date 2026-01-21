# Database Scripts

This directory contains custom database logic that is version controlled separately from the Supabase-managed structure.

## Directory Structure

```
database/
├── triggers/          # Database triggers
│   └── handle_user_registration.sql
└── README.md
```

## Usage

### Running Triggers

To apply or update triggers in your database:

**Local Development:**
```bash
# From project root
psql -h localhost -p 54322 -U postgres -d postgres -f database/triggers/handle_user_registration.sql
```

Or using Supabase CLI:
```bash
# Connect to local database
supabase db reset  # This will rerun all migrations
```

**Production (via Supabase Dashboard):**
1. Go to SQL Editor in your Supabase dashboard
2. Copy the contents of the trigger file
3. Paste and execute

**Important:** After modifying trigger files, you need to reapply them to your database. The triggers are not automatically synced like migrations.

### Adding New Triggers

1. Create a new `.sql` file in `database/triggers/`
2. Include clear comments explaining what the trigger does
3. Always use `DROP TRIGGER IF EXISTS` before creating new triggers
4. Test locally before applying to production

## Triggers

### handle_user_registration.sql

Automatically sets up new users when they register via OTP:
- Assigns 'employee' role
- Creates profile record
- Activates invite status

**Fires on:**
- New user creation (OTP verification)
- Password updates

## Notes

- The `supabase/` folder is managed by Supabase CLI and should not be modified directly
- All custom database logic should live in this `database/` directory
- Keep trigger files focused and single-purpose for easy maintenance

