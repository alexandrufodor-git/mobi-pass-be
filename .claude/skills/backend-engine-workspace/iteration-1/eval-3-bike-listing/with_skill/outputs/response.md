# Getting Bikes with Pricing for the Current User

## The Short Version

Query the `bikes_with_my_pricing` view. It returns all bikes with pricing automatically calculated for the logged-in user based on their company's subsidy and contract terms. No extra joins or parameters needed — the view resolves the user from the JWT internally.

## REST Call

```
GET /rest/v1/bikes_with_my_pricing?select=*
Authorization: Bearer <user-jwt>
apikey: <anon-key>
```

That's it. The view uses `auth.uid()` behind the scenes to look up the user's company, pull `monthly_benefit_subsidy` and `contract_months`, and compute personalized pricing.

## What You Get Back

Each row contains:

| Field | Description |
|---|---|
| `id` | Bike UUID |
| `name` | Bike name |
| `brand` | Bike brand |
| `type` | Bike type enum (e.g. `e_city_bike`, `e_mtb_hardtail_29`) |
| `full_price` | Retail price |
| `employee_full_price` | Total the employee pays after subsidy (full_price minus monthly_subsidy * contract_months, minimum 0) |
| `employee_monthly_price` | `employee_full_price / contract_months` |
| `monthly_benefit_subsidy` | The company's monthly subsidy amount |
| `contract_months` | Contract duration from company terms |
| `currency` | Currency code from company config |
| `image_url` | Primary image URL |
| `images` | JSON array of additional images |
| `description` | Bike description |
| `weight_kg` | Weight in kg |
| `charge_time_hours` | Charge time |
| `range_max_km` | Max range in km |
| `power_wh` | Motor power in watt-hours |
| `engine` | Engine description |
| `frame_material` | Frame material |
| `frame_size` | Frame size |
| `wheel_size` | Wheel size |
| `wheel_bandwidth` | Wheel bandwidth |
| `lock_type` | Lock type |
| `supported_features` | Features description |
| `sku` | SKU code |
| `available_for_test` | Whether test rides are available |
| `in_stock` | Stock availability |
| `dealer_name` | Dealer name |
| `dealer_address` | Dealer address |
| `dealer_phone` | Dealer phone number |
| `dealer_location_coords` | Dealer GPS coordinates |

## Filtering and Pagination

Filter by bike type:

```
GET /rest/v1/bikes_with_my_pricing?select=*&type=eq.e_city_bike
```

Only in-stock bikes:

```
GET /rest/v1/bikes_with_my_pricing?select=*&in_stock=eq.true
```

Paginate with Range header:

```
GET /rest/v1/bikes_with_my_pricing?select=*&order=full_price.asc
Range: 0-19
```

Select only the fields you need (recommended for the list screen):

```
GET /rest/v1/bikes_with_my_pricing?select=id,name,brand,type,image_url,full_price,employee_monthly_price,currency,in_stock,dealer_name
```

## Pricing Logic

The view calculates pricing using the `calc_employee_prices` function:

```
employee_full_price = max(0, full_price - (monthly_benefit_subsidy * contract_months))
employee_monthly_price = employee_full_price / contract_months
```

If the user has no linked company (e.g. profile not yet fully set up), the pricing columns (`employee_full_price`, `employee_monthly_price`, `monthly_benefit_subsidy`, `contract_months`, `currency`) will be `null`. Handle this in your UI — you can still show the bike catalog with `full_price` and display a message that personalized pricing is unavailable.

## Auth Requirement

The user must be authenticated. Pass the JWT in the `Authorization: Bearer` header. The view's `security_invoker` setting means RLS policies apply: employees can SELECT all bikes, so every authenticated user sees the full catalog.
