-- ============================================================================
-- Normalize image paths: store only the storage object name, not full URLs.
-- Clients construct the full URL via supabase.storage.getPublicUrl().
--
-- Back-fills existing rows where a full URL was stored by keeping only the
-- portion after the last '/'.
-- No trigger change needed — sync_avatar_to_profile already stores NEW.name.
-- ============================================================================

-- Strip full URL to just the filename for logo_image_path
UPDATE public.companies
SET logo_image_path = split_part(logo_image_path, '/', -1)
WHERE logo_image_path IS NOT NULL
  AND logo_image_path LIKE 'http%';

-- Defensive: same for profile_image_path
UPDATE public.profiles
SET profile_image_path = split_part(profile_image_path, '/', -1)
WHERE profile_image_path IS NOT NULL
  AND profile_image_path LIKE 'http%';
