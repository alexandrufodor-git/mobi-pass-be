-- PII Security Foundation: employee_pii, labor_contracts, integration_configs, integration_messages
-- All PII fields are encrypted at the application level (AES-256-GCM) before INSERT.
-- Writes happen via service_role in edge functions only — no direct INSERT/UPDATE/DELETE by users.

-- ════════════════════════════════════════════════════════════════════════════════
-- 1. employee_pii — centralised sensitive employee data
-- ════════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.employee_pii (
    id                          uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id                     uuid NOT NULL REFERENCES public.profiles(user_id) ON DELETE CASCADE,
    company_id                  uuid NOT NULL REFERENCES public.companies(id),

    -- Encrypted fields (AES-256-GCM, stored as base64 TEXT)
    national_id_encrypted       text,          -- CNP (RO), PESEL (PL), SSN (US), BSN (NL)
    date_of_birth_encrypted     text,          -- ISO date string
    phone_encrypted             text,          -- Phone number
    home_address_encrypted      text,          -- Full street address
    home_lat_encrypted          text,          -- Latitude as string
    home_lon_encrypted          text,          -- Longitude as string
    salary_gross_encrypted      text,          -- Gross monthly salary

    -- Non-encrypted metadata
    country                     text NOT NULL DEFAULT 'RO',   -- ISO 3166-1 alpha-2
    nationality_iso             text,                         -- ISO country code
    country_of_domicile_iso     text,                         -- ISO country code
    id_document_type            text,                         -- national_id_card, passport, residence_permit
    locality_code               text,                         -- SIRUTA (RO), TERYT (PL), ZIP (US)
    locality_code_system        text,                         -- 'siruta', 'teryt', 'zip'
    salary_currency             text DEFAULT 'RON',
    education_level             text,

    -- Source tracking
    source                      text,                         -- 'reges', 'tbi', 'csv', 'manual', 'klarna', 'migration'
    source_ref_id               text,                         -- External system's reference ID

    -- Timestamps
    created_at                  timestamptz DEFAULT now() NOT NULL,
    updated_at                  timestamptz DEFAULT now() NOT NULL,

    CONSTRAINT employee_pii_user_unique UNIQUE (user_id)
);

CREATE INDEX idx_employee_pii_company ON public.employee_pii(company_id);

-- RLS
ALTER TABLE public.employee_pii ENABLE ROW LEVEL SECURITY;

-- Employee can SELECT own record
CREATE POLICY employee_pii_self_select ON public.employee_pii
    FOR SELECT TO authenticated
    USING (user_id = auth.uid());

-- HR/Admin can SELECT records in their company
CREATE POLICY employee_pii_hr_select ON public.employee_pii
    FOR SELECT TO authenticated
    USING (
        (auth.jwt() ->> 'user_role') IN ('hr', 'admin')
        AND company_id = public.auth_company_id()
    );

-- No INSERT/UPDATE/DELETE policies for authenticated users.
-- All writes go through service_role in edge functions.

-- updated_at trigger
CREATE TRIGGER update_employee_pii_updated_at
    BEFORE UPDATE ON public.employee_pii
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


-- ════════════════════════════════════════════════════════════════════════════════
-- 2. labor_contracts — government-reportable employment contracts
-- ════════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.labor_contracts (
    id                      uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id                 uuid NOT NULL REFERENCES public.profiles(user_id) ON DELETE CASCADE,
    company_id              uuid NOT NULL REFERENCES public.companies(id),
    employee_pii_id         uuid NOT NULL REFERENCES public.employee_pii(id) ON DELETE CASCADE,

    -- Contract identity
    contract_number         text,
    contract_date           date,
    start_date              date,
    end_date                date,              -- NULL = undetermined duration

    -- Classification
    contract_type           text,              -- CIM, temporary, mandate, etc.
    duration_type           text,              -- determined, undetermined
    norm_type               text,              -- full_time, part_time
    work_schedule           jsonb,             -- hours, shifts, repartition details
    work_location_type      text,              -- fixed, mobile
    work_county             text,              -- County/state code
    work_locality_code      text,              -- SIRUTA, ZIP, etc.

    -- Occupation
    occupation_code         text,              -- COR (RO), ISCO, SOC (US)
    occupation_code_system  text,              -- 'cor', 'isco', 'soc'
    occupation_code_version int,

    -- Status
    status                  text DEFAULT 'active',  -- active, suspended, terminated

    -- Source tracking
    source                  text,              -- 'reges', 'manual', 'csv'
    source_ref_id           text,              -- REGES contract UUID, etc.

    -- Timestamps
    created_at              timestamptz DEFAULT now() NOT NULL,
    updated_at              timestamptz DEFAULT now() NOT NULL
);

CREATE INDEX idx_labor_contracts_user    ON public.labor_contracts(user_id);
CREATE INDEX idx_labor_contracts_company ON public.labor_contracts(company_id);
CREATE INDEX idx_labor_contracts_pii     ON public.labor_contracts(employee_pii_id);

-- RLS
ALTER TABLE public.labor_contracts ENABLE ROW LEVEL SECURITY;

CREATE POLICY labor_contracts_self_select ON public.labor_contracts
    FOR SELECT TO authenticated
    USING (user_id = auth.uid());

CREATE POLICY labor_contracts_hr_select ON public.labor_contracts
    FOR SELECT TO authenticated
    USING (
        (auth.jwt() ->> 'user_role') IN ('hr', 'admin')
        AND company_id = public.auth_company_id()
    );

CREATE TRIGGER update_labor_contracts_updated_at
    BEFORE UPDATE ON public.labor_contracts
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


-- ════════════════════════════════════════════════════════════════════════════════
-- 3. integration_configs — per-company config for external integrations
-- ════════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.integration_configs (
    id              uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    company_id      uuid NOT NULL REFERENCES public.companies(id),
    integration     text NOT NULL,          -- 'reges', 'tbi', 'klarna', 'esignatures'
    config          jsonb DEFAULT '{}'::jsonb, -- Non-secret config (CUI, CAEN code, etc.)
    enabled         boolean DEFAULT false,
    created_at      timestamptz DEFAULT now() NOT NULL,
    updated_at      timestamptz DEFAULT now() NOT NULL,

    CONSTRAINT integration_configs_company_integration_unique
        UNIQUE (company_id, integration)
);

-- RLS
ALTER TABLE public.integration_configs ENABLE ROW LEVEL SECURITY;

CREATE POLICY integration_configs_hr_select ON public.integration_configs
    FOR SELECT TO authenticated
    USING (
        (auth.jwt() ->> 'user_role') IN ('hr', 'admin')
        AND company_id = public.auth_company_id()
    );

CREATE TRIGGER update_integration_configs_updated_at
    BEFORE UPDATE ON public.integration_configs
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


-- ════════════════════════════════════════════════════════════════════════════════
-- 4. integration_messages — audit log for ALL external API communications
-- ════════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.integration_messages (
    id                  uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    company_id          uuid NOT NULL REFERENCES public.companies(id),
    integration         text NOT NULL,          -- 'reges', 'tbi', 'esignatures', 'klarna'
    message_id          uuid,                   -- Client-generated per request
    operation           text NOT NULL,           -- 'InregistrareSalariat', 'LoanApplication', etc.
    entity_type         text,                   -- 'employee_pii', 'labor_contract', 'tbi_loan'
    entity_id           uuid,                   -- FK to the entity (not enforced, cross-table)
    direction           text NOT NULL DEFAULT 'outbound',  -- 'outbound' or 'inbound'
    request_payload     jsonb,                  -- What we sent (encrypted fields stay encrypted)
    response_id         text,                   -- Receipt/ID from external system
    result_code         text,                   -- success, fail, pending, warning
    result_payload      jsonb,                  -- What they returned
    status              text DEFAULT 'pending', -- pending, success, failed, retrying
    created_at          timestamptz DEFAULT now() NOT NULL,
    processed_at        timestamptz
);

CREATE INDEX idx_integration_messages_company     ON public.integration_messages(company_id);
CREATE INDEX idx_integration_messages_integration ON public.integration_messages(integration);
CREATE INDEX idx_integration_messages_entity      ON public.integration_messages(entity_type, entity_id);

-- RLS
ALTER TABLE public.integration_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY integration_messages_hr_select ON public.integration_messages
    FOR SELECT TO authenticated
    USING (
        (auth.jwt() ->> 'user_role') IN ('hr', 'admin')
        AND company_id = public.auth_company_id()
    );

-- Grant access to tables
GRANT ALL ON TABLE public.employee_pii          TO anon, authenticated, service_role;
GRANT ALL ON TABLE public.labor_contracts       TO anon, authenticated, service_role;
GRANT ALL ON TABLE public.integration_configs   TO anon, authenticated, service_role;
GRANT ALL ON TABLE public.integration_messages  TO anon, authenticated, service_role;
