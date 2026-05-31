-- Extend profile_invites_with_details with REGES lifecycle columns.
--
-- The reges-employee-bridge schema (20260516000001) added source, radiat, and
-- derived_email to profile_invites, but this view uses an explicit column list
-- (not pi.*), so those columns did NOT project through. The HR reports page
-- needs them to render the source chip, the "Terminated" chip (radiat), and
-- the derived-email tooltip.
--
-- CREATE OR REPLACE VIEW only permits appending columns, so the three new
-- columns are added at the end of the SELECT list. Everything else is
-- unchanged from the prior definition (security_invoker stays on).
CREATE OR REPLACE VIEW "public"."profile_invites_with_details" WITH ("security_invoker"='on') AS
 SELECT "pi"."id" AS "invite_id",
    "pi"."email",
    "pi"."status" AS "invite_status",
    "pi"."created_at" AS "invited_at",
    "pi"."company_id",
    "c"."name" AS "company_name",
    "c"."logo_image_path",
    "p"."user_id",
    "p"."status" AS "profile_status",
    "p"."created_at" AS "registered_at",
    "p"."profile_image_path",
    COALESCE("p"."first_name", "pi"."first_name") AS "first_name",
    COALESCE("p"."last_name", "pi"."last_name") AS "last_name",
    COALESCE("p"."description", "pi"."description") AS "description",
    COALESCE("p"."department", "pi"."department") AS "department",
    COALESCE("p"."hire_date", "pi"."hire_date") AS "hire_date",
    "bb"."id" AS "bike_benefit_id",
    "bb"."benefit_status",
    "bb"."contract_status",
    COALESCE("bb"."updated_at", "bo"."updated_at", "p"."created_at", "pi"."created_at") AS "last_modified_at",
    "bb"."bike_id",
    "bo"."id" AS "order_id",
    "pi"."source",
    "pi"."radiat",
    "pi"."derived_email"
   FROM ((((("public"."profile_invites" "pi"
     LEFT JOIN "public"."companies" "c" ON (("pi"."company_id" = "c"."id")))
     LEFT JOIN "public"."profiles" "p" ON (("pi"."email" = "p"."email")))
     LEFT JOIN "public"."bike_benefits" "bb" ON (("p"."user_id" = "bb"."user_id")))
     LEFT JOIN "public"."bikes" "b" ON (("bb"."bike_id" = "b"."id")))
     LEFT JOIN "public"."bike_orders" "bo" ON (("bb"."id" = "bo"."bike_benefit_id")))
  ORDER BY COALESCE("bb"."updated_at", "bo"."updated_at", "p"."created_at", "pi"."created_at") DESC;
