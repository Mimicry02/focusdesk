-- ACTIVATE AFTER deploying v1.5 and running migration 08.
-- Prerequisite Vault secrets (create via Supabase Vault UI; do not commit secret values):
-- focusdesk_app_url: production HTTPS origin, e.g. https://your-app.vercel.app (no trailing slash).
-- focusdesk_cron_secret: same >=32-character CRON_SECRET configured on Vercel Production.
-- Supabase Cron calls the endpoint every minute. Application clock gates 09:00 / 17:30 WIB.
-- Approx. 43,200 requests in 30 days; subject to provider quotas, outages and network latency.
begin;
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
do $$begin
 if (select count(*) from vault.decrypted_secrets where name='focusdesk_app_url')<>1
 or (select count(*) from vault.decrypted_secrets where name='focusdesk_cron_secret')<>1 then
  raise exception 'Create exactly one Vault secret for each required name';
 end if;
 if not exists(select 1 from vault.decrypted_secrets where name='focusdesk_app_url' and decrypted_secret ~ '^https://[a-zA-Z0-9.-]+(:[0-9]+)?$')
 or not exists(select 1 from vault.decrypted_secrets where name='focusdesk_cron_secret' and length(decrypted_secret)>=32) then
  raise exception 'Check production HTTPS origin and CRON_SECRET length';
 end if;
end $$;
-- Supersedes old queue-only job 06. No other jobs are touched.
select cron.unschedule(jobid) from cron.job where jobname='focusdesk-telegram-queue';
select cron.schedule('focusdesk-telegram-scheduler','* * * * *',$job$
 select net.http_get(
  url := (select decrypted_secret from vault.decrypted_secrets where name='focusdesk_app_url') || '/api/telegram-cron?mode=schedule',
  headers := jsonb_build_object('Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='focusdesk_cron_secret')),
  timeout_milliseconds := 55000
 );
$job$);
commit;
-- Stop deliberately: select cron.unschedule('focusdesk-telegram-scheduler');
-- Vercel's daily fallback still exists; remove its Telegram cron entries too to stop ALL scheduling.
