-- BellaBike sync — make bike_sync_invoke's target base URL Vault-driven.
--
-- Migration 0004 hardcoded the prod functions URL, which means the SAME code
-- could only ever invoke prod. That blocks running the real orchestration on
-- the local Docker stack (pg_net would POST from the local db container to
-- production). Reading the base URL from Vault lets the identical migration run
-- everywhere — only the Vault value differs per environment:
--
--   prod  — no 'bike_sync_base_url' secret → falls back to the prod URL below
--           (so prod behaviour is unchanged with zero new config).
--   local — set the secret to the host gateway so pg_net (inside the db
--           container) reaches the local edge-runtime container:
--             SELECT vault.create_secret(
--               'http://host.docker.internal:54321', 'bike_sync_base_url');
--
-- Everything else (Vault webhook secret, fire-and-forget, headers) is identical
-- to 0004.

CREATE OR REPLACE FUNCTION public.bike_sync_invoke(
  p_run_id uuid,
  p_branch text
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, net, vault AS $$
DECLARE
  v_secret     text;
  v_base       text;
  v_request_id bigint;
BEGIN
  SELECT decrypted_secret INTO v_secret
    FROM vault.decrypted_secrets
   WHERE name = 'bike_sync_webhook_secret'
   LIMIT 1;

  IF v_secret IS NULL THEN
    RAISE WARNING '[bike_sync_invoke] Vault secret "bike_sync_webhook_secret" not found — invocation skipped';
    RETURN NULL;
  END IF;

  -- Optional per-environment override; prod default keeps existing behaviour.
  SELECT decrypted_secret INTO v_base
    FROM vault.decrypted_secrets
   WHERE name = 'bike_sync_base_url'
   LIMIT 1;
  v_base := COALESCE(v_base, 'https://xlfkdumbsflqxpezolhl.supabase.co');

  SELECT net.http_post(
    url     := v_base || '/functions/v1/bike-sync',
    headers := jsonb_build_object(
      'Content-Type',     'application/json',
      'x-webhook-secret', v_secret
    ),
    body    := jsonb_build_object('run_id', p_run_id, 'branch', p_branch)
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$$;
COMMENT ON FUNCTION public.bike_sync_invoke(uuid, text) IS 'Fire-and-forget pg_net POST to the bike-sync edge fn for one branch drain. Base URL from Vault secret bike_sync_base_url (falls back to prod). Webhook secret from Vault (bike_sync_webhook_secret).';
GRANT EXECUTE ON FUNCTION public.bike_sync_invoke(uuid, text) TO service_role;
