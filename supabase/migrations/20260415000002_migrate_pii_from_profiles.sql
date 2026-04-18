-- Migrate PII data from profiles to employee_pii, drop columns, drop view.
--
-- NOTE: Data is inserted as PLAINTEXT into the _encrypted columns.
-- A post-deploy edge function call will encrypt these values.
-- The get-employee-details function uses safeDecrypt() to handle
-- both plaintext (migration) and encrypted (normal) values.

-- ════════════════════════════════════════════════════════════════════════════════
-- 1. Drop user_profile_detail view FIRST (it depends on profiles.home_lat/lon)
--    Replaced by get-employee-details edge function.
-- ════════════════════════════════════════════════════════════════════════════════
DROP VIEW IF EXISTS public.user_profile_detail;

-- ════════════════════════════════════════════════════════════════════════════════
-- 2. Copy home_address / home_lat / home_lon to employee_pii
-- ════════════════════════════════════════════════════════════════════════════════
INSERT INTO public.employee_pii (
    user_id,
    company_id,
    home_address_encrypted,
    home_lat_encrypted,
    home_lon_encrypted,
    source
)
SELECT
    p.user_id,
    p.company_id,
    p.home_address,
    p.home_lat::text,
    p.home_lon::text,
    'migration'
FROM public.profiles p
WHERE p.home_address IS NOT NULL
   OR p.home_lat IS NOT NULL
   OR p.home_lon IS NOT NULL;

-- ════════════════════════════════════════════════════════════════════════════════
-- 3. Drop PII columns from profiles (safe now that view is gone)
-- ════════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.profiles DROP COLUMN IF EXISTS home_address;
ALTER TABLE public.profiles DROP COLUMN IF EXISTS home_lat;
ALTER TABLE public.profiles DROP COLUMN IF EXISTS home_lon;
