-- Create bikes table
CREATE TABLE public.bikes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Create bike benefit step enum (nullable, set when user starts)
CREATE TYPE public.bike_benefit_step AS ENUM (
  'choose_bike',        -- Step 1: Choose an eBike
  'book_live_test',     -- Step 2: Book a live test
  'commit_to_bike',     -- Step 3: Commit to your eBike
  'sign_contract',      -- Step 4: Sign your contract
  'pickup_delivery'     -- Step 5: eBike pickup / delivery
);

-- Create bike_benefits table
CREATE TABLE public.bike_benefits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(user_id) ON DELETE CASCADE,
  bike_id UUID REFERENCES public.bikes(id) ON DELETE SET NULL,
  step public.bike_benefit_step,  -- Nullable, set when user presses "Start now"
  -- Book live test details
  live_test_location TEXT,
  live_test_whatsapp_sent_at TIMESTAMPTZ,
  live_test_checked_in_at TIMESTAMPTZ,
  -- Commit step details
  committed_at TIMESTAMPTZ,
  checked_in_at TIMESTAMPTZ,
  -- Sign step details
  contract_requested_at TIMESTAMPTZ,
  -- Pickup/delivery step details
  delivered_at TIMESTAMPTZ,
  -- Other step details
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Create bike_orders table
CREATE TABLE public.bike_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(user_id) ON DELETE CASCADE,
  bike_benefit_id UUID NOT NULL REFERENCES public.bike_benefits(id) ON DELETE CASCADE,
  
  helmet BOOLEAN NOT NULL DEFAULT false,
  insurance BOOLEAN NOT NULL DEFAULT false,
  
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  
  -- Ensure one order per benefit
  CONSTRAINT unique_benefit_order UNIQUE (bike_benefit_id)
);

-- Create indexes for better query performance
CREATE INDEX idx_bike_benefits_user_id ON public.bike_benefits(user_id);
CREATE INDEX idx_bike_benefits_step ON public.bike_benefits(step);
CREATE INDEX idx_bike_benefits_bike_id ON public.bike_benefits(bike_id);
CREATE INDEX idx_bike_orders_user_id ON public.bike_orders(user_id);
CREATE INDEX idx_bike_orders_bike_benefit_id ON public.bike_orders(bike_benefit_id);
CREATE INDEX idx_bikes_name ON public.bikes(name);

-- Enable RLS
ALTER TABLE public.bikes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bike_benefits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bike_orders ENABLE ROW LEVEL SECURITY;

-- ============================================
-- RLS Policies for bikes table
-- ============================================

-- Policy: All authenticated users can view bikes
CREATE POLICY "bikes_authenticated_select" 
  ON public.bikes 
  FOR SELECT 
  TO authenticated 
  USING (true);

-- Policy: Only HR/Admin can insert bikes
CREATE POLICY "bikes_hr_insert" 
  ON public.bikes 
  FOR INSERT 
  TO authenticated 
  WITH CHECK (
    (auth.jwt() ->> 'user_role'::text) IN ('hr', 'admin')
  );

-- Policy: Only HR/Admin can update bikes
CREATE POLICY "bikes_hr_update" 
  ON public.bikes 
  FOR UPDATE 
  TO authenticated 
  USING (
    (auth.jwt() ->> 'user_role'::text) IN ('hr', 'admin')
  );

-- ============================================
-- RLS Policies for bike_benefits
-- ============================================

-- Policy: Employees can view their own benefits
CREATE POLICY "bike_benefits_employee_select" 
  ON public.bike_benefits 
  FOR SELECT 
  TO authenticated 
  USING (
    user_id = auth.uid()
  );

-- Policy: Employees can insert their own benefits
CREATE POLICY "bike_benefits_employee_insert" 
  ON public.bike_benefits 
  FOR INSERT 
  TO authenticated 
  WITH CHECK (
    user_id = auth.uid()
  );

-- Policy: Employees can update their own benefits
CREATE POLICY "bike_benefits_employee_update" 
  ON public.bike_benefits 
  FOR UPDATE 
  TO authenticated 
  USING (
    user_id = auth.uid()
  )
  WITH CHECK (
    user_id = auth.uid()
  );

-- Policy: HR/Admin can view all benefits in their company
CREATE POLICY "bike_benefits_hr_select" 
  ON public.bike_benefits 
  FOR SELECT 
  TO authenticated 
  USING (
    (auth.jwt() ->> 'user_role'::text) IN ('hr', 'admin')
    AND user_id IN (
      SELECT p.user_id 
      FROM public.profiles p
      JOIN public.profiles my_profile ON my_profile.user_id = auth.uid()
      WHERE p.company_id = my_profile.company_id
    )
  );

-- Policy: HR/Admin can update all benefits in their company
CREATE POLICY "bike_benefits_hr_update" 
  ON public.bike_benefits 
  FOR UPDATE 
  TO authenticated 
  USING (
    (auth.jwt() ->> 'user_role'::text) IN ('hr', 'admin')
    AND user_id IN (
      SELECT p.user_id 
      FROM public.profiles p
      JOIN public.profiles my_profile ON my_profile.user_id = auth.uid()
      WHERE p.company_id = my_profile.company_id
    )
  );

-- ============================================
-- RLS Policies for bike_orders
-- ============================================

-- Policy: Employees can view their own orders
CREATE POLICY "bike_orders_employee_select" 
  ON public.bike_orders 
  FOR SELECT 
  TO authenticated 
  USING (
    user_id = auth.uid()
  );

-- Policy: Employees can insert their own orders
CREATE POLICY "bike_orders_employee_insert" 
  ON public.bike_orders 
  FOR INSERT 
  TO authenticated 
  WITH CHECK (
    user_id = auth.uid()
  );

-- Policy: Employees can update their own orders
CREATE POLICY "bike_orders_employee_update" 
  ON public.bike_orders 
  FOR UPDATE 
  TO authenticated 
  USING (
    user_id = auth.uid()
  )
  WITH CHECK (
    user_id = auth.uid()
  );

-- Policy: HR/Admin can view all orders in their company
CREATE POLICY "bike_orders_hr_select" 
  ON public.bike_orders 
  FOR SELECT 
  TO authenticated 
  USING (
    (auth.jwt() ->> 'user_role'::text) IN ('hr', 'admin')
    AND user_id IN (
      SELECT p.user_id 
      FROM public.profiles p
      JOIN public.profiles my_profile ON my_profile.user_id = auth.uid()
      WHERE p.company_id = my_profile.company_id
    )
  );

-- Policy: HR/Admin can update all orders in their company
CREATE POLICY "bike_orders_hr_update" 
  ON public.bike_orders 
  FOR UPDATE 
  TO authenticated 
  USING (
    (auth.jwt() ->> 'user_role'::text) IN ('hr', 'admin')
    AND user_id IN (
      SELECT p.user_id 
      FROM public.profiles p
      JOIN public.profiles my_profile ON my_profile.user_id = auth.uid()
      WHERE p.company_id = my_profile.company_id
    )
  );

-- ============================================
-- RLS Policies for companies table
-- ============================================

-- Policy: Authenticated users can view their own company
CREATE POLICY "companies_employee_select" 
  ON public.companies 
  FOR SELECT 
  TO authenticated 
  USING (
    id IN (
      SELECT company_id FROM public.profiles WHERE user_id = auth.uid()
    )
  );

-- Policy: HR/Admin can update their own company
CREATE POLICY "companies_hr_update" 
  ON public.companies 
  FOR UPDATE 
  TO authenticated 
  USING (
    (auth.jwt() ->> 'user_role'::text) IN ('hr', 'admin')
    AND id IN (
      SELECT company_id FROM public.profiles WHERE user_id = auth.uid()
    )
  );

-- ============================================
-- Triggers for updated_at
-- ============================================

-- Create trigger function to update updated_at timestamp (if not exists)
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Add triggers for updated_at
CREATE TRIGGER update_bikes_updated_at 
  BEFORE UPDATE ON public.bikes 
  FOR EACH ROW 
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_bike_benefits_updated_at 
  BEFORE UPDATE ON public.bike_benefits 
  FOR EACH ROW 
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_bike_orders_updated_at 
  BEFORE UPDATE ON public.bike_orders 
  FOR EACH ROW 
  EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================
-- Grant permissions
-- ============================================

GRANT ALL ON public.bikes TO authenticated;
GRANT ALL ON public.bike_benefits TO authenticated;
GRANT ALL ON public.bike_orders TO authenticated;
GRANT ALL ON public.bikes TO service_role;
GRANT ALL ON public.bike_benefits TO service_role;
GRANT ALL ON public.bike_orders TO service_role;
