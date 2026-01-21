create type "public"."company_name" as enum ('8x8', 'BigTech1', 'SmallTech2');

alter table "public"."profile_invites" drop constraint "profile_invites_pkey";

drop index if exists "public"."profile_invites_pkey";


  create table "public"."companies" (
    "id" uuid not null default gen_random_uuid(),
    "created_at" timestamp with time zone not null default now(),
    "name" public.company_name not null,
    "description" text
      );


alter table "public"."companies" enable row level security;

alter table "public"."profile_invites" add column "company_id" uuid not null;

alter table "public"."profile_invites" add column "id" uuid not null default gen_random_uuid();

alter table "public"."profiles" add column "company_id" uuid not null;

CREATE UNIQUE INDEX companies_pkey ON public.companies USING btree (id);

CREATE UNIQUE INDEX profile_invites_pkey ON public.profile_invites USING btree (id);

alter table "public"."companies" add constraint "companies_pkey" PRIMARY KEY using index "companies_pkey";

alter table "public"."profile_invites" add constraint "profile_invites_pkey" PRIMARY KEY using index "profile_invites_pkey";

alter table "public"."profile_invites" add constraint "profile_invites_company_id_fkey" FOREIGN KEY (company_id) REFERENCES public.companies(id) not valid;

alter table "public"."profile_invites" validate constraint "profile_invites_company_id_fkey";

alter table "public"."profiles" add constraint "profiles_company_id_fkey" FOREIGN KEY (company_id) REFERENCES public.companies(id) not valid;

alter table "public"."profiles" validate constraint "profiles_company_id_fkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.handle_user_registration()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$DECLARE
  v_company_id uuid;
BEGIN
  -- Only proceed if user has confirmed their email (via OTP verification)
  IF NEW.email_confirmed_at IS NOT NULL THEN

    -- Extract company_id from user metadata
    v_company_id := (NEW.raw_user_meta_data->>'company_id')::uuid;

    -- Safety check
    IF v_company_id IS NULL THEN
      RAISE EXCEPTION 'company_id missing in user metadata';
    END IF;
    
    -- 1. Automatically assign 'employee' role to new users
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, 'employee'::public.user_role)
    ON CONFLICT (user_id, role) DO NOTHING;
    
    -- 2. Create or update profile
    INSERT INTO public.profiles (user_id, email, status)
    VALUES (NEW.id, NEW.email, 'active'::public.user_profile_status, v_company_id)
    ON CONFLICT (user_id) 
    DO UPDATE SET 
      email = EXCLUDED.email,
      status = 'active'::public.user_profile_status,
      company_id = EXCLUDED.company_id;
    
    -- 3. Update profile_invites status to 'active'
    UPDATE public.profile_invites
    SET status = 'active'::public.user_profile_status
    WHERE LOWER(email) = LOWER(NEW.email);
    
  END IF;
  
  RETURN NEW;
END;$function$
;

grant delete on table "public"."companies" to "anon";

grant insert on table "public"."companies" to "anon";

grant references on table "public"."companies" to "anon";

grant select on table "public"."companies" to "anon";

grant trigger on table "public"."companies" to "anon";

grant truncate on table "public"."companies" to "anon";

grant update on table "public"."companies" to "anon";

grant delete on table "public"."companies" to "authenticated";

grant insert on table "public"."companies" to "authenticated";

grant references on table "public"."companies" to "authenticated";

grant select on table "public"."companies" to "authenticated";

grant trigger on table "public"."companies" to "authenticated";

grant truncate on table "public"."companies" to "authenticated";

grant update on table "public"."companies" to "authenticated";

grant delete on table "public"."companies" to "service_role";

grant insert on table "public"."companies" to "service_role";

grant references on table "public"."companies" to "service_role";

grant select on table "public"."companies" to "service_role";

grant trigger on table "public"."companies" to "service_role";

grant truncate on table "public"."companies" to "service_role";

grant update on table "public"."companies" to "service_role";


  create policy "HR can view profile invites"
  on "public"."profile_invites"
  as permissive
  for select
  to authenticated
using (((auth.jwt() ->> 'user_role'::text) = 'hr'::text));



  create policy "HR can view profiles"
  on "public"."profiles"
  as permissive
  for select
  to authenticated
using (((auth.jwt() ->> 'user_role'::text) = 'hr'::text));



