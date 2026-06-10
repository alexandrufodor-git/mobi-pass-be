-- Add single-token email patterns: last@domain and first@domain.
-- Enums are append-only; we ADD VALUE rather than recreate the type. The
-- literal templates live in TS (EMAIL_PATTERN_TEMPLATES) — add the matching
-- entries there in lockstep.
ALTER TYPE "public"."email_pattern_kind" ADD VALUE IF NOT EXISTS 'last_only';
ALTER TYPE "public"."email_pattern_kind" ADD VALUE IF NOT EXISTS 'first_only';
