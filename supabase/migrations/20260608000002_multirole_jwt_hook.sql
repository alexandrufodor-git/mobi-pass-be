-- Multi-role JWT hook: deterministic highest-privilege role + user_roles array
--
-- Foundation ADR (llm-agent-assist/plans/canonical-identity-and-roles.md),
-- "Migration B" (§7). user_roles is UNIQUE(user_id, role) — a person can
-- legitimately hold both `hr` and `employee` (an HR who also takes a bike
-- benefit for themselves). The old hook did `SELECT role ... WHERE user_id = X`
-- with no ordering, so a multi-role user got an *arbitrary* single user_role
-- claim — non-deterministic 403s in send-contract / requireRole / the webhook.
--
-- This rewrite:
--   1. Stamps the deterministic HIGHEST-PRIVILEGE role (admin > hr > employee)
--      into `user_role`. No-op for the single-role users who make up everyone
--      today (highest-of-one is that one role).
--   2. Adds an additive `user_roles` array claim (priv-ordered, e.g.
--      ["hr","employee"]) so mobile can detect that an HR user is *also* an
--      employee and offer the self-benefit flow, and so guards can later read
--      the full set instead of a single claim.
--
-- Employee-only gates stay DB-based (presence of an `employee` user_roles row),
-- never on the single JWT claim.

CREATE OR REPLACE FUNCTION "public"."custom_access_token_hook"("event" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  claims    jsonb;
  v_user_id uuid := (event->>'user_id')::uuid;
  v_roles   text[];
BEGIN
  -- Get existing claims
  claims := event->'claims';

  -- All roles for this user, ordered by privilege (admin > hr > employee).
  SELECT array_agg(role::text ORDER BY
           CASE role
             WHEN 'admin'    THEN 1
             WHEN 'hr'       THEN 2
             WHEN 'employee' THEN 3
             ELSE 99
           END)
  INTO v_roles
  FROM public.user_roles
  WHERE user_id = v_user_id;

  IF v_roles IS NULL OR array_length(v_roles, 1) IS NULL THEN
    -- No role assigned
    claims := jsonb_set(claims, '{user_role}',  'null'::jsonb);
    claims := jsonb_set(claims, '{user_roles}', '[]'::jsonb);
  ELSE
    -- Highest-privilege role is first in the priv-ordered array.
    claims := jsonb_set(claims, '{user_role}',  to_jsonb(v_roles[1]));
    claims := jsonb_set(claims, '{user_roles}', to_jsonb(v_roles));
  END IF;

  -- Update claims in the event
  event := jsonb_set(event, '{claims}', claims);

  RETURN event;
END;
$$;

COMMENT ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") IS 'Auth hook that injects role claims into the JWT:
  - user_role  : the deterministic highest-privilege role (admin > hr > employee)
  - user_roles : the full priv-ordered array of the user''s roles (e.g. ["hr","employee"])
Multi-role aware (an HR user can also be an employee). No device validation - security enforced via:
1. RLS policies / edge-function guards based on the role claims
2. Employee-only actions gate on a DB user_roles row, never on the single user_role claim';
