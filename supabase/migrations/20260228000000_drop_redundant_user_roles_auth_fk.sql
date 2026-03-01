-- Drop the redundant FK from user_roles to auth.users.
-- The cascade chain auth.users → profiles → user_roles already covers deletions
-- via the user_roles_user_id_profiles_fkey constraint.
ALTER TABLE public.user_roles
  DROP CONSTRAINT user_roles_user_id_fkey;
