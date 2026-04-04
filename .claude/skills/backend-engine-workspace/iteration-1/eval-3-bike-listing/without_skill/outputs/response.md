# Getting Bikes with Pricing for the Current User

## Use the `bikes_with_my_pricing` view

The backend already provides a dedicated view called `bikes_with_my_pricing` that returns the full bike catalog with employee-specific pricing calculated automatically for the authenticated user. No extra parameters or joins are needed on the client side.

### How it works

The view uses `auth.uid()` internally to:

1. Look up the calling user's profile and company.
2. Read the company's `monthly_benefit_subsidy`, `contract_months`, and `currency`.
3. Calculate personalized pricing via `calc_employee_prices()`.
4. JOIN the dealer table to include dealer info (name, address, coordinates, phone).

### REST endpoint

```
GET /rest/v1/bikes_with_my_pricing
Authorization: Bearer <user-jwt>
apikey: <anon-key>
```

That single request returns all bikes. Each row includes:

| Column | Description |
|--------|-------------|
| `id` | Bike UUID |
| `name` | Bike name |
| `brand` | Brand |
| `type` | Bike type (e-bike category) |
| `description` | Text description |
| `images` | JSONB array of image URLs (typically 5 per bike) |
| `full_price` | Catalog/retail price |
| `employee_full_price` | Price the employee actually pays (after subsidy) |
| `employee_monthly_price` | Monthly cost to the employee |
| `employee_contract_month` | Contract duration in months |
| `monthly_benefit_subsidy` | Company's monthly subsidy amount |
| `currency` | Currency code |
| `weight_kg`, `range_max_km`, `power_wh`, `charge_time_hours` | Specs |
| `engine`, `frame_material`, `frame_size`, `wheel_size` | More specs |
| `supported_features` | Feature list (text) |
| `available_for_test` | Whether the bike can be test-ridden |
| `in_stock` | Stock availability |
| `dealer_name`, `dealer_address`, `dealer_location_coords`, `dealer_phone` | Dealer info |
| `sku` | SKU identifier |

### Pricing formula

```
employee_full_price  = MAX(0, full_price - (monthly_benefit_subsidy x contract_months))
employee_monthly_price = employee_full_price / contract_months
```

Example: a bike with `full_price` = 2999, company subsidy of 72/month over 36 months:
- `employee_full_price` = 2999 - (72 x 36) = 407
- `employee_monthly_price` = 407 / 36 = 11.31

### Selecting specific columns

To reduce payload size for a listing screen, request only the columns you need:

```
GET /rest/v1/bikes_with_my_pricing?select=id,name,brand,type,images,full_price,employee_full_price,employee_monthly_price,currency,frame_size,available_for_test,in_stock
```

### Filtering and sorting

Filter by type:
```
GET /rest/v1/bikes_with_my_pricing?type=eq.mountain
```

Filter in-stock only:
```
GET /rest/v1/bikes_with_my_pricing?in_stock=eq.true
```

Sort by price (ascending):
```
GET /rest/v1/bikes_with_my_pricing?order=employee_full_price.asc.nullslast
```

Combine filters:
```
GET /rest/v1/bikes_with_my_pricing?in_stock=eq.true&order=employee_full_price.asc.nullslast&select=id,name,brand,type,images,full_price,employee_full_price,employee_monthly_price,currency,frame_size
```

### Notes

- **Pricing columns are NULL** when the user has no linked company (e.g., if the profile is incomplete). Handle this on the client by showing the `full_price` as a fallback or displaying a "pricing unavailable" state.
- The `images` column is a JSONB array of CDN URLs (typically 5 images per bike). Use the first element as the listing thumbnail.
- The view has `security_invoker = on`, so RLS policies on the underlying `bikes` table apply. All authenticated users have SELECT access.
- No edge function is needed -- this is a direct REST query against the view.
