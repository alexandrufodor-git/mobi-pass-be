-- Enforce that an account email always lives on its company's email_domain.
--
-- Why: a company is created with a fixed `companies.email_domain` (e.g.
-- borderbridge.eu). The HR/employee records that hang off it (profile_invites,
-- profiles) carry an `email`. Nothing stopped those emails from drifting to a
-- different — usually mistyped — domain (e.g. bordgerbridge.eu). When that
-- happens the login credential and the company silently disagree and the user
-- can never sign in ("Profile API failed"), while the data looks fine at a
-- glance. We make that state unrepresentable.
--
-- A plain CHECK can't reference another table, so this is a BEFORE trigger that
-- looks up the company's domain and rejects a mismatch. SECURITY INVOKER is
-- correct: every role that writes these tables (authenticated HR, service_role,
-- and the postgres-owned handle_user_registration) already has SELECT on
-- public.companies, so no privilege escalation is needed.
--
-- The triggers fire only on INSERT or on UPDATE OF (email, company_id) so that
-- unrelated updates (e.g. flipping `status`) on any pre-existing row are never
-- blocked retroactively.

CREATE OR REPLACE FUNCTION "public"."enforce_email_matches_company_domain"()
    RETURNS "trigger"
    LANGUAGE "plpgsql"
    SECURITY INVOKER
    SET "search_path" = ''
    AS $$
DECLARE
  v_company_domain text;
  v_email_domain   text;
BEGIN
  -- REGES-staged invites carry a NULL email until claim time — nothing to check.
  IF NEW.email IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT lower(c.email_domain)
    INTO v_company_domain
    FROM public.companies c
   WHERE c.id = NEW.company_id;

  -- No company / no domain resolvable yet → let the FK + NOT NULL constraints
  -- be the ones that complain, not this check.
  IF v_company_domain IS NULL THEN
    RETURN NEW;
  END IF;

  v_email_domain := lower(split_part(NEW.email, '@', 2));

  IF v_email_domain IS DISTINCT FROM v_company_domain THEN
    RAISE EXCEPTION
      'EMAIL_DOMAIN_MISMATCH: email % (domain %) does not match company % domain %',
      NEW.email, v_email_domain, NEW.company_id, v_company_domain
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."enforce_email_matches_company_domain"() OWNER TO "postgres";

DROP TRIGGER IF EXISTS "trg_profile_invites_email_domain" ON "public"."profile_invites";
CREATE TRIGGER "trg_profile_invites_email_domain"
  BEFORE INSERT OR UPDATE OF "email", "company_id" ON "public"."profile_invites"
  FOR EACH ROW EXECUTE FUNCTION "public"."enforce_email_matches_company_domain"();

DROP TRIGGER IF EXISTS "trg_profiles_email_domain" ON "public"."profiles";
CREATE TRIGGER "trg_profiles_email_domain"
  BEFORE INSERT OR UPDATE OF "email", "company_id" ON "public"."profiles"
  FOR EACH ROW EXECUTE FUNCTION "public"."enforce_email_matches_company_domain"();

-- ── Harden sync_run_summary: make it respect RLS ────────────────────────────
-- A view without security_invoker runs with the view owner's privileges and
-- BYPASSES RLS on its base tables. sync_run_summary is granted to anon +
-- authenticated and reads sync_runs / sync_units (both RLS-enabled), so as a
-- definer view it let any anon/authenticated caller read every dealer's sync
-- data regardless of policy. security_invoker = on makes reads go through the
-- caller's RLS. service_role (the bike-sync function) bypasses RLS either way,
-- so its behaviour is unchanged. The other two public views
-- (bikes_with_my_pricing, profile_invites_with_details) already have it on.
ALTER VIEW "public"."sync_run_summary" SET ("security_invoker" = on);
