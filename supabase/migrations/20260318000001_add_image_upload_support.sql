-- ============================================================================
-- Image upload support: profile photos + company logos
-- - Adds profile_image_path to profiles, logo_image_path to companies
-- - Creates public storage buckets: avatars, company-logos
-- - Storage RLS: employees own their avatar; HR/admin own company logo
-- - Updates profile_invites_with_details view to include image columns
-- ============================================================================

-- ── 1. Add image path columns ─────────────────────────────────────────────

ALTER TABLE public.profiles  ADD COLUMN profile_image_path text;
ALTER TABLE public.companies ADD COLUMN logo_image_path    text;

-- ── 2. Create storage buckets ─────────────────────────────────────────────

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  ('avatars',       'avatars',       true, 2097152,
   ARRAY['image/jpeg', 'image/png', 'image/webp']),
  ('company-logos', 'company-logos', true, 2097152,
   ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/svg+xml']);

-- ── 3. Storage RLS — avatars bucket ──────────────────────────────────────
-- Path convention: {user_id}  (e.g. "550e8400-e29b-41d4-a716-446655440000")
-- SELECT: public (bucket is public, but explicit policy for authenticated reads)
-- INSERT/UPDATE/DELETE: only the user who owns the path

CREATE POLICY "avatars_public_select"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'avatars');

CREATE POLICY "avatars_owner_insert"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'avatars'
    AND name = auth.uid()::text
  );

CREATE POLICY "avatars_owner_update"
  ON storage.objects FOR UPDATE TO authenticated
  USING (
    bucket_id = 'avatars'
    AND name = auth.uid()::text
  );

CREATE POLICY "avatars_owner_delete"
  ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'avatars'
    AND name = auth.uid()::text
  );

-- ── 4. Storage RLS — company-logos bucket ────────────────────────────────
-- Path convention: {company_id}  (e.g. "550e8400-e29b-41d4-a716-446655440000")
-- SELECT: public
-- INSERT/UPDATE/DELETE: hr or admin of the matching company

CREATE POLICY "company_logos_public_select"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'company-logos');

CREATE POLICY "company_logos_hr_insert"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'company-logos'
    AND auth.jwt() ->> 'user_role' IN ('hr', 'admin')
    AND name = public.auth_company_id()::text
  );

CREATE POLICY "company_logos_hr_update"
  ON storage.objects FOR UPDATE TO authenticated
  USING (
    bucket_id = 'company-logos'
    AND auth.jwt() ->> 'user_role' IN ('hr', 'admin')
    AND name = public.auth_company_id()::text
  );

CREATE POLICY "company_logos_hr_delete"
  ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'company-logos'
    AND auth.jwt() ->> 'user_role' IN ('hr', 'admin')
    AND name = public.auth_company_id()::text
  );

-- ── 5. Trigger: auto-update profiles.profile_image_path on avatar upload ──

CREATE OR REPLACE FUNCTION public.sync_avatar_to_profile()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.bucket_id = 'avatars' THEN
    UPDATE public.profiles
    SET profile_image_path = NEW.name
    WHERE user_id = NEW.name::uuid;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_avatar_upload
  AFTER INSERT OR UPDATE ON storage.objects
  FOR EACH ROW EXECUTE FUNCTION public.sync_avatar_to_profile();

-- ── 6. Rebuild profile_invites_with_details view with image columns ───────

DROP VIEW IF EXISTS public.profile_invites_with_details;

CREATE VIEW public.profile_invites_with_details
  WITH (security_invoker = on)
AS
SELECT
  pi.id                                                       AS invite_id,
  pi.email,
  pi.status                                                   AS invite_status,
  pi.created_at                                               AS invited_at,
  pi.company_id,
  c.name                                                      AS company_name,
  c.logo_image_path,
  p.user_id,
  p.status                                                    AS profile_status,
  p.created_at                                                AS registered_at,
  p.profile_image_path,
  COALESCE(p.first_name,   pi.first_name)                    AS first_name,
  COALESCE(p.last_name,    pi.last_name)                     AS last_name,
  COALESCE(p.description,  pi.description)                   AS description,
  COALESCE(p.department,   pi.department)                    AS department,
  COALESCE(p.hire_date,    pi.hire_date)                     AS hire_date,
  bb.id                                                       AS bike_benefit_id,
  bb.benefit_status,
  bb.contract_status,
  COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) AS last_modified_at,
  bb.bike_id,
  bo.id                                                       AS order_id
FROM       public.profile_invites pi
LEFT JOIN  public.companies       c   ON  pi.company_id = c.id
LEFT JOIN  public.profiles        p   ON  pi.email      = p.email
LEFT JOIN  public.bike_benefits   bb  ON  p.user_id     = bb.user_id
LEFT JOIN  public.bikes           b   ON  bb.bike_id    = b.id
LEFT JOIN  public.bike_orders     bo  ON  bb.id         = bo.bike_benefit_id
ORDER BY last_modified_at DESC;

GRANT SELECT ON public.profile_invites_with_details TO authenticated;
