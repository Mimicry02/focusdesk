-- Focusdesk v1.5.0. Run after v1.4 / migration 07. No scheduler job is activated here.
begin;
alter table public.fd_telegram_outbox drop constraint if exists fd_telegram_outbox_kind_check;
alter table public.fd_telegram_outbox add constraint fd_telegram_outbox_kind_check check(kind in ('task','digest','briefing'));
alter table public.fd_telegram_outbox add column if not exists schedule_slot text check(schedule_slot in ('morning','evening'));
alter table public.fd_telegram_outbox add column if not exists depends_on uuid references public.fd_telegram_outbox(id) on delete set null;
create table if not exists public.fd_tg_schedule_runs (
 day date not null, slot text not null check(slot in ('morning','evening')),
 created_at timestamptz not null default now(), materialized integer not null default 0,
 summaries integer not null default 0, cards integer not null default 0, primary key(day,slot)
);
create table if not exists public.fd_tg_scheduler_health (
 id boolean primary key default true check(id), last_tick_at timestamptz,
 last_generated_at timestamptz, last_slot text
);
alter table public.fd_tg_schedule_runs enable row level security;
alter table public.fd_tg_scheduler_health enable row level security;
revoke all on public.fd_tg_schedule_runs,public.fd_tg_scheduler_health from public,anon,authenticated;
grant all on public.fd_tg_schedule_runs,public.fd_tg_scheduler_health to service_role;

-- Materializing today's series during a briefing must not also emit duplicate event cards.
-- The activity record remains; normal foreground creation/updates keep their notifications.
create or replace function public.fd_task_event() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' or new.status is distinct from old.status or new.progress_note is distinct from old.progress_note then
  insert into public.fd_task_activity(task_id,actor_id,from_status,to_status,test_cycle,note,task_version)
  values(new.id,auth.uid(),case when tg_op='UPDATE' then old.status else null end,new.status,new.test_cycle,new.progress_note,new.version);
 end if;
 if coalesce(current_setting('fd.scheduler_materializing',true),'')<>'on'
 and (new.recurrence_date is null or new.recurrence_date=(now() at time zone 'Asia/Jakarta')::date or (tg_op='UPDATE' and new.recurrence_date<(now() at time zone 'Asia/Jakarta')::date)) then
  perform public.fd_tg_enqueue_task(new.id,'event:'||new.id||':'||new.version);
 end if;
 return new;
end $$;

-- Service-only: p_now is for deterministic SQL tests/recovery, never taken from HTTP input.
create or replace function public.fd_tg_schedule(p_slot text default null,p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d date:=(p_now at time zone 'Asia/Jakarta')::date; tm time:=(p_now at time zone 'Asia/Jakarta')::time;
 s text; u uuid; n integer:=0; sc integer:=0; cc integer:=0; inserted integer;
 prior text:=current_setting('request.jwt.claim.sub',true); flag text:=current_setting('fd.scheduler_materializing',true);
begin
 if p_now is null then raise exception 'Clock is required';end if;
 if p_slot is not null and p_slot not in ('morning','evening') then raise exception 'Invalid schedule slot';end if;
 insert into public.fd_tg_scheduler_health(id,last_tick_at) values(true,p_now)
 on conflict(id) do update set last_tick_at=excluded.last_tick_at;
 s:=case when tm>=time '17:30' then 'evening' when tm>=time '09:00' then 'morning' else null end;
 if s is null or (p_slot is not null and p_slot<>s) then return jsonb_build_object('generated',false,'reason','outside_window','day',d);end if;
 perform pg_advisory_xact_lock(hashtextextended('fd-schedule:'||d||':'||s,0));
 insert into public.fd_tg_schedule_runs(day,slot) values(d,s) on conflict do nothing;
 get diagnostics inserted=row_count;
 if inserted=0 then return jsonb_build_object('generated',false,'reason','already_generated','day',d,'slot',s);end if;
 perform set_config('fd.scheduler_materializing','on',true);
 for u in select distinct r.owner_id from public.fd_recurrences r join public.fd_profiles p on p.id=r.owner_id and p.is_active where r.active loop
  perform set_config('request.jwt.claim.sub',u::text,true);
  n:=n+public.fd_materialize_recurrences(d+14);
 end loop;
 perform set_config('request.jwt.claim.sub',coalesce(prior,''),true);
 perform set_config('fd.scheduler_materializing',coalesce(flag,''),true);
 insert into public.fd_telegram_outbox(owner_id,target_group_id,kind,day,schedule_slot,dedupe_key)
 select g.owner_id,g.id,'briefing',d,s,'schedule:'||d||':'||s||':g:'||g.id
 from public.fd_telegram_groups g join public.fd_profiles p on p.id=g.owner_id and p.is_active
 where g.active on conflict(dedupe_key) do nothing;
 get diagnostics sc=row_count;
 if s='morning' then
  -- Runnable tasks to executor; review-stage tasks to owner. Neither path goes to a group.
  insert into public.fd_telegram_outbox(owner_id,target_user_id,task_id,kind,day,schedule_slot,dedupe_key,depends_on)
  select t.user_id,recipient.id,t.id,'task',d,s,'schedule:'||d||':morning:t:'||t.id||':u:'||recipient.id,
   (select o.id from public.fd_telegram_outbox o where o.dedupe_key='schedule:'||d||':morning:g:'||t.telegram_group_id)
  from public.fd_tasks t join public.fd_profiles owner on owner.id=t.user_id and owner.is_active
  cross join lateral (select case when t.requires_testing and t.status in ('Ready for Testing','Testing') then t.user_id
    when t.assignee_id is not null then t.assignee_id when t.pic_id is null then t.user_id else null end id) recipient
  join public.fd_profiles p on p.id=recipient.id and p.is_active
  join public.fd_telegram_accounts a on a.user_id=recipient.id
  where t.status<>'Done' and (t.scheduled_date<=d or t.due_date<=d)
   and (recipient.id is distinct from t.assignee_id or t.pic_id is null or public.fd_tg_pic_matches(t.pic_id,recipient.id))
  on conflict(dedupe_key) do nothing;
  get diagnostics cc=row_count;
 end if;
 update public.fd_tg_schedule_runs set materialized=n,summaries=sc,cards=cc where day=d and slot=s;
 update public.fd_tg_scheduler_health set last_generated_at=p_now,last_slot=s where id;
 delete from public.fd_telegram_codes where expires_at<now();
 delete from public.fd_telegram_updates where created_at<now()-interval '30 days';
 delete from public.fd_telegram_messages where created_at<now()-interval '30 days';
 delete from public.fd_telegram_outbox where status in ('sent','skipped') and created_at<now()-interval '90 days';
 delete from public.fd_tg_schedule_runs where day<d-180;
 return jsonb_build_object('generated',true,'day',d,'slot',s,'materialized',n,'summaries',sc,'cards',cc);
end $$;

-- Compatibility for old cron callers: generation is now gated by the same WIB windows.
create or replace function public.fd_tg_daily() returns integer
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin result:=public.fd_tg_schedule();return coalesce((result->>'materialized')::integer,0);end $$;

-- Counts are complete; samples are bounded. Group data is scoped to BOTH owner and group.
create or replace function public.fd_tg_briefing_data(p_owner uuid,p_group uuid,p_day date) returns jsonb
language sql stable security definer set search_path='' as $$
 with visible as (
  select t.id,t.title,t.status,t.pic_name,t.owner_name,t.scheduled_date,t.due_date,t.start_time,
   coalesce(t.due_date<p_day or t.scheduled_date<p_day,false) as carry,
   coalesce(t.due_date=p_day or t.scheduled_date=p_day,false) as today,
   coalesce(t.due_date=p_day+1 or t.scheduled_date=p_day+1,false) as tomorrow
  from public.fd_tasks t join public.fd_profiles p on p.id=t.user_id and p.is_active
  join public.fd_telegram_groups g on g.id=t.telegram_group_id and g.active and g.owner_id=t.user_id
  where t.user_id=p_owner and t.telegram_group_id=p_group and t.status<>'Done'
 ), buckets as (
  select 'carry' bucket,v.* from visible v where carry
  union all select 'today',v.* from visible v where today and not carry
  union all select 'tomorrow',v.* from visible v where tomorrow
 ), ranked as (select *,row_number() over(partition by bucket order by due_date nulls last,scheduled_date nulls last,id) rn from buckets)
 select jsonb_build_object(
  'carry',jsonb_build_object('count',(select count(*) from ranked where bucket='carry'),'items',coalesce((select jsonb_agg(to_jsonb(r)-'bucket'-'rn'-'carry'-'today'-'tomorrow' order by rn) from ranked r where bucket='carry' and rn<=5),'[]'::jsonb)),
  'today',jsonb_build_object('count',(select count(*) from ranked where bucket='today'),'items',coalesce((select jsonb_agg(to_jsonb(r)-'bucket'-'rn'-'carry'-'today'-'tomorrow' order by rn) from ranked r where bucket='today' and rn<=5),'[]'::jsonb)),
  'tomorrow',jsonb_build_object('count',(select count(*) from ranked where bucket='tomorrow'),'items',coalesce((select jsonb_agg(to_jsonb(r)-'bucket'-'rn'-'carry'-'today'-'tomorrow' order by rn) from ranked r where bucket='tomorrow' and rn<=5),'[]'::jsonb))
 );
$$;

create or replace function public.fd_tg_claim(p_owner uuid default null,p_limit integer default 8)
returns setof public.fd_telegram_outbox language plpgsql security definer set search_path='' as $$
declare d date:=(now() at time zone 'Asia/Jakarta')::date; tm time:=(now() at time zone 'Asia/Jakarta')::time;
begin
 update public.fd_telegram_outbox set status='uncertain',last_error='Worker interrupted; inspect Telegram before manual resend' where status='sending' and attempted_at<now()-interval '5 minutes';
 update public.fd_telegram_outbox set status='skipped',last_error='Scheduled window expired'
 where status in ('pending','failed') and schedule_slot is not null and (day<>d or schedule_slot='morning' and tm>=time '17:30');
 return query with q as (
  select o.id from public.fd_telegram_outbox o
  where o.status in ('pending','failed') and o.attempts<5 and o.next_attempt_at<=now() and (p_owner is null or o.owner_id=p_owner)
   and (o.depends_on is null or exists(select 1 from public.fd_telegram_outbox parent where parent.id=o.depends_on
    and (parent.status in ('sent','skipped','uncertain') or parent.status='failed' and parent.attempts>=5)))
  order by case when o.kind='briefing' then 0 else 1 end,o.created_at,o.id
  for update of o skip locked limit least(greatest(p_limit,1),20)
 ) update public.fd_telegram_outbox o set status='sending',attempts=attempts+1,attempted_at=now() from q where o.id=q.id returning o.*;
end $$;
revoke all on function public.fd_tg_schedule(text,timestamptz),public.fd_tg_briefing_data(uuid,uuid,date) from public,anon,authenticated;
grant execute on function public.fd_tg_schedule(text,timestamptz),public.fd_tg_briefing_data(uuid,uuid,date) to service_role;
notify pgrst,'reload schema';
commit;
