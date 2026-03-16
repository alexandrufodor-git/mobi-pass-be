-- =============================================================
-- Migration 1: Extract dealers table and migrate data
-- =============================================================

-- 1. Create dealers table
CREATE TABLE public.dealers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  address text,
  location_coords text,
  phone text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.dealers OWNER TO postgres;

COMMENT ON COLUMN public.dealers.location_coords IS 'Dealer location in "lon,lat" format for test rides and pickup';

-- 2. Insert the single known dealer
INSERT INTO public.dealers (name, address, location_coords, phone)
VALUES (
  'Maros Bike',
  'Cluj Napoca str. Aurel Vlaicu Nr. 25',
  '23.62565635434891,46.780762423563985',
  '+40741077495'
);

-- 3. Add dealer_id FK to bikes (nullable initially)
ALTER TABLE public.bikes ADD COLUMN dealer_id uuid REFERENCES public.dealers(id);

-- 4. Backfill all existing bikes to point to the dealer
UPDATE public.bikes
SET dealer_id = (SELECT id FROM public.dealers LIMIT 1);

-- 5. Make dealer_id NOT NULL
ALTER TABLE public.bikes ALTER COLUMN dealer_id SET NOT NULL;

-- 6. Drop the view that depends on the old dealer columns
DROP VIEW IF EXISTS public.bikes_with_my_pricing;

-- 7. Drop old embedded dealer columns
ALTER TABLE public.bikes
  DROP COLUMN dealer_name,
  DROP COLUMN dealer_address,
  DROP COLUMN dealer_location_coords;

-- 8. Enable RLS on dealers
ALTER TABLE public.dealers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can view dealers"
  ON public.dealers
  FOR SELECT
  TO authenticated
  USING (true);

-- 9. Recreate bikes_with_my_pricing view with dealer JOIN
CREATE OR REPLACE VIEW public.bikes_with_my_pricing
WITH (security_invoker = on) AS
SELECT
  b.id,
  b.name,
  b.created_at,
  b.updated_at,
  b.brand,
  b.description,
  b.image_url,
  b.full_price,
  b.employee_price,
  b.weight_kg,
  b.charge_time_hours,
  b.range_max_km,
  b.power_wh,
  b.engine,
  b.supported_features,
  b.frame_material,
  b.frame_size,
  b.wheel_size,
  b.wheel_bandwidth,
  b.lock_type,
  b.sku,
  d.name AS dealer_name,
  d.address AS dealer_address,
  d.location_coords AS dealer_location_coords,
  d.phone AS dealer_phone,
  b.available_for_test,
  b.in_stock,
  b.type,
  b.images,
  c.monthly_benefit_subsidy,
  c.contract_months,
  c.contract_months AS employee_contract_month,
  c.currency,
  prices.employee_price AS employee_full_price,
  prices.monthly_employee_price AS employee_monthly_price
FROM public.bikes b
  JOIN public.dealers d ON d.id = b.dealer_id
  LEFT JOIN public.profiles me ON me.user_id = auth.uid()
  LEFT JOIN public.companies c ON c.id = me.company_id
  LEFT JOIN LATERAL public.calc_employee_prices(
    b.full_price, c.monthly_benefit_subsidy, c.contract_months
  ) prices(employee_price, monthly_employee_price) ON true;

COMMENT ON VIEW public.bikes_with_my_pricing IS 'Bike catalog with employee-specific pricing and dealer info. Uses auth.uid() to resolve the calling user''s company subsidy and contract terms automatically. Returns all bikes; pricing columns are NULL when the user has no linked company.';

-- =============================================================
-- Migration 2: Add onboarding_status to profiles + trigger logic
-- =============================================================

-- 1. Add onboarding_status column to profiles
ALTER TABLE public.profiles ADD COLUMN onboarding_status boolean DEFAULT false;

-- 2. Replace update_bike_benefit_status() with onboarding_status logic
CREATE OR REPLACE FUNCTION public.update_bike_benefit_status() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  -- HR terminal states: never overwrite automatically
  IF TG_OP = 'UPDATE'
     AND OLD.benefit_status IN (
       'insurance_claim'::public.benefit_status,
       'terminated'::public.benefit_status
     ) THEN
    RETURN NEW;
  END IF;

  -- Snap currency + contract_months only on new benefit creation
  IF TG_OP = 'INSERT' THEN
    SELECT t.currency, t.contract_months
    INTO   NEW.employee_currency, NEW.employee_contract_months
    FROM   public.get_company_terms_for_user(NEW.user_id) t;
  END IF;

  IF NEW.step IS NULL THEN
    NEW.benefit_status := 'inactive'::public.benefit_status;

  ELSIF NEW.step = 'choose_bike'::public.bike_benefit_step THEN
    IF TG_OP = 'UPDATE'
       AND (OLD.step IS NULL OR OLD.step <> 'choose_bike'::public.bike_benefit_step) THEN
      NEW.live_test_whatsapp_sent_at  := NULL;
      NEW.live_test_checked_in_at     := NULL;
      NEW.committed_at                := NULL;
      NEW.contract_requested_at       := NULL;
      NEW.contract_viewed_at          := NULL;
      NEW.contract_employee_signed_at := NULL;
      NEW.contract_employer_signed_at := NULL;
      NEW.contract_approved_at        := NULL;
      NEW.contract_declined_at        := NULL;
      NEW.delivered_at                := NULL;
      NEW.contract_status             := NULL;
      NEW.employee_full_price         := NULL;
      NEW.employee_monthly_price      := NULL;
      NEW.employee_contract_months    := NULL;
      DELETE FROM public.bike_orders WHERE bike_benefit_id = NEW.id;
      DELETE FROM public.contracts WHERE bike_benefit_id = NEW.id;
      -- Reset onboarding status when going back to choose_bike
      UPDATE public.profiles SET onboarding_status = false WHERE user_id = NEW.user_id;
    END IF;
    NEW.benefit_status := 'searching'::public.benefit_status;

  ELSIF NEW.step = 'book_live_test'::public.bike_benefit_step THEN
    NEW.benefit_status := 'searching'::public.benefit_status;

  ELSIF NEW.step = 'commit_to_bike'::public.bike_benefit_step THEN
    IF NEW.bike_id IS NOT NULL THEN
      SELECT p.employee_price, p.monthly_employee_price, t.contract_months
      INTO   NEW.employee_full_price, NEW.employee_monthly_price, NEW.employee_contract_months
      FROM         public.bikes b
      JOIN         public.get_company_terms_for_user(NEW.user_id) t ON true
      CROSS JOIN LATERAL public.calc_employee_prices(
                   b.full_price, t.monthly_benefit_subsidy, t.contract_months
                 ) p
      WHERE  b.id = NEW.bike_id;
    END IF;

    IF NEW.live_test_whatsapp_sent_at IS NOT NULL THEN
      NEW.benefit_status := 'testing'::public.benefit_status;
    ELSE
      NEW.benefit_status := 'searching'::public.benefit_status;
    END IF;

  ELSIF NEW.step = 'sign_contract'::public.bike_benefit_step THEN
    IF NEW.committed_at IS NOT NULL THEN
      NEW.benefit_status := 'active'::public.benefit_status;
    ELSE
      NEW.benefit_status := COALESCE(OLD.benefit_status, 'searching'::public.benefit_status);
    END IF;

  ELSIF NEW.step = 'pickup_delivery'::public.bike_benefit_step THEN
    NEW.benefit_status := COALESCE(OLD.benefit_status, 'active'::public.benefit_status);

  END IF;

  -- Mark onboarding complete when delivered_at is set
  IF TG_OP = 'UPDATE'
     AND OLD.delivered_at IS NULL
     AND NEW.delivered_at IS NOT NULL THEN
    UPDATE public.profiles SET onboarding_status = true WHERE user_id = NEW.user_id;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.update_bike_benefit_status() IS 'Auto-updates benefit_status on step / timestamp changes.
Terminal-state guard: once HR sets insurance_claim or terminated, any
subsequent step/timestamp updates are ignored until HR explicitly changes it.
choose_bike resets all downstream timestamps, contract_status, pricing,
deletes related bike_orders and contracts rows, and resets onboarding_status.
Sets onboarding_status = true when delivered_at transitions from NULL to non-NULL.';
