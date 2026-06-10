-- Rename the single-token patterns to bare 'last'/'first' (added in
-- 20260610000001 as 'last_only'/'first_only'). No company references them yet,
-- so the rename is safe. Keep TS EMAIL_PATTERN_TEMPLATES in lockstep.
ALTER TYPE "public"."email_pattern_kind" RENAME VALUE 'last_only' TO 'last';
ALTER TYPE "public"."email_pattern_kind" RENAME VALUE 'first_only' TO 'first';
