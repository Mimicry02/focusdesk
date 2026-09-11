-- Focusdesk v1.2 recurring tasks migration.
-- Safe after 03_pic_reports.sql. Re-runnable and additive.
begin;

create table if not exists public.fd_recurrences (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references public.fd_profiles(id) on delete cascade,
 template jsonb not null check(jsonb_typeof(template)='object'),
 pattern text not null check(pattern in ('daily','weekdays','weekly')),
 repeat_interval integer not null default 1 check(repeat_interval between 1 and 30),
 start_date date not null,
 end_date date,
 generated_through date,
 active boolean not null default true,
 version integer not null default 1,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(end_date is null or end_date>=start_date)
);

alter table public.fd_tasks add column if not exists recurrence_id uuid references public.fd_recurrences(id) on delete set null;
alter table public.fd_tasks add column if not exists recurrence_date date;
alter table public.fd_tasks add column if not exists recurrence_pattern text check(recurrence_pattern is null or recurrence_pattern in ('daily','weekdays','weekly'));
alter table public.fd_tasks add column if not exists recurrence_interval integer check(recurrence_interval is null or recurrence_interval between 1 and 30);
create unique index if not exists fd_tasks_recurrence_occurrence on public.fd_tasks(recurrence_id,recurrence_date) where recurrence_id is not null;
create index if not exists fd_recurrences_owner_active on public.fd_recurrences(owner_id,active,start_date);

create or replace function public.fd_repeat_date(p_pattern text,p_interval integer,p_start date,p_day date)
returns boolean language sql immutable parallel safe set search_path='' as $$
 select case p_pattern
  when 'daily' then ((p_day-p_start)%p_interval)=0
  when 'weekdays' then extract(isodow from p_day) between 1 and 5 and ((p_day-p_start)/7)%p_interval=0
  when 'weekly' then ((p_day-p_start)%(7*p_interval))=0
  else false end
$$;

create or replace function public.fd_materialize_recurrences(p_until date default null)
returns integer language plpgsql security definer set search_path='' as $$
declare r public.fd_recurrences; upper_day date; lower_day date; today_day date:=(now() at time zone 'Asia/Jakarta')::date; inserted_count integer; total_count integer:=0;
begin
 if not public.fd_is_active() then raise exception 'Active account required' using errcode='42501';end if;
 upper_day:=least(coalesce(p_until,today_day+7),today_day+31);
 if upper_day<today_day then raise exception 'Recurring horizon invalid';end if;
 perform pg_advisory_xact_lock(hashtextextended('recurrence:'||auth.uid()::text,0));
 for r in
  select x.* from public.fd_recurrences x
  where x.owner_id=auth.uid() and x.active and x.start_date<=upper_day
   and (x.end_date is null or x.end_date>=greatest(x.start_date,today_day-31))
   and (not (x.template ? 'pic_id') or exists(
    select 1 from public.fd_pics p left join public.fd_profiles u on u.id=p.linked_user_id
    where p.id=(x.template->>'pic_id')::uuid and p.owner_id=x.owner_id and p.is_active
     and (p.linked_user_id is null or u.is_active)
   ))
  for update
 loop
  lower_day:=greatest(r.start_date,coalesce(r.generated_through+1,r.start_date),today_day-31);
  if lower_day<=least(upper_day,coalesce(r.end_date,upper_day)) then
   insert into public.fd_tasks(
    user_id,title,category,project,kind,priority,status,due_date,scheduled_date,start_time,duration,notes,top_focus,pic_id,progress_note,
    recurrence_id,recurrence_date,recurrence_pattern,recurrence_interval
   )
   select r.owner_id,r.template->>'title',r.template->>'category',coalesce(r.template->>'project',''),r.template->>'kind',r.template->>'priority','To do',
    case when r.template ? 'due_offset' then d.occurrence_day+(r.template->>'due_offset')::integer else null end,
    d.occurrence_day,nullif(r.template->>'start_time','')::time,(r.template->>'duration')::integer,coalesce(r.template->>'notes',''),false,
    case when r.template ? 'pic_id' then (r.template->>'pic_id')::uuid else null end,'',r.id,d.occurrence_day,r.pattern,r.repeat_interval
   from (
    select x::date occurrence_day from generate_series(lower_day,least(upper_day,coalesce(r.end_date,upper_day)),interval '1 day') x
   ) d
   where public.fd_repeat_date(r.pattern,r.repeat_interval,r.start_date,d.occurrence_day)
   on conflict(recurrence_id,recurrence_date) where recurrence_id is not null do nothing;
   get diagnostics inserted_count=row_count;total_count:=total_count+inserted_count;
  end if;
  update public.fd_recurrences set generated_through=greatest(coalesce(generated_through,start_date-1),least(upper_day,coalesce(end_date,upper_day))),updated_at=now() where id=r.id;
 end loop;
 return total_count;
end $$;

create or replace function public.fd_create_recurrence(p_template jsonb,p_pattern text,p_interval integer,p_end_date date default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare safe jsonb; start_day date; due_day date; today_day date:=(now() at time zone 'Asia/Jakarta')::date; contact_id uuid; recurrence public.fd_recurrences; made integer;
begin
 if not public.fd_is_active() then raise exception 'Active account required' using errcode='42501';end if;
 if p_template is null or jsonb_typeof(p_template)<>'object' or p_pattern not in ('daily','weekdays','weekly') or p_pattern is null or p_interval is null or p_interval not between 1 and 30 then raise exception 'Recurring values invalid';end if;
 start_day:=(p_template->>'scheduled_date')::date;due_day:=nullif(p_template->>'due_date','')::date;contact_id:=nullif(p_template->>'pic_id','')::uuid;
 if start_day is null or p_end_date is not null and p_end_date<start_day then raise exception 'Recurring task needs a valid start/end date';end if;
 if length(trim(coalesce(p_template->>'title',''))) not between 1 and 180 or p_template->>'category' not in ('Full Time','Property','Web Development') or p_template->>'kind' not in ('Delivery','Meeting','Marketing','Follow-up') or p_template->>'priority' not in ('High','Medium','Low') then raise exception 'Recurring task template invalid';end if;
 if length(coalesce(p_template->>'project',''))>100 or length(coalesce(p_template->>'notes',''))>4000 or (p_template->>'duration')::integer not between 5 and 720 then raise exception 'Recurring task template invalid';end if;
 if nullif(p_template->>'start_time','') is not null and extract(hour from nullif(p_template->>'start_time','')::time)*60+extract(minute from nullif(p_template->>'start_time','')::time)+(p_template->>'duration')::integer>1440 then raise exception 'Sesi tidak boleh melewati tengah malam';end if;
 if contact_id is not null and not exists(select 1 from public.fd_pics where id=contact_id and owner_id=auth.uid() and is_active) then raise exception 'PIC tidak aktif atau bukan milik Anda';end if;
 safe:=jsonb_build_object(
  'title',trim(p_template->>'title'),'category',p_template->>'category','project',trim(coalesce(p_template->>'project','')),
  'kind',p_template->>'kind','priority',p_template->>'priority','start_time',coalesce(p_template->>'start_time',''),
  'duration',(p_template->>'duration')::integer,'notes',coalesce(p_template->>'notes','')
 );
 if contact_id is not null then safe:=safe||jsonb_build_object('pic_id',contact_id);end if;
 if due_day is not null then safe:=safe||jsonb_build_object('due_offset',due_day-start_day);end if;
 insert into public.fd_recurrences(owner_id,template,pattern,repeat_interval,start_date,end_date)
 values(auth.uid(),safe,p_pattern,p_interval,start_day,p_end_date) returning * into recurrence;
 made:=public.fd_materialize_recurrences(greatest(today_day+14,start_day));
 return jsonb_build_object('id',recurrence.id,'pattern',recurrence.pattern,'repeat_interval',recurrence.repeat_interval,'start_date',recurrence.start_date,'end_date',recurrence.end_date,'created',made);
end $$;

create or replace function public.fd_stop_recurrence(p_id uuid,p_after date,p_delete_future boolean default true)
returns integer language plpgsql security definer set search_path='' as $$
declare r public.fd_recurrences; removed integer:=0;
begin
 if not public.fd_is_active() then raise exception 'Active account required' using errcode='42501';end if;
 select * into r from public.fd_recurrences where id=p_id and owner_id=auth.uid() for update;
 if not found then raise exception 'Recurring series not found' using errcode='42501';end if;
 update public.fd_recurrences set active=false,version=version+1,updated_at=now() where id=p_id;
 if p_delete_future then
  delete from public.fd_tasks where recurrence_id=p_id and recurrence_date>p_after and status<>'Done';
  get diagnostics removed=row_count;
 end if;
 return removed;
end $$;

alter table public.fd_recurrences enable row level security;
drop policy if exists fd_recurrences_own on public.fd_recurrences;
create policy fd_recurrences_own on public.fd_recurrences for select to authenticated using(owner_id=auth.uid() and public.fd_is_active());
revoke all on public.fd_recurrences from anon,authenticated;
grant select on public.fd_recurrences to authenticated;
grant all on public.fd_recurrences to service_role;
revoke all on function public.fd_repeat_date(text,integer,date,date),public.fd_materialize_recurrences(date),public.fd_create_recurrence(jsonb,text,integer,date),public.fd_stop_recurrence(uuid,date,boolean) from public,anon,authenticated;
grant execute on function public.fd_materialize_recurrences(date),public.fd_create_recurrence(jsonb,text,integer,date),public.fd_stop_recurrence(uuid,date,boolean) to authenticated;
commit;
