# Bike Benefits Database Schema

## Key Tables

### `bikes`
Each row = one bike variant (separate entry per size):
- Basic: `name`, `type`, `brand`, `description`, `image_url`, `sku`
- Pricing: `full_price`, `employee_price` (calculated)
- Specs: `weight_kg`, `charge_time_hours`, `range_max_km`, `power_wh`
- Dealer: `dealer_name`, `dealer_address`, `dealer_location_coords` (format: "lon,lat")
- Details: `engine`, `supported_features` (text), `frame_material`, `frame_size` (single size per row), `wheel_size`, etc.

### `companies`
Company benefit configuration:
- `monthly_benefit_subsidy` - Amount company pays per month (e.g., €72)
- `contract_months` - Contract duration (e.g., 36 months)

### `bike_benefits`
User's bike benefit journey with 5 steps:
- Location: `live_test_location_coords` (format: "lon,lat"), `live_test_location_name`
- Progress: `step`, `committed_at`, `contract_requested_at`, `delivered_at`

### `profile_invites`
Now linked to profiles:
- `user_id` - Links to profile after registration (enables joins)

## Pricing Formula

```
employee_price = full_price - (monthly_benefit_subsidy × contract_months)
monthly_cost = monthly_benefit_subsidy
```

Example: €2999 bike with €72/month subsidy over 36 months:
- Employee pays: €2999 - (€72 × 36) = €407
- Monthly benefit: €72

## Helper Function

```sql
SELECT calculate_employee_bike_price(2999.00, company_id);
```

## Frontend View

Use `profile_invites_with_details` view for HR dashboard - joins invites, profiles, and bike benefits in one query.
