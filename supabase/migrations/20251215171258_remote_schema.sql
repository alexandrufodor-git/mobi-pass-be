


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."user_profile_status" AS ENUM (
    'active',
    'inactive'
);


ALTER TYPE "public"."user_profile_status" OWNER TO "postgres";


CREATE TYPE "public"."user_role" AS ENUM (
    'admin',
    'hr',
    'employee'
);


ALTER TYPE "public"."user_role" OWNER TO "postgres";


COMMENT ON TYPE "public"."user_role" IS 'Type description for user role';



CREATE TYPE "public"."user_role_permissions" AS ENUM (
    'users.create'
);


ALTER TYPE "public"."user_role_permissions" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  bind_permissions int;
  user_role text;
BEGIN
  -- Fetch user role from JWT claims (injected by custom_access_token_hook)
  user_role := auth.jwt() ->> 'user_role';
  
  -- Check if the role has the requested permission
  SELECT count(*)
  INTO bind_permissions
  FROM public.role_permissions
  WHERE role_permissions.permission = requested_permission
    AND role_permissions.role::text = user_role;
  
  RETURN bind_permissions > 0;
END;
$$;


ALTER FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") IS 'Checks if the current user has the requested permission based on their role. Use in RLS policies: authorize(''users.create'')';



CREATE OR REPLACE FUNCTION "public"."custom_access_token_hook"("event" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  claims jsonb;
  user_role public.user_role;
BEGIN
  -- Get existing claims
  claims := event->'claims';
  
  -- Fetch user role from user_roles table
  SELECT role INTO user_role 
  FROM public.user_roles 
  WHERE user_id = (event->>'user_id')::uuid;
  
  -- Add user_role to JWT claims
  IF user_role IS NOT NULL THEN
    claims := jsonb_set(claims, '{user_role}', to_jsonb(user_role));
  ELSE
    -- No role assigned, set to null
    claims := jsonb_set(claims, '{user_role}', 'null');
  END IF;
  
  -- Update claims in the event
  event := jsonb_set(event, '{claims}', claims);
  
  RETURN event;
END;
$$;


ALTER FUNCTION "public"."custom_access_token_hook"("event" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") IS 'Auth hook that injects user_role (admin/hr/employee) into JWT claims.
No device validation - security enforced via:
1. RLS policies based on user_role
2. Client-side app logic to show/hide features by role';



CREATE OR REPLACE FUNCTION "public"."get_my_role"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  SELECT COALESCE(auth.jwt() ->> 'user_role', 'null');
$$;


ALTER FUNCTION "public"."get_my_role"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_my_role"() IS 'Returns the current user''s role from JWT claims. Returns ''null'' if no role assigned.';



CREATE OR REPLACE FUNCTION "public"."handle_user_registration"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Automatically assign 'employee' role to new users
  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, 'employee')
  ON CONFLICT (user_id, role) DO NOTHING;
  
  -- Only proceed if user has confirmed their email (via OTP verification)
  IF NEW.email_confirmed_at IS NOT NULL THEN
    
    -- 1. Create or update profile
    INSERT INTO public.profiles (id, email, updated_at)
    VALUES (NEW.id, NEW.email, NOW())
    ON CONFLICT (id) 
    DO UPDATE SET 
      email = EXCLUDED.email,
      updated_at = NOW();
    
    -- 2. Update profile_invites status to 'active' (with explicit enum cast)
    UPDATE public.profile_invites
    SET status = 'active'::user_profile_status
    WHERE LOWER(email) = LOWER(NEW.email);
    
  END IF;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_user_registration"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_profile_email"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- if email changed, update profile.email
  IF NEW.email IS DISTINCT FROM OLD.email THEN
    UPDATE public.profiles SET email = NEW.email WHERE user_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_profile_email"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."profile_invites" (
    "email" "text" NOT NULL,
    "status" "public"."user_profile_status" DEFAULT 'inactive'::"public"."user_profile_status" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."profile_invites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "user_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "public"."user_profile_status" DEFAULT 'inactive'::"public"."user_profile_status" NOT NULL
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."role_permissions" (
    "id" bigint NOT NULL,
    "role" "public"."user_role" NOT NULL,
    "permission" "public"."user_role_permissions" NOT NULL
);


ALTER TABLE "public"."role_permissions" OWNER TO "postgres";


COMMENT ON TABLE "public"."role_permissions" IS 'Permissions for each role. Use authorize() function in RLS policies to check permissions.';



ALTER TABLE "public"."role_permissions" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."role_permissions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."user_roles" (
    "id" bigint NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "role" "public"."user_role" NOT NULL
);


ALTER TABLE "public"."user_roles" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_roles" IS 'User roles for RBAC. Roles are injected into JWT via custom_access_token_hook.';



ALTER TABLE "public"."user_roles" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."user_roles_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."profile_invites"
    ADD CONSTRAINT "profile_invites_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."profile_invites"
    ADD CONSTRAINT "profile_invites_pkey" PRIMARY KEY ("email");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_permission_key" UNIQUE ("permission");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_role_key" UNIQUE ("role");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "idx_profiles_email_unique" ON "public"."profiles" USING "btree" ("lower"("email")) WHERE ("email" IS NOT NULL);



CREATE UNIQUE INDEX "user_roles_user_role_idx" ON "public"."user_roles" USING "btree" ("user_id", "role");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON UPDATE CASCADE ON DELETE CASCADE;



CREATE POLICY "Allow auth admin to read user roles" ON "public"."user_roles" FOR SELECT TO "supabase_auth_admin" USING (true);



CREATE POLICY "Authenticated users can read permissions" ON "public"."role_permissions" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Enable read access for user own roles" ON "public"."user_roles" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "HR can assign roles" ON "public"."user_roles" FOR INSERT TO "authenticated" WITH CHECK (((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text") OR (("auth"."jwt"() ->> 'user_role'::"text") = 'admin'::"text")));



CREATE POLICY "HR can delete profile invites" ON "public"."profile_invites" FOR DELETE TO "authenticated" USING ((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text"));



CREATE POLICY "HR can update profile invites" ON "public"."profile_invites" FOR UPDATE TO "authenticated" USING ((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text"));



CREATE POLICY "Hr can only add profile invites" ON "public"."profile_invites" FOR INSERT TO "authenticated" WITH CHECK ((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text"));



CREATE POLICY "Users can read own role" ON "public"."user_roles" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."profile_invites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_hr_insert" ON "public"."profiles" FOR INSERT TO "authenticated" WITH CHECK ((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text"));



CREATE POLICY "profiles_self_select" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "profiles_self_update" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."role_permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_roles" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";





GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";
GRANT USAGE ON SCHEMA "public" TO "supabase_auth_admin";

























































































































































GRANT ALL ON FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") TO "anon";
GRANT ALL ON FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") TO "authenticated";
GRANT ALL ON FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") TO "service_role";



REVOKE ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") TO "supabase_auth_admin";



GRANT ALL ON FUNCTION "public"."get_my_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_my_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_role"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_user_registration"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_user_registration"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_user_registration"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_profile_email"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_profile_email"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_profile_email"() TO "service_role";


















GRANT ALL ON TABLE "public"."profile_invites" TO "anon";
GRANT ALL ON TABLE "public"."profile_invites" TO "authenticated";
GRANT ALL ON TABLE "public"."profile_invites" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."role_permissions" TO "anon";
GRANT ALL ON TABLE "public"."role_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."role_permissions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."role_permissions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."role_permissions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."role_permissions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."user_roles" TO "service_role";
GRANT ALL ON TABLE "public"."user_roles" TO "supabase_auth_admin";



GRANT ALL ON SEQUENCE "public"."user_roles_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."user_roles_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."user_roles_id_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































revoke delete on table "public"."user_roles" from "anon";

revoke insert on table "public"."user_roles" from "anon";

revoke references on table "public"."user_roles" from "anon";

revoke select on table "public"."user_roles" from "anon";

revoke trigger on table "public"."user_roles" from "anon";

revoke truncate on table "public"."user_roles" from "anon";

revoke update on table "public"."user_roles" from "anon";

revoke delete on table "public"."user_roles" from "authenticated";

revoke insert on table "public"."user_roles" from "authenticated";

revoke references on table "public"."user_roles" from "authenticated";

revoke select on table "public"."user_roles" from "authenticated";

revoke trigger on table "public"."user_roles" from "authenticated";

revoke truncate on table "public"."user_roles" from "authenticated";

revoke update on table "public"."user_roles" from "authenticated";

CREATE TRIGGER auth_user_email_sync AFTER UPDATE OF email ON auth.users FOR EACH ROW EXECUTE FUNCTION public.sync_profile_email();

CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW WHEN ((new.email_confirmed_at IS NOT NULL)) EXECUTE FUNCTION public.handle_user_registration();

CREATE TRIGGER on_auth_user_updated AFTER UPDATE ON auth.users FOR EACH ROW WHEN (((new.email_confirmed_at IS NOT NULL) AND (((old.encrypted_password)::text IS DISTINCT FROM (new.encrypted_password)::text) OR (old.email_confirmed_at IS DISTINCT FROM new.email_confirmed_at)))) EXECUTE FUNCTION public.handle_user_registration();


