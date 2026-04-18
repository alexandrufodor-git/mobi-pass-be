-- TBI Bank loan integration: enum, table, indexes, trigger, RLS

-- Enum for loan application status
CREATE TYPE public.tbi_loan_status AS ENUM ('pending', 'approved', 'rejected', 'canceled');

-- Table
CREATE TABLE public.tbi_loan_applications (
    id              uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    profile_id      uuid NOT NULL REFERENCES public.profiles(user_id) ON DELETE CASCADE,
    bike_benefit_id uuid NOT NULL REFERENCES public.bike_benefits(id) ON DELETE CASCADE,
    order_id        text UNIQUE NOT NULL,
    order_total     numeric(10,2) NOT NULL,
    status          public.tbi_loan_status DEFAULT 'pending' NOT NULL,
    rejection_reason text,
    redirect_url    text,
    tbi_response    jsonb,
    created_at      timestamptz DEFAULT now(),
    updated_at      timestamptz DEFAULT now()
);

-- Indexes
CREATE INDEX idx_tbi_loan_apps_profile ON public.tbi_loan_applications(profile_id);
CREATE INDEX idx_tbi_loan_apps_order   ON public.tbi_loan_applications(order_id);
CREATE INDEX idx_tbi_loan_apps_benefit ON public.tbi_loan_applications(bike_benefit_id);

-- updated_at trigger (reuse existing function)
CREATE TRIGGER update_tbi_loan_apps_updated_at
    BEFORE UPDATE ON public.tbi_loan_applications
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- RLS
ALTER TABLE public.tbi_loan_applications ENABLE ROW LEVEL SECURITY;

-- Employee can read own loan applications
CREATE POLICY tbi_loan_employee_select ON public.tbi_loan_applications
    FOR SELECT TO authenticated
    USING (profile_id = auth.uid());

-- HR/Admin can read loan applications for their company
CREATE POLICY tbi_loan_hr_select ON public.tbi_loan_applications
    FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles ur
            WHERE ur.user_id = auth.uid()
            AND ur.role IN ('hr', 'admin')
        )
        AND EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.user_id = tbi_loan_applications.profile_id
            AND p.company_id = public.auth_company_id()
        )
    );

-- No client INSERT/UPDATE/DELETE — all writes via service_role in edge functions
