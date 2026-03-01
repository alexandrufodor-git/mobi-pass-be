-- pgtap is kept installed for local testing; do not drop it.
-- drop extension if exists "pgtap";

drop view if exists "public"."profile_invites_with_details";

alter table "public"."user_roles" add constraint "user_roles_user_id_profiles_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(user_id) ON UPDATE CASCADE ON DELETE CASCADE not valid;

alter table "public"."user_roles" validate constraint "user_roles_user_id_profiles_fkey";

create or replace view "public"."profile_invites_with_details" as  SELECT pi.id AS invite_id,
    pi.email,
    pi.status AS invite_status,
    pi.created_at AS invited_at,
    pi.company_id,
    c.name AS company_name,
    p.user_id,
    p.status AS profile_status,
    p.created_at AS registered_at,
    COALESCE(p.first_name, pi.first_name) AS first_name,
    COALESCE(p.last_name, pi.last_name) AS last_name,
    COALESCE(p.description, pi.description) AS description,
    COALESCE(p.department, pi.department) AS department,
    COALESCE(p.hire_date, pi.hire_date) AS hire_date,
    bb.id AS bike_benefit_id,
    bb.benefit_status,
    bb.contract_status,
    COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) AS last_modified_at,
    bb.bike_id,
    bo.id AS order_id
   FROM (((((public.profile_invites pi
     LEFT JOIN public.companies c ON ((pi.company_id = c.id)))
     LEFT JOIN public.profiles p ON ((pi.email = p.email)))
     LEFT JOIN public.bike_benefits bb ON ((p.user_id = bb.user_id)))
     LEFT JOIN public.bikes b ON ((bb.bike_id = b.id)))
     LEFT JOIN public.bike_orders bo ON ((bb.id = bo.bike_benefit_id)))
  ORDER BY COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) DESC;


-- Supabase Cloud internal triggers — function does not exist in local CLI environment.
-- CREATE TRIGGER protect_buckets_delete BEFORE DELETE ON storage.buckets FOR EACH STATEMENT EXECUTE FUNCTION storage.protect_delete();
-- CREATE TRIGGER protect_objects_delete BEFORE DELETE ON storage.objects FOR EACH STATEMENT EXECUTE FUNCTION storage.protect_delete();


