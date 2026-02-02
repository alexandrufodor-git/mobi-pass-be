# Bulk Create Employee Invites

This edge function allows HR users to bulk-create employee invites by uploading a CSV file.

## Endpoint

```
POST /bulk-create
```

## Authentication

Requires authentication via JWT token. The user must have HR permissions.

## CSV Format

The CSV file must include a header row with column names.

### Required Columns
- `email` - Employee email address (must be valid email format)
- `firstName` - Employee first name (cannot be empty)
- `lastName` - Employee last name (cannot be empty)

### Optional Columns
- `description` - Employee description or bio
- `department` - Employee department or team
- `experience` - Employee experience (e.g., "2 years", "6 months")
- `hireDate` - Employee hire date as Unix timestamp in milliseconds (e.g., 1706745600000 for Feb 1, 2024)

### Example CSV

```csv
email,firstName,lastName,department,experience,hireDate,description
john.doe@example.com,John,Doe,Engineering,3 years,1672531200000,Senior Software Engineer
jane.smith@example.com,Jane,Smith,Marketing,2 years,1680307200000,Marketing Manager
bob.johnson@example.com,Bob,Johnson,Sales,,1688169600000,
alice.williams@example.com,Alice,Williams,HR,5 years,1659398400000,HR Director
```

### Notes

- Column order doesn't matter as long as the header row matches
- `firstName` and `lastName` are required and cannot be empty
- Empty values for optional fields are treated as NULL in the database
- If an email already exists in the system, that row will be skipped with status `already_exists`
- Invalid email addresses will be rejected with status `invalid_email`
- Missing or empty `firstName` will be rejected with error `missing_first_name`
- Missing or empty `lastName` will be rejected with error `missing_last_name`
- The `hireDate` must be a valid integer (Unix timestamp in milliseconds). Invalid values will be ignored
- All text fields are trimmed of leading/trailing whitespace
- The CSV can be sent as either:
  - `multipart/form-data` (file upload)
  - Raw CSV text in the request body

## Response Format

```json
{
  "created": 4,
  "results": [
    {
      "email": "john.doe@example.com",
      "invited": true,
      "body": {
        "id": "123e4567-e89b-12d3-a456-426614174000",
        "email": "john.doe@example.com",
        "first_name": "John",
        "last_name": "Doe",
        "department": "Engineering",
        "experience": "3 years",
        "hire_date": 1672531200000,
        "description": "Senior Software Engineer",
        "company_id": "abc12345-e89b-12d3-a456-426614174000",
        "status": "inactive",
        "created_at": "2024-02-01T12:00:00Z"
      }
    },
    {
      "email": "existing@example.com",
      "invited": false,
      "status": "already_exists"
    },
    {
      "email": "invalid-email",
      "invited": false,
      "error": "invalid_email"
    },
    {
      "email": "missing.name@example.com",
      "invited": false,
      "error": "missing_first_name"
    }
  ]
}
```

## Example Request (cURL)

```bash
curl -X POST https://your-supabase-url.functions.supabase.co/bulk-create \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -F "file=@employees.csv"
```

## Data Flow

1. HR user uploads CSV file
2. Function parses CSV and validates email addresses
3. For each valid email:
   - Checks if email already exists in `profile_invites`
   - If not exists, creates a new invite record with all provided employee data
   - Associates the invite with the HR user's company
4. Returns summary of successful and failed invites

## Employee Registration Flow

When an employee registers using their invite:

1. Employee receives invitation email
2. Employee verifies their email via OTP
3. Employee sets their password
4. The `handle_user_registration` trigger automatically:
   - Creates a user profile with all employee data from the invite
   - Copies firstName, lastName, department, experience, hireDate, and description to the profile
   - Assigns 'employee' role
   - Creates a bike benefit record
   - Updates the invite status to 'active'

## Converting Date to Unix Timestamp

To convert a date to Unix timestamp in milliseconds for the `hireDate` field:

### JavaScript/TypeScript
```javascript
const date = new Date('2024-02-01');
const timestamp = date.getTime(); // 1706745600000
```

### Python
```python
from datetime import datetime
date = datetime(2024, 2, 1)
timestamp = int(date.timestamp() * 1000)  # 1706745600000
```

### Excel/Sheets Formula
```
=(A2-DATE(1970,1,1))*86400000
```
Where A2 contains your date value.
