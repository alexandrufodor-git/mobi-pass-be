# Benefit & Contract Status Tracking

## Overview

This document explains the new status tracking system for bike benefits and contracts in the HR dashboard and employee views.

## Status Fields

### 1. Benefit Status (`benefit_status`)

Tracks the overall lifecycle of an employee's bike benefit from creation to completion.

**Nullable Field**: `benefit_status` is `NULL` when the benefit has not been started yet (`step` is NULL).

**Enum Values:**

| Status | Description | Trigger Condition |
|--------|-------------|-------------------|
| `NULL` | Benefit created but not yet started | `step` is NULL |
| `inactive` | Manually set intermediate state | Manually set by HR |
| `searching` | Employee is browsing/choosing bikes | `step = 'choose_bike'` |
| `testing` | Employee has booked and is testing a bike | `step = 'book_live_test'` AND `live_test_whatsapp_sent_at` IS NOT NULL |
| `active` | Bike has been delivered, benefit is active | `step = 'pickup_delivery'` AND `delivered_at` IS NOT NULL |
| `insurance_claim` | Insurance claim has been filed | Manually set by HR |
| `terminated` | Benefit has been terminated | Manually set by HR |

**Auto-Update Logic:**
- Status automatically updates when `step` or relevant timestamps change
- When `step` is set to NULL, status is automatically set to NULL
- `insurance_claim` and `terminated` statuses are manually set and protected from auto-updates

### 2. Contract Status (`contract_status`)

Tracks the contract signing workflow from creation to approval.

**Enum Values:**

| Status | Description | Trigger Condition |
|--------|-------------|-------------------|
| `not_started` | Contract not yet generated | Default state |
| `viewed_by_employee` | Employee has opened the contract | `contract_viewed_at` IS NOT NULL |
| `signed_by_employee` | Employee has signed | `contract_employee_signed_at` IS NOT NULL |
| `signed_by_employer` | Employer has signed (after employee) | `contract_employer_signed_at` IS NOT NULL |
| `approved` | Both parties signed, contract active | `contract_approved_at` IS NOT NULL |
| `terminated` | Contract is terminated | Manually set by HR |

**Auto-Update Logic:**
- Status automatically updates when contract timestamps change
- `terminated` status is manually set and protected from auto-updates

## Database Schema

### New Columns in `bike_benefits` Table

```sql
-- Status fields
benefit_status          benefit_status           NULL (nullable, NULL when not started)
contract_status         contract_status          NOT NULL DEFAULT 'not_started'

-- Contract tracking timestamps
contract_viewed_at              TIMESTAMPTZ
contract_employee_signed_at     TIMESTAMPTZ
contract_employer_signed_at     TIMESTAMPTZ
contract_approved_at            TIMESTAMPTZ
contract_terminated_at          TIMESTAMPTZ

-- Benefit status tracking timestamps
benefit_terminated_at           TIMESTAMPTZ
benefit_insurance_claim_at      TIMESTAMPTZ
```

## Frontend Usage Examples

### For HR Dashboard

#### 1. Get All Employees with Status Summary

```javascript
const { data: employees } = await supabase
  .from('profile_invites_with_details')
  .select(`
    email,
    profile_status,
    benefit_status,
    contract_status,
    current_step,
    bike_name,
    invited_at,
    registered_at
  `)
  .order('invited_at', { ascending: false });
```

#### 2. Filter by Benefit Status

```javascript
// Get all employees in 'testing' phase
const { data: testingEmployees } = await supabase
  .from('profile_invites_with_details')
  .select('*')
  .eq('benefit_status', 'testing')
  .order('live_test_whatsapp_sent_at', { ascending: false });
```

#### 3. Filter by Contract Status

```javascript
// Get all contracts waiting for employer signature
const { data: pendingContracts } = await supabase
  .from('profile_invites_with_details')
  .select(`
    email,
    contract_status,
    bike_name,
    contract_employee_signed_at
  `)
  .eq('contract_status', 'signed_by_employee')
  .order('contract_employee_signed_at', { ascending: false });
```

#### 4. Get Status Summary Counts

```javascript
const { data: statusSummary } = await supabase
  .from('profile_invites_with_details')
  .select('benefit_status')
  .not('benefit_status', 'is', null);

// Count locally or use a stored function
const counts = statusSummary.reduce((acc, row) => {
  acc[row.benefit_status] = (acc[row.benefit_status] || 0) + 1;
  return acc;
}, {});

// Result: { inactive: 5, searching: 10, testing: 3, active: 15, ... }
```

### For Employee View

#### 1. Get Current Benefit Status

```javascript
const { data: myBenefit } = await supabase
  .from('bike_benefits')
  .select(`
    benefit_status,
    contract_status,
    step,
    bike:bikes(name, brand, image_url)
  `)
  .eq('user_id', userId)
  .single();
```

### Updating Statuses

#### 1. Employee Views Contract (Auto-updates to 'viewed_by_employee')

```javascript
const { error } = await supabase
  .from('bike_benefits')
  .update({ contract_viewed_at: new Date().toISOString() })
  .eq('id', benefitId);

// contract_status automatically updates to 'viewed_by_employee'
```

#### 2. Employee Signs Contract (Auto-updates to 'signed_by_employee')

```javascript
const { error } = await supabase
  .from('bike_benefits')
  .update({ contract_employee_signed_at: new Date().toISOString() })
  .eq('id', benefitId);

// contract_status automatically updates to 'signed_by_employee'
```

#### 3. HR Signs Contract (Auto-updates to 'approved')

```javascript
const { error } = await supabase
  .from('bike_benefits')
  .update({ 
    contract_employer_signed_at: new Date().toISOString(),
    contract_approved_at: new Date().toISOString()
  })
  .eq('id', benefitId);

// contract_status automatically updates to 'approved'
```

#### 4. HR Terminates Benefit (Manual update)

```javascript
const { error } = await supabase
  .from('bike_benefits')
  .update({ 
    benefit_status: 'terminated',
    benefit_terminated_at: new Date().toISOString()
  })
  .eq('id', benefitId);

// benefit_status stays 'terminated' even if step changes
```

#### 5. HR Files Insurance Claim (Manual update)

```javascript
const { error } = await supabase
  .from('bike_benefits')
  .update({ 
    benefit_status: 'insurance_claim',
    benefit_insurance_claim_at: new Date().toISOString()
  })
  .eq('id', benefitId);

// benefit_status stays 'insurance_claim' even if step changes
```

## UI Display Recommendations

### Benefit Status Colors

| Status | Color | Badge Style |
|--------|-------|-------------|
| inactive | Gray | Secondary |
| searching | Blue | Info |
| testing | Orange | Warning |
| active | Green | Success |
| insurance_claim | Red | Error |
| terminated | Dark Gray | Default |

### Contract Status Colors

| Status | Color | Badge Style |
|--------|-------|-------------|
| not_started | Gray | Secondary |
| viewed_by_employee | Blue | Info |
| signed_by_employee | Light Blue | Info |
| signed_by_employer | Yellow | Warning |
| approved | Green | Success |
| terminated | Red | Error |

### Sample React Component

```tsx
const BenefitStatusBadge = ({ status }: { status: BenefitStatus | null }) => {
  // Handle NULL status (benefit not started)
  if (!status) {
    return (
      <span className="badge badge-gray">
        Not Started
      </span>
    );
  }

  const config = {
    inactive: { label: 'Inactive', color: 'gray' },
    searching: { label: 'Searching', color: 'blue' },
    testing: { label: 'Testing', color: 'orange' },
    active: { label: 'Active', color: 'green' },
    insurance_claim: { label: 'Insurance Claim', color: 'red' },
    terminated: { label: 'Terminated', color: 'darkgray' },
  };

  const { label, color } = config[status];

  return (
    <span className={`badge badge-${color}`}>
      {label}
    </span>
  );
};

const ContractStatusBadge = ({ status }: { status: ContractStatus }) => {
  const config = {
    not_started: { label: 'Not Started', color: 'gray' },
    viewed_by_employee: { label: 'Viewed by Employee', color: 'blue' },
    signed_by_employee: { label: 'Signed by Employee', color: 'lightblue' },
    signed_by_employer: { label: 'Signed by Employer', color: 'yellow' },
    approved: { label: 'Approved', color: 'green' },
    terminated: { label: 'Terminated', color: 'red' },
  };

  const { label, color } = config[status];

  return (
    <span className={`badge badge-${color}`}>
      {label}
    </span>
  );
};
```

## Migration Notes

### Running the Migration

```bash
# Apply the migration
supabase db push

# Or if using migration files
supabase migration up
```

### Existing Data

- All existing `bike_benefits` records will be automatically updated with appropriate statuses based on their current `step` and timestamp values
- If a benefit has `step = 'pickup_delivery'` and `delivered_at` is set, it will be marked as `active`
- If `contract_requested_at` is set, contract_status will be set to `viewed_by_employee`

## Troubleshooting

### Status Not Updating Automatically

If status is not updating when you change step or timestamps:

1. Check if status is manually set to `terminated` or `insurance_claim` - these are protected
2. Verify triggers are active:
   ```sql
   SELECT * FROM pg_trigger WHERE tgname LIKE '%benefit%status%';
   ```

### Manual Status Override

If you need to manually set a status:

```sql
-- Temporarily disable triggers
ALTER TABLE bike_benefits DISABLE TRIGGER update_benefit_status_on_change;

-- Update status
UPDATE bike_benefits SET benefit_status = 'active' WHERE id = 'your-id';

-- Re-enable triggers
ALTER TABLE bike_benefits ENABLE TRIGGER update_benefit_status_on_change;
```

## Testing

### Test Scenarios

1. **Create new benefit**: Should start with `inactive` status
2. **Employee chooses bike**: Update `step = 'choose_bike'` → status should become `searching`
3. **Book live test**: Update `step = 'book_live_test'` and `live_test_whatsapp_sent_at` → status should become `testing`
4. **Delivery**: Update `step = 'pickup_delivery'` and `delivered_at` → status should become `active`
5. **Contract workflow**: 
   - Set `contract_viewed_at` → `viewed_by_employee`
   - Set `contract_employee_signed_at` → `signed_by_employee`
   - Set `contract_employer_signed_at` → `signed_by_employer`
   - Set `contract_approved_at` → `approved`

## Additional Resources

- [Database README](./README.md)
- [Migration Files](../supabase/migrations/)
- [Supabase Documentation](https://supabase.com/docs)
