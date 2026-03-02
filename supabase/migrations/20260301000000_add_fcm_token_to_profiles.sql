-- FCM token for push notifications
alter table public.profiles add column if not exists fcm_token text;

-- Notification event types used in FCM data payloads for mobile localization
drop type if exists public.notification_event;
create type public.notification_event as enum (
  'contract_ready',
  'contract_signed_hr',
  'contract_approved'
);
