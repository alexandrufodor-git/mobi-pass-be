-- ============================================================================
-- Add days_in_office to companies — number of days per week employees
-- commute to the office. Used for estimating distance, calories, CO2, etc.
-- ============================================================================

ALTER TABLE public.companies ADD COLUMN days_in_office integer DEFAULT 5;

COMMENT ON COLUMN public.companies.days_in_office IS 'Number of days per week employees commute to the office (1-7). Used for dashboard estimations (distance, calories, CO2, fuel saved).';
