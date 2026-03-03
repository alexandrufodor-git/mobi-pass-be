-- Grant SELECT on user_roles to authenticated so RLS policies are evaluated.
-- Without this, authenticated users get "permission denied" before RLS is checked,
-- blocking both the HR company-scoped policy and the employee own-row policy.
GRANT SELECT ON public.user_roles TO authenticated;
