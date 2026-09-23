-- READ ONLY. Run each SELECT separately if the editor shows only the final result.
-- Does not print any credential values.
select now() at time zone 'Asia/Jakarta' as now_wib;
select jobid,jobname,schedule,active from cron.job where jobname like 'focusdesk%';
select j.jobname,d.status,d.return_message,d.start_time at time zone 'Asia/Jakarta' as started_wib
from cron.job_run_details d join cron.job j on j.jobid=d.jobid
where j.jobname like 'focusdesk%' order by d.start_time desc limit 10;
select id,status_code,content,error_msg,created at time zone 'Asia/Jakarta' as created_wib
from net._http_response order by created desc limit 10;
select last_tick_at at time zone 'Asia/Jakarta' as last_tick_wib,
last_generated_at at time zone 'Asia/Jakarta' as generated_wib,last_slot from public.fd_tg_scheduler_health;
select day,slot,summaries,cards from public.fd_tg_schedule_runs order by day desc,slot limit 10;
select status,count(*) from public.fd_desk_outbox group by status;
select id,status,last_error,attempts,created_at from public.fd_desk_outbox
where status in ('failed','uncertain','skipped') order by created_at desc limit 10;
select name,count(*) as copies,min(length(decrypted_secret)) as length_only
from vault.decrypted_secrets where name in ('focusdesk_app_url','focusdesk_cron_secret') group by name;
