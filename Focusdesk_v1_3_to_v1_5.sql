-- Focusdesk v1.3 to v1.5
-- Backup first. Run the ENTIRE file in Supabase SQL Editor.
begin;

-- Focusdesk v1.4: apply AFTER 05. No task deletion, status reset, or pairing reset.

alter table public.fd_pics add column if not exists telegram_username text
 check(telegram_username is null or telegram_username ~ '^[a-z][a-z0-9_]{4,31}$');
alter table public.fd_telegram_accounts add column if not exists telegram_username text;
alter table public.fd_telegram_accounts add column if not exists username_seen_at timestamptz;

-- Expected username is not identity. Telegram's numeric ID, verified by one-use
-- pairing, remains authoritative. Existing contacts without a username keep pairing.
create or replace function public.fd_tg_pic_matches(p_pic uuid,p_user uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.fd_pics p
 join public.fd_telegram_accounts a on a.user_id=p_user
 join public.fd_profiles u on u.id=a.user_id and u.is_active
 where p.id=p_pic and p.linked_user_id=p_user
 and (p.telegram_username is null or p.telegram_username=lower(a.telegram_username)))
$$;
revoke all on function public.fd_tg_pic_matches(uuid,uuid) from public,anon,authenticated;
grant execute on function public.fd_tg_pic_matches(uuid,uuid) to service_role;

create or replace function public.fd_save_pic_v14(p_id uuid,p_name text,p_email text,p_link boolean,p_active boolean,p_version integer default null,p_telegram_username text default null)
returns public.fd_pics language plpgsql security definer set search_path='' as $$
declare result public.fd_pics; handle text:=nullif(lower(trim(coalesce(p_telegram_username,''))),'');
begin
 if handle is not null and handle !~ '^[a-z][a-z0-9_]{4,31}$' then raise exception 'Username Telegram harus 5–32 huruf/angka/underscore, tanpa @';end if;
 if handle is not null and not p_link then raise exception 'Hubungkan akun PIC aktif untuk menggunakan Telegram';end if;
 result:=public.fd_save_pic(p_id,p_name,p_email,p_link,p_active,p_version);
 update public.fd_pics set telegram_username=handle where id=result.id returning * into result;
 return result;
end $$;
revoke all on function public.fd_save_pic_v14(uuid,text,text,boolean,boolean,integer,text) from public,anon,authenticated;
grant execute on function public.fd_save_pic_v14(uuid,text,text,boolean,boolean,integer,text) to authenticated;

-- Scoped directory, never expose another workspace's contacts or Telegram IDs.
create or replace function public.fd_pic_telegram_status()
returns table(pic_id uuid,observed_username text,telegram_status text)
language sql stable security definer set search_path='' as $$
 select p.id,a.telegram_username,
 case when not coalesce(u.is_active,false) then 'account_required'
 when a.user_id is null then 'not_paired'
 when p.telegram_username is not null and p.telegram_username is distinct from lower(a.telegram_username) then 'username_mismatch'
 when p.telegram_username is null then 'paired'
 else 'verified' end
 from public.fd_pics p left join public.fd_profiles u on u.id=p.linked_user_id
 left join public.fd_telegram_accounts a on a.user_id=p.linked_user_id
 where p.owner_id=auth.uid() and public.fd_is_active()
$$;
revoke all on function public.fd_pic_telegram_status() from public,anon,authenticated;
grant execute on function public.fd_pic_telegram_status() to authenticated;

create or replace function public.fd_tg_action(p_update bigint,p_telegram bigint,p_chat bigint,p_message bigint,p_task uuid,p_version integer,p_status text,p_note text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid; t public.fd_tasks; prior text:=current_setting('request.jwt.claim.sub',true); n integer; executor boolean; reviewer boolean;
begin
 select a.user_id into actor from public.fd_telegram_accounts a join public.fd_profiles p on p.id=a.user_id and p.is_active where a.telegram_id=p_telegram and a.chat_id=p_chat;
 if actor is null then raise exception 'Gunakan chat pribadi dari akun Focusdesk yang sudah terhubung';end if;
 select * into t from public.fd_tasks where id=p_task for update;
 if not found or not exists(select 1 from public.fd_profiles where id=t.user_id and is_active) or (actor<>t.user_id and actor is distinct from t.assignee_id) then raise exception 'Anda bukan pemilik atau PIC aktif tugas ini';end if;
 if not exists(select 1 from public.fd_telegram_messages m where m.chat_id=p_chat and p_chat>0 and m.message_id=p_message and m.task_id=t.id and m.task_version=p_version and m.target_user_id=actor and m.target_group_id is null) then raise exception 'Pesan tidak terhubung dengan chat pribadi Anda';end if;
 insert into public.fd_telegram_updates(update_id) values(p_update) on conflict do nothing;
 get diagnostics n=row_count;if n=0 then return jsonb_build_object('duplicate',true);end if;
 if t.version<>p_version then raise exception 'Pesan sudah lama. Ketik /tasks untuk tombol terbaru.';end if;
 if p_status is null or p_status not in ('Backlog','To do','In progress','Ready for Testing','Testing','Rework','Done') or length(coalesce(p_note,''))>4000 then raise exception 'Tindakan tidak valid';end if;
 reviewer:=actor=t.user_id;
 executor:=coalesce(actor=t.assignee_id,false) or (t.pic_id is null and reviewer);
 if actor=t.assignee_id and t.pic_id is not null and not public.fd_tg_pic_matches(t.pic_id,actor) then raise exception 'Username Telegram tidak cocok dengan PIC';end if;
 if p_status is distinct from t.status then
  if t.requires_testing then
   if not ((executor and t.status in ('Backlog','To do','Rework') and p_status='In progress') or
    (executor and t.status='In progress' and p_status='Ready for Testing') or
    (reviewer and t.status='Ready for Testing' and p_status in ('Testing','Rework')) or
    (reviewer and t.status='Testing' and p_status in ('Done','Rework')) or
    (reviewer and t.status='Done' and p_status='Rework')) then raise exception 'Tindakan bukan untuk peran/tahap Anda';end if;
  elsif not executor or not ((t.status='Done' and p_status='To do') or (t.status<>'Done' and p_status in ('In progress','Done'))) then raise exception 'Hanya PIC pengerjaan dapat melakukan tindakan ini';
  end if;
 end if;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 update public.fd_tasks set status=p_status,progress_note=coalesce(p_note,progress_note) where id=p_task returning * into t;
 perform set_config('request.jwt.claim.sub',coalesce(prior,''),true);
 return jsonb_build_object('status',t.status,'version',t.version);
end $$;
revoke all on function public.fd_tg_action(bigint,bigint,bigint,bigint,uuid,integer,text,text) from public,anon,authenticated;
grant execute on function public.fd_tg_action(bigint,bigint,bigint,bigint,uuid,integer,text,text) to service_role;
notify pgrst, 'reload schema';


-- Focusdesk v1.5.0. Run after v1.4 / migration 07. No scheduler job is activated here.

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
