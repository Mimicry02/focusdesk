-- OPTIONAL, NOT PART OF THE AUTOMATIC UPGRADE.
-- Run only after configuring Supabase Cron/pg_net and two Vault secrets:
-- focusdesk_app_url = exact HTTPS production origin, no trailing slash
-- focusdesk_cron_secret = same >=32-character CRON_SECRET configured on Vercel
-- This job only drains the queue. Daily generation remains Vercel's 08:00 WIB job.
-- Can generate ~43,200 HTTP requests/month. Check your platform quotas first.
begin;
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
do $$begin
 if not exists(select 1 from vault.decrypted_secrets where name='focusdesk_app_url' and decrypted_secret ~ '^https://[^/]+$')
 or not exists(select 1 from vault.decrypted_secrets where name='focusdesk_cron_secret' and length(decrypted_secret)>=32) then
  raise exception 'Create the two Vault secrets described at the top of this file first';
 end if;
end $$;
-- Named scheduling updates this job when re-run; does not create duplicates.
select cron.schedule('focusdesk-telegram-queue','* * * * *',$job$
 select net.http_get(
  url := (select decrypted_secret from vault.decrypted_secrets where name='focusdesk_app_url') || '/api/telegram-cron?mode=queue',
  headers := jsonb_build_object('Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='focusdesk_cron_secret')),
  timeout_milliseconds := 55000
 );
$job$);
commit;
-- To stop this job later (run deliberately):
-- select cron.unschedule('focusdesk-telegram-queue');
