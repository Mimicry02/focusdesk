begin;
-- FRESH database only; bootstrap admin separately.
-- Focusdesk v1.0 · Run in Supabase SQL Editor as project owner.
-- Namespaced tables: does not change unrelated application tables.
-- New accounts start INACTIVE; admin approval is required even if public signup is enabled.

create table if not exists public.fd_profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 email text not null, display_name text not null default '' check(length(display_name)<=80),
 role text not null default 'user' check(role in ('admin','user')),
 is_active boolean not null default false,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.fd_preferences (
 user_id uuid primary key references public.fd_profiles(id) on delete cascade,
 capacity integer not null default 360 check(capacity between 30 and 1440),
 email_enabled boolean not null default false
);
create table if not exists public.fd_tasks (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.fd_profiles(id) on delete cascade,
 title text not null check(length(trim(title)) between 1 and 180),
 category text not null check(category in ('Full Time','Property','Web Development')),
 project text not null default '' check(length(project)<=100),
 kind text not null default 'Delivery' check(kind in ('Delivery','Meeting','Marketing','Follow-up')),
 priority text not null default 'Medium' check(priority in ('High','Medium','Low')),
 status text not null default 'To do' check(status in ('Backlog','To do','In progress','Done')),
 due_date date, scheduled_date date, start_time time,
 duration integer not null default 60 check(duration between 5 and 720),
 notes text not null default '' check(length(notes)<=4000),
 top_focus boolean not null default false,
 completed_at timestamptz,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 version integer not null default 1,
 check(start_time is null or scheduled_date is not null),
 check(not top_focus or scheduled_date is not null),
 check(start_time is null or extract(epoch from start_time)+duration*60<=86400)
);
create index if not exists fd_tasks_owner_date on public.fd_tasks(user_id,scheduled_date);
create index if not exists fd_tasks_owner_due on public.fd_tasks(user_id,due_date) where status<>'Done';
create table if not exists public.fd_audit (
 id bigint generated always as identity primary key,
 actor_id uuid references public.fd_profiles(id) on delete set null,
 target_id uuid references public.fd_profiles(id) on delete set null,
 action text not null, details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create table if not exists public.fd_deliveries (
 user_id uuid not null references public.fd_profiles(id) on delete cascade,
 day date not null, status text not null check(status in ('sending','accepted','failed')),
 attempt_at timestamptz not null default now(), accepted_at timestamptz,
 provider_id text, last_error text,
 primary key(user_id,day)
);
create or replace function public.fd_is_active() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.fd_profiles where id=auth.uid() and is_active);
$$;
create or replace function public.fd_is_admin() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.fd_profiles where id=auth.uid() and is_active and role='admin');
$$;
create or replace function public.fd_on_auth_user() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into public.fd_profiles(id,email,display_name) values(new.id,coalesce(new.email,''),left(coalesce(new.raw_user_meta_data->>'display_name',''),80)) on conflict(id) do nothing;
 insert into public.fd_preferences(user_id) values(new.id) on conflict do nothing;
 return new;
end $$;
drop trigger if exists fd_auth_user_created on auth.users;
create trigger fd_auth_user_created after insert on auth.users for each row execute function public.fd_on_auth_user();
create or replace function public.fd_sync_email() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 update public.fd_profiles set email=coalesce(new.email,''),updated_at=now() where id=new.id;
 return new;
end $$;
drop trigger if exists fd_auth_email_changed on auth.users;
create trigger fd_auth_email_changed after update of email on auth.users for each row execute function public.fd_sync_email();
-- Existing Auth users are imported as INACTIVE, never automatically as admins.
insert into public.fd_profiles(id,email,display_name)
 select id,coalesce(email,''),left(coalesce(raw_user_meta_data->>'display_name',''),80) from auth.users on conflict(id) do nothing;
insert into public.fd_preferences(user_id) select id from public.fd_profiles on conflict do nothing;
create or replace function public.fd_task_rules() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(new.user_id::text,0));
 if tg_op='UPDATE' then
  if new.id<>old.id or new.user_id<>old.user_id then raise exception 'Task ownership is immutable'; end if;
  new.version:=old.version+1; new.created_at:=old.created_at;
 else new.version:=1; new.created_at:=now(); end if;
 new.updated_at:=clock_timestamp();
 if new.status='Done' then new.completed_at:=coalesce(new.completed_at,now()); else new.completed_at:=null; end if;
 if new.top_focus and new.status<>'Done' and
  (select count(*) from public.fd_tasks where user_id=new.user_id and scheduled_date=new.scheduled_date and top_focus and status<>'Done' and id<>new.id)>=3
 then raise exception 'Maksimal tiga prioritas aktif pada satu tanggal'; end if;
 return new;
end $$;
drop trigger if exists fd_tasks_rules on public.fd_tasks;
create trigger fd_tasks_rules before insert or update on public.fd_tasks for each row execute function public.fd_task_rules();
create or replace function public.fd_set_user_access(p_target uuid,p_role text,p_active boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended('focusdesk-user-access',0));
 if not public.fd_is_admin() then raise exception 'Admin access required' using errcode='42501'; end if;
 if p_target=auth.uid() then raise exception 'Tidak dapat mengubah role/status akun sendiri'; end if;
 if p_role not in ('user','admin') or p_role is null or p_active is null then raise exception 'Invalid access values'; end if;
 update public.fd_profiles set role=p_role,is_active=p_active,updated_at=now() where id=p_target;
 if not found then raise exception 'User not found'; end if;
 insert into public.fd_audit(actor_id,target_id,action,details) values(auth.uid(),p_target,'access_changed',jsonb_build_object('role',p_role,'is_active',p_active));
end $$;
-- Called only by server secret credential. Claims once per user/WIB date; retries preserve provider idempotency key.
create or replace function public.fd_claim_digest(p_user uuid,p_day date) returns boolean
language plpgsql security definer set search_path='' as $$
declare claimed integer;
begin
 insert into public.fd_deliveries(user_id,day,status) values(p_user,p_day,'sending')
 on conflict(user_id,day) do update set status='sending',attempt_at=now(),last_error=null
 where public.fd_deliveries.status='failed' or (public.fd_deliveries.status='sending' and public.fd_deliveries.attempt_at<now()-interval '10 minutes');
 get diagnostics claimed=row_count; return claimed>0;
end $$;
alter table public.fd_profiles enable row level security;
alter table public.fd_preferences enable row level security;
alter table public.fd_tasks enable row level security;
alter table public.fd_audit enable row level security;
alter table public.fd_deliveries enable row level security;
drop policy if exists fd_profile_read on public.fd_profiles;
create policy fd_profile_read on public.fd_profiles for select to authenticated using(id=auth.uid() or public.fd_is_admin());
drop policy if exists fd_profile_edit on public.fd_profiles;
create policy fd_profile_edit on public.fd_profiles for update to authenticated using(id=auth.uid() and public.fd_is_active()) with check(id=auth.uid() and public.fd_is_active());
drop policy if exists fd_preferences_own on public.fd_preferences;
create policy fd_preferences_own on public.fd_preferences for all to authenticated using(user_id=auth.uid() and public.fd_is_active()) with check(user_id=auth.uid() and public.fd_is_active());
drop policy if exists fd_tasks_own on public.fd_tasks;
create policy fd_tasks_own on public.fd_tasks for all to authenticated using(user_id=auth.uid() and public.fd_is_active()) with check(user_id=auth.uid() and public.fd_is_active());
drop policy if exists fd_audit_admin on public.fd_audit;
create policy fd_audit_admin on public.fd_audit for select to authenticated using(public.fd_is_admin());
drop policy if exists fd_deliveries_own on public.fd_deliveries;
create policy fd_deliveries_own on public.fd_deliveries for select to authenticated using(user_id=auth.uid() and public.fd_is_active());
revoke all on public.fd_profiles,public.fd_preferences,public.fd_tasks,public.fd_audit,public.fd_deliveries from anon,authenticated;
grant select on public.fd_profiles to authenticated;
grant update(display_name) on public.fd_profiles to authenticated;
grant select,insert,update,delete on public.fd_tasks,public.fd_preferences to authenticated;
grant select on public.fd_audit,public.fd_deliveries to authenticated;
grant all on public.fd_profiles,public.fd_preferences,public.fd_tasks,public.fd_audit,public.fd_deliveries to service_role;
grant usage,select on sequence public.fd_audit_id_seq to service_role;
revoke all on function public.fd_is_active(),public.fd_is_admin(),public.fd_on_auth_user(),public.fd_sync_email(),public.fd_task_rules(),public.fd_set_user_access(uuid,text,boolean),public.fd_claim_digest(uuid,date) from public,anon,authenticated;
grant execute on function public.fd_is_active(),public.fd_is_admin(),public.fd_set_user_access(uuid,text,boolean) to authenticated;
grant execute on function public.fd_claim_digest(uuid,date) to service_role;

-- EXISTING v1.3/v1.4 database. Backup first. No bootstrap/cron activation.
-- Focusdesk v1.1 migration. Existing v1 users: run ONLY this file after backup.
-- Fresh installation: run 01_schema.sql, this file, then 02_bootstrap_admin.sql.

create table if not exists public.fd_pics (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references public.fd_profiles(id) on delete cascade,
 name text not null check(length(trim(name)) between 1 and 80),
 email text not null check(length(email)<=254 and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
 linked_user_id uuid references public.fd_profiles(id) on delete set null,
 is_active boolean not null default true,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 version integer not null default 1
);
create unique index if not exists fd_pics_unique_email on public.fd_pics(owner_id,lower(email));
alter table public.fd_tasks add column if not exists pic_id uuid references public.fd_pics(id) on delete restrict;
alter table public.fd_tasks add column if not exists assignee_id uuid references public.fd_profiles(id) on delete set null;
alter table public.fd_tasks add column if not exists pic_name text;
alter table public.fd_tasks add column if not exists pic_email text;
alter table public.fd_tasks add column if not exists owner_name text;
alter table public.fd_tasks add column if not exists owner_email text;
alter table public.fd_tasks add column if not exists progress_note text not null default '' check(length(progress_note)<=4000);
create index if not exists fd_tasks_assignee_date on public.fd_tasks(assignee_id,scheduled_date);
create index if not exists fd_tasks_owner_completed on public.fd_tasks(user_id,completed_at);
-- Preserve task versions/timestamps while adding descriptive snapshots for existing records.
alter table public.fd_tasks disable trigger fd_tasks_rules;
update public.fd_tasks t set owner_name=p.display_name,owner_email=p.email from public.fd_profiles p where p.id=t.user_id and t.owner_email is null;
alter table public.fd_tasks enable trigger fd_tasks_rules;
create table if not exists public.fd_assignment_messages (
 id uuid primary key default gen_random_uuid(),
 task_id uuid not null references public.fd_tasks(id) on delete cascade,
 owner_id uuid not null references public.fd_profiles(id) on delete cascade,
 task_version integer not null,
 recipient_email text not null,
 payload jsonb not null,
 status text not null check(status in ('sending','accepted','failed')),
 created_at timestamptz not null default now(), attempt_at timestamptz not null default now(),
 accepted_at timestamptz, provider_id text, last_error text,
 unique(task_id,task_version,recipient_email)
);
create or replace function public.fd_save_pic(p_id uuid,p_name text,p_email text,p_link boolean,p_active boolean,p_version integer default null)
returns public.fd_pics language plpgsql security definer set search_path='' as $$
declare previous public.fd_pics; target uuid; result public.fd_pics;
begin
 if not public.fd_is_active() then raise exception 'Active account required' using errcode='42501'; end if;
 if p_name is null or length(trim(p_name)) not between 1 and 80 or p_email is null or length(p_email)>254 or p_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or p_link is null or p_active is null then raise exception 'PIC values invalid'; end if;
 p_email:=lower(trim(p_email));
 if p_link then
  select id into target from public.fd_profiles where lower(email)=p_email and (is_active or not p_active);
  if target is null then raise exception 'Belum ada akun aktif dengan email ini. Undang/aktifkan akun dahulu, atau gunakan Email only.'; end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('pic:'||auth.uid()::text,0));
 select * into previous from public.fd_pics where id=p_id for update;
 if found then
  if previous.owner_id<>auth.uid() then raise exception 'PIC not owned' using errcode='42501'; end if;
  if p_version is null or previous.version<>p_version then raise exception 'PIC telah berubah. Muat ulang sebelum mengedit.'; end if;
  if (previous.email is distinct from p_email) and exists(select 1 from public.fd_tasks where pic_id=p_id) then
   raise exception 'PIC sedang digunakan. Buat kontak PIC baru untuk email yang berbeda, lalu tugaskan ulang secara eksplisit.';
  end if;
  update public.fd_pics set name=trim(p_name),email=p_email,linked_user_id=target,is_active=p_active,updated_at=now(),version=version+1 where id=p_id returning * into result;
 else
  if p_version is not null then raise exception 'PIC tidak ditemukan'; end if;
  insert into public.fd_pics(id,owner_id,name,email,linked_user_id,is_active) values(coalesce(p_id,gen_random_uuid()),auth.uid(),trim(p_name),p_email,target,p_active) returning * into result;
 end if;
 return result;
end $$;
create or replace function public.fd_task_rules() returns trigger
language plpgsql security definer set search_path='' as $$
declare contact public.fd_pics;
begin
 -- Enforce field-level sharing even when clients call Supabase REST directly.
 if tg_op='UPDATE' and auth.uid() is not null and auth.uid()<>old.user_id then
  if not public.fd_is_active() or old.assignee_id is distinct from auth.uid() then raise exception 'Task access denied' using errcode='42501'; end if;
  if (to_jsonb(new)-array['status','progress_note']) is distinct from (to_jsonb(old)-array['status','progress_note']) then
   raise exception 'PIC hanya dapat mengubah status dan catatan progres' using errcode='42501';
  end if;
  if new.status not in ('To do','In progress','Done') then raise exception 'PIC tidak dapat mengubah status menjadi Backlog'; end if;
 else
  if auth.uid() is not null and new.user_id<>auth.uid() then raise exception 'row-level security: task ownership denied' using errcode='42501'; end if;
  if new.pic_id is not null then
   select * into contact from public.fd_pics where id=new.pic_id;
   if not found or contact.owner_id<>new.user_id then raise exception 'PIC tidak dimiliki pemilik tugas'; end if;
   if not contact.is_active and (tg_op='INSERT' or new.pic_id is distinct from old.pic_id) then raise exception 'PIC nonaktif tidak dapat menerima penugasan baru'; end if;
   if contact.linked_user_id is not null and not exists(select 1 from public.fd_profiles where id=contact.linked_user_id and is_active) and (tg_op='INSERT' or new.pic_id is distinct from old.pic_id) then raise exception 'Akun PIC tidak aktif'; end if;
   new.assignee_id:=contact.linked_user_id;new.pic_name:=contact.name;new.pic_email:=contact.email;
  else new.assignee_id:=null;new.pic_name:=null;new.pic_email:=null;end if;
  select display_name,email into new.owner_name,new.owner_email from public.fd_profiles where id=new.user_id;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(new.user_id::text,0));
 if tg_op='UPDATE' then
  if new.id<>old.id or new.user_id<>old.user_id then raise exception 'Task ownership is immutable'; end if;
  new.version:=old.version+1;new.created_at:=old.created_at;
 else new.version:=1;new.created_at:=now();end if;
 new.updated_at:=clock_timestamp();
 if new.status='Done' then
  if tg_op='INSERT' or old.status<>'Done' then new.completed_at:=now();else new.completed_at:=old.completed_at;end if;
 else new.completed_at:=null;end if;
 if new.top_focus and new.status<>'Done' and (select count(*) from public.fd_tasks where user_id=new.user_id and scheduled_date=new.scheduled_date and top_focus and status<>'Done' and id<>new.id)>=3 then raise exception 'Maksimal tiga prioritas aktif pada satu tanggal';end if;
 return new;
end $$;
drop policy if exists fd_tasks_own on public.fd_tasks;
drop policy if exists fd_tasks_read on public.fd_tasks;
drop policy if exists fd_tasks_insert on public.fd_tasks;
drop policy if exists fd_tasks_update on public.fd_tasks;
drop policy if exists fd_tasks_delete on public.fd_tasks;
create policy fd_tasks_read on public.fd_tasks for select to authenticated using(public.fd_is_active() and (user_id=auth.uid() or assignee_id=auth.uid()));
create policy fd_tasks_insert on public.fd_tasks for insert to authenticated with check(public.fd_is_active() and user_id=auth.uid());
create policy fd_tasks_update on public.fd_tasks for update to authenticated using(public.fd_is_active() and (user_id=auth.uid() or assignee_id=auth.uid())) with check(public.fd_is_active() and (user_id=auth.uid() or assignee_id=auth.uid()));
create policy fd_tasks_delete on public.fd_tasks for delete to authenticated using(public.fd_is_active() and user_id=auth.uid());
alter table public.fd_pics enable row level security;
alter table public.fd_assignment_messages enable row level security;
drop policy if exists fd_pics_own on public.fd_pics;
create policy fd_pics_own on public.fd_pics for select to authenticated using(owner_id=auth.uid() and public.fd_is_active());
drop policy if exists fd_assignment_own on public.fd_assignment_messages;
create policy fd_assignment_own on public.fd_assignment_messages for select to authenticated using(owner_id=auth.uid() and public.fd_is_active());
revoke all on public.fd_pics,public.fd_assignment_messages from anon,authenticated;
grant select on public.fd_pics,public.fd_assignment_messages to authenticated;
grant all on public.fd_pics,public.fd_assignment_messages to service_role;
create or replace function public.fd_prepare_assignment(p_task uuid,p_version integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.fd_tasks; m public.fd_assignment_messages;
begin
 if not public.fd_is_active() then raise exception 'Active account required' using errcode='42501';end if;
 select * into t from public.fd_tasks where id=p_task and user_id=auth.uid() for update;
 if not found then raise exception 'Hanya pemilik tugas dapat mengirim email' using errcode='42501';end if;
 if p_version is null or t.version<>p_version then raise exception 'Tugas telah berubah. Buka ulang preview email sebelum mengirim.';end if;
 if t.pic_id is null or t.pic_email is null then raise exception 'Pilih PIC pada tugas terlebih dahulu';end if;
 if not exists(select 1 from public.fd_pics where id=t.pic_id and is_active) then raise exception 'PIC nonaktif';end if;
 select * into m from public.fd_assignment_messages where task_id=t.id and task_version=t.version and recipient_email=t.pic_email for update;
 if found then
  if m.status='accepted' or (m.status='sending' and m.attempt_at>now()-interval '10 minutes') then return jsonb_build_object('claimed',false,'message',to_jsonb(m));end if;
  if m.created_at<now()-interval '23 hours' then raise exception 'Percobaan lama perlu diperiksa di provider. Jangan retry tanpa meninjau status pengiriman.';end if;
  update public.fd_assignment_messages set status='sending',attempt_at=now(),last_error=null where id=m.id returning * into m;
 else
  insert into public.fd_assignment_messages(task_id,owner_id,task_version,recipient_email,payload,status) values(t.id,t.user_id,t.version,t.pic_email,to_jsonb(t),'sending') returning * into m;
 end if;
 return jsonb_build_object('claimed',true,'message',to_jsonb(m));
end $$;
revoke all on function public.fd_save_pic(uuid,text,text,boolean,boolean,integer),public.fd_prepare_assignment(uuid,integer) from public,anon,authenticated;
grant execute on function public.fd_save_pic(uuid,text,text,boolean,boolean,integer),public.fd_prepare_assignment(uuid,integer) to authenticated;
-- One statement returns one RLS-protected report snapshot (no paginated partial report).
create or replace function public.fd_report_tasks(p_start date,p_end date,p_basis text,p_scope text,p_category text default null,p_pic uuid default null,p_self boolean default false)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb;
begin
 if p_start is null or p_end is null or extract(day from p_start)<>1 or p_end<>(p_start+interval '1 month')::date or p_basis not in ('scheduled','due','completed') or p_scope not in ('owned','assigned','all') or p_basis is null or p_scope is null then raise exception 'Invalid report period/filter';end if;
 if p_category is not null and p_category not in ('Full Time','Property','Web Development') then raise exception 'Invalid category';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at,x.id),'[]'::jsonb) into result from (
  select t.* from public.fd_tasks t where
   (case p_basis when 'scheduled' then t.scheduled_date when 'due' then t.due_date else (t.completed_at at time zone 'Asia/Jakarta')::date end)>=p_start and
   (case p_basis when 'scheduled' then t.scheduled_date when 'due' then t.due_date else (t.completed_at at time zone 'Asia/Jakarta')::date end)<p_end and
   (p_scope='all' or (p_scope='owned' and t.user_id=auth.uid()) or (p_scope='assigned' and t.assignee_id=auth.uid() and t.user_id<>auth.uid())) and
   (p_category is null or t.category=p_category) and
   (p_pic is null or t.pic_id=p_pic) and (not p_self or t.pic_id is null)
  order by t.created_at,t.id limit 10001
 ) x;
 if jsonb_array_length(result)>10000 then raise exception 'Laporan melebihi 10000 baris. Persempit filter kategori/PIC.';end if;
 if octet_length(result::text)>3000000 then raise exception 'Data laporan terlalu besar. Persempit filter kategori/PIC.';end if;
 return result;
end $$;
revoke all on function public.fd_report_tasks(date,date,text,text,text,uuid,boolean) from public,anon,authenticated;
grant execute on function public.fd_report_tasks(date,date,text,text,text,uuid,boolean) to authenticated;

-- Focusdesk v1.2 recurring tasks migration.
-- Safe after 03_pic_reports.sql. Re-runnable and additive.

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

-- Focusdesk v1.3. Run after 04_recurring_tasks.sql. Additive, replay-safe.

create table if not exists public.fd_telegram_accounts (
 user_id uuid primary key references public.fd_profiles(id) on delete cascade,
 telegram_id bigint not null unique check(telegram_id>0),
 chat_id bigint not null check(chat_id=telegram_id),
 created_at timestamptz not null default now()
);
create table if not exists public.fd_telegram_groups (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references public.fd_profiles(id) on delete cascade,
 chat_id bigint not null unique check(chat_id<0),
 title text not null check(length(title)<=200),
 active boolean not null default true, created_at timestamptz not null default now()
);
create table if not exists public.fd_telegram_codes (
 hash text primary key check(length(hash)=64),
 user_id uuid not null references public.fd_profiles(id) on delete cascade,
 kind text not null check(kind in ('personal','group')),
 expires_at timestamptz not null default now()+interval '10 minutes'
);
alter table public.fd_tasks add column if not exists requires_testing boolean not null default false;
alter table public.fd_tasks add column if not exists acceptance_criteria text not null default '' check(length(acceptance_criteria)<=4000);
alter table public.fd_tasks add column if not exists test_cycle integer not null default 0;
alter table public.fd_tasks add column if not exists telegram_group_id uuid references public.fd_telegram_groups(id) on delete restrict;
alter table public.fd_tasks drop constraint if exists fd_tasks_status_check;
alter table public.fd_tasks add constraint fd_tasks_status_check check(status in ('Backlog','To do','In progress','Ready for Testing','Testing','Rework','Done'));
create table if not exists public.fd_task_activity (
 id uuid primary key default gen_random_uuid(), task_id uuid not null references public.fd_tasks(id) on delete cascade,
 actor_id uuid references public.fd_profiles(id) on delete set null,
 from_status text, to_status text not null, test_cycle integer not null,
 note text not null default '', task_version integer not null, created_at timestamptz not null default now()
);
create index if not exists fd_activity_task on public.fd_task_activity(task_id,created_at);
create table if not exists public.fd_telegram_outbox (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.fd_profiles(id) on delete cascade,
 target_user_id uuid references public.fd_profiles(id) on delete cascade,
 target_group_id uuid references public.fd_telegram_groups(id) on delete cascade,
 task_id uuid references public.fd_tasks(id) on delete cascade,
 kind text not null check(kind in ('task','digest')),
 day date, dedupe_key text not null unique,
 status text not null default 'pending' check(status in ('pending','sending','sent','failed','uncertain','skipped')),
 attempts integer not null default 0, next_attempt_at timestamptz not null default now(),
 attempted_at timestamptz, sent_at timestamptz, last_error text, created_at timestamptz not null default now(),
 check((target_user_id is null)<>(target_group_id is null))
);
create index if not exists fd_tg_queue on public.fd_telegram_outbox(status,next_attempt_at,created_at);
create table if not exists public.fd_telegram_messages (
 chat_id bigint not null, message_id bigint not null,
 task_id uuid references public.fd_tasks(id) on delete cascade, task_version integer,
 target_user_id uuid references public.fd_profiles(id) on delete cascade,
 target_group_id uuid references public.fd_telegram_groups(id) on delete cascade,
 created_at timestamptz not null default now(), primary key(chat_id,message_id)
);
create table if not exists public.fd_telegram_updates (
 update_id bigint primary key, created_at timestamptz not null default now()
);

-- Extra guard runs BEFORE the existing PIC/owner guard. Derived cycle cannot be forged.
create or replace function public.fd_workflow_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare reviewer boolean:=auth.uid()=new.user_id;
begin
 if new.telegram_group_id is not null and not exists(select 1 from public.fd_telegram_groups where id=new.telegram_group_id and owner_id=new.user_id and active) then
  if tg_op='INSERT' or new.telegram_group_id is distinct from old.telegram_group_id then raise exception 'Pilih grup Telegram aktif milik Anda';end if;
 end if;
 if tg_op='UPDATE' and (new.recurrence_id is distinct from old.recurrence_id or new.recurrence_date is distinct from old.recurrence_date or new.recurrence_pattern is distinct from old.recurrence_pattern or new.recurrence_interval is distinct from old.recurrence_interval) then raise exception 'Identitas occurrence tidak dapat diubah';end if;
 if new.recurrence_id is not null and not exists(select 1 from public.fd_recurrences r where r.id=new.recurrence_id and r.owner_id=new.user_id) then raise exception 'Recurring series bukan milik Anda';end if;
 if tg_op='INSERT' then
  new.test_cycle:=0;
  if new.requires_testing and new.status not in ('Backlog','To do','In progress') then raise exception 'Tugas testing baru harus dimulai sebelum tahap review';end if;
 else
  if new.test_cycle is distinct from old.test_cycle then raise exception 'Test cycle dikelola sistem';end if;
  if old.requires_testing and not new.requires_testing then raise exception 'Testing tidak dapat dinonaktifkan pada tugas yang sudah memerlukannya';end if;
  if not old.requires_testing and new.requires_testing and old.status not in ('Backlog','To do','In progress','Rework') then raise exception 'Aktifkan testing sebelum tugas selesai';end if;
  if new.requires_testing then
   if old.status in ('Ready for Testing','Testing') and (new.pic_id is distinct from old.pic_id or new.acceptance_criteria is distinct from old.acceptance_criteria) then raise exception 'Kembalikan untuk perbaikan sebelum mengganti PIC/kriteria';end if;
   if new.status is distinct from old.status then
    if not (
      (old.status in ('Backlog','To do','Rework') and new.status='In progress') or
      (old.status='In progress' and new.status='Ready for Testing') or
      (reviewer and old.status='Ready for Testing' and new.status='Testing') or
      (reviewer and old.status='Testing' and new.status in ('Done','Rework')) or
      (reviewer and old.status='Ready for Testing' and new.status='Rework') or
      (reviewer and old.status='Done' and new.status='Rework')
    ) then raise exception 'Transisi testing tidak diizinkan. PIC kirim Need Testing; pemilik melakukan review.';end if;
    if new.status='Rework' and (length(trim(new.progress_note))=0 or new.progress_note=old.progress_note) then raise exception 'Tuliskan alasan baru untuk pengembalian/reopen';end if;
   end if;
  end if;
 end if;
 if not new.requires_testing and new.status in ('Ready for Testing','Testing','Rework') then raise exception 'Status ini khusus tugas dengan testing';end if;
 return new;
end $$;
drop trigger if exists fd_tasks_00_workflow on public.fd_tasks;
create trigger fd_tasks_00_workflow before insert or update on public.fd_tasks for each row execute function public.fd_workflow_guard();
-- Runs after fd_tasks_rules so PIC field comparisons see only client-written fields.
create or replace function public.fd_workflow_cycle() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' and new.status='Ready for Testing' and old.status<>'Ready for Testing' then new.test_cycle:=old.test_cycle+1;end if;
 return new;
end $$;
drop trigger if exists fd_tasks_zz_cycle on public.fd_tasks;
create trigger fd_tasks_zz_cycle before insert or update on public.fd_tasks for each row execute function public.fd_workflow_cycle();

create or replace function public.fd_tg_enqueue_task(p_task uuid,p_key text) returns void
language plpgsql security definer set search_path='' as $$
declare t public.fd_tasks; u uuid;
begin
 select * into t from public.fd_tasks where id=p_task;
 if not found then return;end if;
 for u in select distinct x from unnest(array[t.user_id,t.assignee_id]) x where x is not null loop
  if exists(select 1 from public.fd_telegram_accounts where user_id=u) then
   insert into public.fd_telegram_outbox(owner_id,target_user_id,task_id,kind,dedupe_key)
   values(t.user_id,u,t.id,'task',p_key||':u:'||u) on conflict(dedupe_key) do nothing;
  end if;
 end loop;
 if t.telegram_group_id is not null then
  insert into public.fd_telegram_outbox(owner_id,target_group_id,task_id,kind,dedupe_key)
  values(t.user_id,t.telegram_group_id,t.id,'task',p_key||':g:'||t.telegram_group_id) on conflict(dedupe_key) do nothing;
 end if;
end $$;
create or replace function public.fd_task_event() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' or new.status is distinct from old.status or new.progress_note is distinct from old.progress_note then
  insert into public.fd_task_activity(task_id,actor_id,from_status,to_status,test_cycle,note,task_version)
  values(new.id,auth.uid(),case when tg_op='UPDATE' then old.status else null end,new.status,new.test_cycle,new.progress_note,new.version);
 end if;
 if new.recurrence_date is null or new.recurrence_date=(now() at time zone 'Asia/Jakarta')::date or (tg_op='UPDATE' and new.recurrence_date<(now() at time zone 'Asia/Jakarta')::date) then
  perform public.fd_tg_enqueue_task(new.id,'event:'||new.id||':'||new.version);
 end if;
 return new;
end $$;
drop trigger if exists fd_tasks_event on public.fd_tasks;
create trigger fd_tasks_event after insert or update on public.fd_tasks for each row execute function public.fd_task_event();

create or replace function public.fd_tg_new_code(p_hash text,p_kind text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not public.fd_is_active() then raise exception 'Active account required' using errcode='42501';end if;
 if p_kind='group' and not exists(select 1 from public.fd_telegram_accounts where user_id=auth.uid()) then raise exception 'Hubungkan akun Telegram pribadi dahulu';end if;
 delete from public.fd_telegram_codes where user_id=auth.uid() and kind=p_kind;
 insert into public.fd_telegram_codes(hash,user_id,kind) values(p_hash,auth.uid(),p_kind);
end $$;
create or replace function public.fd_tg_redeem(p_hash text,p_telegram bigint,p_chat bigint,p_kind text,p_title text)
returns void language plpgsql security definer set search_path='' as $$
declare c public.fd_telegram_codes;
begin
 select * into c from public.fd_telegram_codes where hash=p_hash and kind=p_kind and expires_at>now() for update;
 if not found or not exists(select 1 from public.fd_profiles where id=c.user_id and is_active) then raise exception 'Kode tidak valid atau kedaluwarsa';end if;
 if p_kind='personal' then
  if p_chat<>p_telegram or p_chat<=0 then raise exception 'Gunakan chat pribadi bot';end if;
  insert into public.fd_telegram_accounts(user_id,telegram_id,chat_id) values(c.user_id,p_telegram,p_chat)
  on conflict(user_id) do update set telegram_id=excluded.telegram_id,chat_id=excluded.chat_id;
 else
  if p_chat>=0 or not exists(select 1 from public.fd_telegram_accounts where user_id=c.user_id and telegram_id=p_telegram) then raise exception 'Hanya pemilik kode yang sudah terhubung dapat menghubungkan grup';end if;
  if exists(select 1 from public.fd_telegram_groups where chat_id=p_chat and owner_id<>c.user_id) then raise exception 'Grup sudah terhubung ke pemilik lain';end if;
  insert into public.fd_telegram_groups(owner_id,chat_id,title) values(c.user_id,p_chat,left(p_title,200))
  on conflict(chat_id) do update set active=true,title=excluded.title;
 end if;
 delete from public.fd_telegram_codes where hash=p_hash;
end $$;
create or replace function public.fd_tg_disconnect(p_group uuid default null) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not public.fd_is_active() then raise exception 'Active account required' using errcode='42501';end if;
 if p_group is null then
  delete from public.fd_telegram_accounts where user_id=auth.uid();
  delete from public.fd_telegram_codes where user_id=auth.uid();
 else update public.fd_telegram_groups set active=false where id=p_group and owner_id=auth.uid();end if;
end $$;

-- Transactional update: verifies message binding, current PIC/owner, active accounts,
-- version, and update_id. Only service_role may call (webhook verifies secret).
create or replace function public.fd_tg_action(p_update bigint,p_telegram bigint,p_chat bigint,p_message bigint,p_task uuid,p_version integer,p_status text,p_note text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid; t public.fd_tasks; prior text:=current_setting('request.jwt.claim.sub',true); n integer;
begin
 select a.user_id into actor from public.fd_telegram_accounts a join public.fd_profiles p on p.id=a.user_id and p.is_active where a.telegram_id=p_telegram;
 if actor is null then raise exception 'Hubungkan akun Focusdesk Anda dahulu';end if;
 select * into t from public.fd_tasks where id=p_task for update;
 if not found or not exists(select 1 from public.fd_profiles where id=t.user_id and is_active) or (actor<>t.user_id and actor is distinct from t.assignee_id) then raise exception 'Anda bukan pemilik atau PIC aktif tugas ini';end if;
 if not exists(select 1 from public.fd_telegram_messages m where m.chat_id=p_chat and m.message_id=p_message and m.task_id=t.id and m.task_version=p_version
  and ((p_chat>0 and m.target_user_id=actor) or (p_chat<0 and m.target_group_id=t.telegram_group_id and exists(select 1 from public.fd_telegram_groups g where g.id=m.target_group_id and g.active)))) then raise exception 'Pesan tidak terhubung dengan tugas/grup ini';end if;
 insert into public.fd_telegram_updates(update_id) values(p_update) on conflict do nothing;
 get diagnostics n=row_count;if n=0 then return jsonb_build_object('duplicate',true);end if;
 if t.version<>p_version then raise exception 'Pesan sudah lama. Ketik /tasks untuk tombol terbaru.';end if;
 if p_status is null or p_status not in ('Backlog','To do','In progress','Ready for Testing','Testing','Rework','Done') or length(coalesce(p_note,''))>4000 then raise exception 'Tindakan tidak valid';end if;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 update public.fd_tasks set status=p_status,progress_note=coalesce(p_note,progress_note) where id=p_task returning * into t;
 perform set_config('request.jwt.claim.sub',coalesce(prior,''),true);
 return jsonb_build_object('status',t.status,'version',t.version);
end $$;

create or replace function public.fd_tg_claim(p_owner uuid default null,p_limit integer default 8)
returns setof public.fd_telegram_outbox language plpgsql security definer set search_path='' as $$
begin
 -- A crashed/ambiguous send is NOT retried automatically: Telegram has no send idempotency key.
 update public.fd_telegram_outbox set status='uncertain',last_error='Worker interrupted; inspect Telegram before manual resend' where status='sending' and attempted_at<now()-interval '5 minutes';
 return query with q as (
  select id from public.fd_telegram_outbox where status in ('pending','failed') and attempts<5 and next_attempt_at<=now() and (p_owner is null or owner_id=p_owner)
  order by created_at for update skip locked limit least(greatest(p_limit,1),20)
 ) update public.fd_telegram_outbox o set status='sending',attempts=attempts+1,attempted_at=now() from q where o.id=q.id returning o.*;
end $$;

-- Private tables: no client inserts/updates, even via direct Supabase REST.
do $$declare n text;begin
 foreach n in array array['fd_telegram_accounts','fd_telegram_groups','fd_telegram_codes','fd_task_activity','fd_telegram_outbox','fd_telegram_messages','fd_telegram_updates'] loop
  execute format('alter table public.%I enable row level security',n);
  execute format('revoke all on public.%I from anon,authenticated',n);
  execute format('grant all on public.%I to service_role',n);
 end loop;
end $$;
grant select on public.fd_telegram_accounts,public.fd_telegram_groups,public.fd_task_activity to authenticated;
drop policy if exists fd_tg_account_own on public.fd_telegram_accounts;
create policy fd_tg_account_own on public.fd_telegram_accounts for select to authenticated using(user_id=auth.uid() and public.fd_is_active());
drop policy if exists fd_tg_group_own on public.fd_telegram_groups;
create policy fd_tg_group_own on public.fd_telegram_groups for select to authenticated using(owner_id=auth.uid() and public.fd_is_active());
drop policy if exists fd_activity_access on public.fd_task_activity;
create policy fd_activity_access on public.fd_task_activity for select to authenticated using(exists(select 1 from public.fd_tasks t where t.id=task_id));
revoke all on function public.fd_workflow_guard(),public.fd_workflow_cycle(),public.fd_task_event(),public.fd_tg_enqueue_task(uuid,text),public.fd_tg_new_code(text,text),public.fd_tg_redeem(text,bigint,bigint,text,text),public.fd_tg_disconnect(uuid),public.fd_tg_action(bigint,bigint,bigint,bigint,uuid,integer,text,text),public.fd_tg_claim(uuid,integer) from public,anon,authenticated;
grant execute on function public.fd_tg_new_code(text,text),public.fd_tg_disconnect(uuid) to authenticated;
grant execute on function public.fd_tg_redeem(text,bigint,bigint,text,text),public.fd_tg_action(bigint,bigint,bigint,bigint,uuid,integer,text,text),public.fd_tg_claim(uuid,integer),public.fd_tg_enqueue_task(uuid,text) to service_role;
create or replace function public.fd_task_rules() returns trigger
language plpgsql security definer set search_path='' as $$
declare contact public.fd_pics;
begin
 -- Enforce field-level sharing even when clients call Supabase REST directly.
 if tg_op='UPDATE' and auth.uid() is not null and auth.uid()<>old.user_id then
  if not public.fd_is_active() or old.assignee_id is distinct from auth.uid() then raise exception 'Task access denied' using errcode='42501'; end if;
  if (to_jsonb(new)-array['status','progress_note']) is distinct from (to_jsonb(old)-array['status','progress_note']) then
   raise exception 'PIC hanya dapat mengubah status dan catatan progres' using errcode='42501';
  end if;
  if new.status not in ('To do','In progress','Ready for Testing','Testing','Rework','Done') and new.status is distinct from old.status then raise exception 'PIC tidak dapat mengubah status menjadi Backlog'; end if;
 else
  if auth.uid() is not null and new.user_id<>auth.uid() then raise exception 'row-level security: task ownership denied' using errcode='42501'; end if;
  if new.pic_id is not null then
   select * into contact from public.fd_pics where id=new.pic_id;
   if not found or contact.owner_id<>new.user_id then raise exception 'PIC tidak dimiliki pemilik tugas'; end if;
   if not contact.is_active and (tg_op='INSERT' or new.pic_id is distinct from old.pic_id) then raise exception 'PIC nonaktif tidak dapat menerima penugasan baru'; end if;
   if contact.linked_user_id is not null and not exists(select 1 from public.fd_profiles where id=contact.linked_user_id and is_active) and (tg_op='INSERT' or new.pic_id is distinct from old.pic_id) then raise exception 'Akun PIC tidak aktif'; end if;
   new.assignee_id:=contact.linked_user_id;new.pic_name:=contact.name;new.pic_email:=contact.email;
  else new.assignee_id:=null;new.pic_name:=null;new.pic_email:=null;end if;
  select display_name,email into new.owner_name,new.owner_email from public.fd_profiles where id=new.user_id;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(new.user_id::text,0));
 if tg_op='UPDATE' then
  if new.id<>old.id or new.user_id<>old.user_id then raise exception 'Task ownership is immutable'; end if;
  new.version:=old.version+1;new.created_at:=old.created_at;
 else new.version:=1;new.created_at:=now();end if;
 new.updated_at:=clock_timestamp();
 if new.status='Done' then
  if tg_op='INSERT' or old.status<>'Done' then new.completed_at:=now();else new.completed_at:=old.completed_at;end if;
 else new.completed_at:=null;end if;
 if new.top_focus and new.status<>'Done' and (select count(*) from public.fd_tasks where user_id=new.user_id and scheduled_date=new.scheduled_date and top_focus and status<>'Done' and id<>new.id)>=3 then raise exception 'Maksimal tiga prioritas aktif pada satu tanggal';end if;
 return new;
end $$;

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
    recurrence_id,recurrence_date,recurrence_pattern,recurrence_interval,requires_testing,acceptance_criteria,telegram_group_id
   )
   select r.owner_id,r.template->>'title',r.template->>'category',coalesce(r.template->>'project',''),r.template->>'kind',r.template->>'priority','To do',
    case when r.template ? 'due_offset' then d.occurrence_day+(r.template->>'due_offset')::integer else null end,
    d.occurrence_day,nullif(r.template->>'start_time','')::time,(r.template->>'duration')::integer,coalesce(r.template->>'notes',''),false,
    case when r.template ? 'pic_id' then (r.template->>'pic_id')::uuid else null end,'',r.id,d.occurrence_day,r.pattern,r.repeat_interval,coalesce((r.template->>'requires_testing')::boolean,false),coalesce(r.template->>'acceptance_criteria',''),case when exists(select 1 from public.fd_telegram_groups g where g.id=nullif(r.template->>'telegram_group_id','')::uuid and g.owner_id=r.owner_id and g.active) then nullif(r.template->>'telegram_group_id','')::uuid else null end
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
 safe:=safe||jsonb_build_object('requires_testing',coalesce((p_template->>'requires_testing')::boolean,false),'acceptance_criteria',coalesce(p_template->>'acceptance_criteria',''),'telegram_group_id',nullif(p_template->>'telegram_group_id',''));
 if length(safe->>'acceptance_criteria')>4000 then raise exception 'Kriteria terlalu panjang';end if;
 if nullif(safe->>'telegram_group_id','') is not null and not exists(select 1 from public.fd_telegram_groups where id=(safe->>'telegram_group_id')::uuid and owner_id=auth.uid() and active) then raise exception 'Grup bukan milik Anda';end if;
 if contact_id is not null then safe:=safe||jsonb_build_object('pic_id',contact_id);end if;
 if due_day is not null then safe:=safe||jsonb_build_object('due_offset',due_day-start_day);end if;
 insert into public.fd_recurrences(owner_id,template,pattern,repeat_interval,start_date,end_date)
 values(auth.uid(),safe,p_pattern,p_interval,start_day,p_end_date) returning * into recurrence;
 made:=public.fd_materialize_recurrences(greatest(today_day+14,start_day));
 return jsonb_build_object('id',recurrence.id,'pattern',recurrence.pattern,'repeat_interval',recurrence.repeat_interval,'start_date',recurrence.start_date,'end_date',recurrence.end_date,'created',made);
end $$;



-- Daily server materialization without exposing arbitrary account impersonation.
create or replace function public.fd_tg_daily() returns integer
language plpgsql security definer set search_path='' as $$
declare u uuid; a record; n integer:=0; d date:=(now() at time zone 'Asia/Jakarta')::date; prior text:=current_setting('request.jwt.claim.sub',true);
begin
 perform pg_advisory_xact_lock(hashtextextended('fd-telegram-daily',0));
 for u in select distinct r.owner_id from public.fd_recurrences r join public.fd_profiles p on p.id=r.owner_id and p.is_active where r.active loop
  perform set_config('request.jwt.claim.sub',u::text,true);
  n:=n+public.fd_materialize_recurrences(d+14);
 end loop;
 perform set_config('request.jwt.claim.sub',coalesce(prior,''),true);
 for a in select x.* from public.fd_telegram_accounts x join public.fd_profiles p on p.id=x.user_id and p.is_active loop
  insert into public.fd_telegram_outbox(owner_id,target_user_id,kind,day,dedupe_key)
  values(a.user_id,a.user_id,'digest',d,'daily:'||d||':u:'||a.user_id) on conflict do nothing;
 end loop;
 for a in select g.* from public.fd_telegram_groups g join public.fd_profiles p on p.id=g.owner_id and p.is_active where g.active loop
  insert into public.fd_telegram_outbox(owner_id,target_group_id,kind,day,dedupe_key)
  values(a.owner_id,a.id,'digest',d,'daily:'||d||':g:'||a.id) on conflict do nothing;
 end loop;
 delete from public.fd_telegram_codes where expires_at<now();
 delete from public.fd_telegram_updates where created_at<now()-interval '30 days';
 delete from public.fd_telegram_messages where created_at<now()-interval '30 days';
 delete from public.fd_telegram_outbox where status in ('sent','skipped') and created_at<now()-interval '90 days';
 return n;
end $$;
revoke all on function public.fd_tg_daily() from public,anon,authenticated;
grant execute on function public.fd_tg_daily() to service_role;


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

-- Focusdesk 1.6.0 — additive migration, run AFTER 08_scheduled_briefings.sql.

create table if not exists public.fd_desk_priorities (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.fd_profiles(id),
 name text not null check(length(name) between 1 and 60), task_priority text not null check(task_priority in ('Low','Medium','High')),
 sort_order integer not null default 2, response_hours integer not null default 8 check(response_hours between 1 and 720),
 resolution_hours integer not null default 48 check(resolution_hours between 1 and 8760), active boolean not null default true,
 unique(owner_id,name)
);
create table if not exists public.fd_desk_categories (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.fd_profiles(id),
 name text not null check(length(name) between 1 and 80), description text not null default '', active boolean not null default true,
 unique(owner_id,name)
);
create table if not exists public.fd_applications (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.fd_profiles(id),
 code text not null check(code ~ '^[A-Z0-9_-]{2,20}$'), name text not null check(length(name) between 1 and 100),
 description text not null default '', work_area text not null default 'Full Time' check(work_area in ('Full Time','Property','Web Development')),
 default_pic_id uuid references public.fd_pics(id), backup_pic_id uuid references public.fd_pics(id),
 priority_id uuid not null references public.fd_desk_priorities(id), requires_testing boolean not null default true,
 active boolean not null default true, unique(owner_id,code)
);
create table if not exists public.fd_desk_routes (
 id uuid primary key default gen_random_uuid(), application_id uuid not null references public.fd_applications(id),
 category_id uuid not null references public.fd_desk_categories(id), pic_id uuid references public.fd_pics(id),
 priority_id uuid not null references public.fd_desk_priorities(id), active boolean not null default true,
 unique(application_id,category_id)
);
create table if not exists public.fd_desk_groups (
 id uuid primary key default gen_random_uuid(), application_id uuid not null references public.fd_applications(id),
 group_id uuid not null references public.fd_telegram_groups(id), active boolean not null default true,
 unique(application_id,group_id)
);
create table if not exists public.fd_knowledge_articles (
 id uuid primary key default gen_random_uuid(), application_id uuid not null references public.fd_applications(id),
 title text not null check(length(title) between 1 and 160), keywords text not null default '',
 content_md text not null check(length(content_md) between 1 and 150000),
 status text not null default 'Draft' check(status in ('Draft','Published','Archived')),
 revision integer not null default 1, updated_at timestamptz not null default now(), published_by uuid references public.fd_profiles(id),
 unique(application_id,title)
);
create table if not exists public.fd_knowledge_chunks (
 id uuid primary key default gen_random_uuid(), article_id uuid not null references public.fd_knowledge_articles(id) on delete cascade,
 heading text not null, content text not null, position integer not null,
 search_vector tsvector not null, unique(article_id,position)
);
create index if not exists fd_knowledge_search on public.fd_knowledge_chunks using gin(search_vector);
create table if not exists public.fd_support_requests (
 id uuid primary key default gen_random_uuid(), number bigint generated always as identity unique,
 application_id uuid not null references public.fd_applications(id), group_id uuid not null references public.fd_telegram_groups(id),
 chat_id bigint not null, message_id bigint not null, reporter_telegram_id bigint not null,
 reporter_name text not null, reporter_user_id uuid references public.fd_profiles(id),
 question text not null check(length(question) between 3 and 3000), source_update_id bigint not null unique,
 status text not null default 'Asked' check(status in ('Asked','Answered','Clarification','Escalated','Resolved')),
 category_id uuid references public.fd_desk_categories(id), priority_name text, response_due_at timestamptz, resolution_due_at timestamptz,
 task_id uuid references public.fd_tasks(id) on delete restrict, answer_snapshot text, source_title text, source_revision integer,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.fd_support_notes (
 id uuid primary key default gen_random_uuid(), request_id uuid not null references public.fd_support_requests(id),
 actor_telegram_id bigint, actor_user_id uuid references public.fd_profiles(id),
 kind text not null, content text not null check(length(content)<=4000), created_at timestamptz not null default now()
);
create table if not exists public.fd_desk_updates (update_id bigint primary key,created_at timestamptz not null default now());
create table if not exists public.fd_desk_outbox (
 id uuid primary key default gen_random_uuid(), request_id uuid references public.fd_support_requests(id),
 group_id uuid not null references public.fd_telegram_groups(id),chat_id bigint not null, reply_to bigint,
 text text not null check(length(text)<=4000), markup jsonb, dedupe_key text not null unique,
 status text not null default 'pending' check(status in ('pending','sending','sent','failed','uncertain','skipped')),
 attempts integer not null default 0, next_attempt_at timestamptz not null default now(),
 sent_message_id bigint, last_error text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists fd_desk_outbox_queue on public.fd_desk_outbox(status,next_attempt_at);

-- Append-only original reports and audit notes, even through elevated application APIs.
create or replace function public.fd_support_immutable() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' then raise exception 'Laporan dan riwayat tidak dapat dihapus';end if;
 if tg_table_name='fd_support_notes' then raise exception 'Catatan bersifat append-only';end if;
 if (to_jsonb(new)-array['status','category_id','priority_name','response_due_at','resolution_due_at','task_id','answer_snapshot','source_title','source_revision','updated_at']) is distinct from
    (to_jsonb(old)-array['status','category_id','priority_name','response_due_at','resolution_due_at','task_id','answer_snapshot','source_title','source_revision','updated_at']) then raise exception 'Laporan asli terkunci. Tambahkan koreksi sebagai catatan.';end if;
 new.updated_at:=now();return new;
end $$;
drop trigger if exists fd_support_locked on public.fd_support_requests;
create trigger fd_support_locked before update or delete on public.fd_support_requests for each row execute function public.fd_support_immutable();
drop trigger if exists fd_support_notes_locked on public.fd_support_notes;
create trigger fd_support_notes_locked before update or delete on public.fd_support_notes for each row execute function public.fd_support_immutable();

create or replace function public.fd_desk_can_read(p_request uuid) returns boolean language sql stable security definer set search_path='' as $$
 select public.fd_is_active() and exists(select 1 from public.fd_support_requests r join public.fd_applications a on a.id=r.application_id left join public.fd_tasks t on t.id=r.task_id
 where r.id=p_request and (a.owner_id=auth.uid() or r.reporter_user_id=auth.uid() or t.assignee_id=auth.uid()))
$$;
-- Only service role mutates conversations. Admin master writes use the validated RPC below.
do $$declare t text;begin
 foreach t in array array['fd_desk_priorities','fd_desk_categories','fd_applications','fd_desk_routes','fd_desk_groups','fd_knowledge_articles','fd_knowledge_chunks','fd_support_requests','fd_support_notes','fd_desk_updates','fd_desk_outbox'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 execute format('grant all on public.%I to service_role',t);
 end loop;
end $$;
grant usage,select on sequence public.fd_support_requests_number_seq to service_role;
grant select on public.fd_support_requests,public.fd_support_notes to authenticated;
drop policy if exists fd_support_read on public.fd_support_requests;
create policy fd_support_read on public.fd_support_requests for select to authenticated using(public.fd_desk_can_read(id));
drop policy if exists fd_support_note_read on public.fd_support_notes;
create policy fd_support_note_read on public.fd_support_notes for select to authenticated using(public.fd_desk_can_read(request_id));

create or replace function public.fd_desk_admin(p_kind text,p_data jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); i uuid:=coalesce(nullif(p_data->>'id','')::uuid,gen_random_uuid()); a public.fd_applications; owner uuid; x uuid; rec record; rev integer;
begin
 if not public.fd_is_admin() then raise exception 'Admin aktif diperlukan' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('desk-master:'||u::text,0));
 if p_kind='list' then return jsonb_build_object(
 'applications',(select coalesce(jsonb_agg(t),'[]') from public.fd_applications t where owner_id=u),
 'categories',(select coalesce(jsonb_agg(t),'[]') from public.fd_desk_categories t where owner_id=u),
 'priorities',(select coalesce(jsonb_agg(t order by sort_order),'[]') from public.fd_desk_priorities t where owner_id=u),
 'routes',(select coalesce(jsonb_agg(t),'[]') from public.fd_desk_routes t join public.fd_applications ap on ap.id=t.application_id where ap.owner_id=u),
 'bindings',(select coalesce(jsonb_agg(t),'[]') from public.fd_desk_groups t join public.fd_applications ap on ap.id=t.application_id where ap.owner_id=u),
 'articles',(select coalesce(jsonb_agg(t),'[]') from public.fd_knowledge_articles t join public.fd_applications ap on ap.id=t.application_id where ap.owner_id=u),
 'pics',(select coalesce(jsonb_agg(t),'[]') from public.fd_pics t where owner_id=u),
 'groups',(select coalesce(jsonb_agg(t),'[]') from public.fd_telegram_groups t where owner_id=u));end if;
 if p_kind='seed' then
 insert into public.fd_desk_priorities(owner_id,name,task_priority,sort_order,response_hours,resolution_hours) values(u,'Low','Low',3,24,120),(u,'Medium','Medium',2,8,48),(u,'High','High',1,2,24),(u,'Critical','High',0,1,4) on conflict do nothing;
 insert into public.fd_desk_categories(owner_id,name) values(u,'Pertanyaan'),(u,'Bug'),(u,'Permintaan Akses'),(u,'Enhancement'),(u,'Data Issue') on conflict do nothing;
 return jsonb_build_object('ok',true);end if;
 if p_kind in ('application','category','priority') then
 if p_kind='application' then select owner_id into owner from public.fd_applications where id=i;
 elsif p_kind='category' then select owner_id into owner from public.fd_desk_categories where id=i;
 else select owner_id into owner from public.fd_desk_priorities where id=i;end if;
 if owner is not null and owner<>u then raise exception 'Master di luar workspace' using errcode='42501';end if;
 else
 select * into a from public.fd_applications where id=(p_data->>'application_id')::uuid and owner_id=u;
 if not found then raise exception 'Aplikasi di luar workspace' using errcode='42501';end if;
 if p_kind='article' and exists(select 1 from public.fd_knowledge_articles where id=i and application_id<>a.id) or
 p_kind='route' and exists(select 1 from public.fd_desk_routes where id=i and application_id<>a.id) or
 p_kind='binding' and exists(select 1 from public.fd_desk_groups where id=i and application_id<>a.id) then raise exception 'Relasi master tidak dapat dipindah';end if;
 end if;
 if p_kind in ('application','route') then
 if not exists(select 1 from public.fd_desk_priorities where id=(p_data->>'priority_id')::uuid and owner_id=u) then raise exception 'Priority tidak valid';end if;
 foreach x in array array[nullif(p_data->>'default_pic_id','')::uuid,nullif(p_data->>'backup_pic_id','')::uuid,nullif(p_data->>'pic_id','')::uuid] loop
 if x is not null and not exists(select 1 from public.fd_pics p join public.fd_profiles pr on pr.id=p.linked_user_id and pr.is_active where p.id=x and p.owner_id=u and p.is_active) then raise exception 'PIC harus kontak milik Anda dengan akun aktif terhubung';end if;
 end loop;end if;
 if p_kind='application' then
 insert into public.fd_applications(id,owner_id,code,name,description,work_area,default_pic_id,backup_pic_id,priority_id,requires_testing,active)
 values(i,u,p_data->>'code',p_data->>'name',coalesce(p_data->>'description',''),p_data->>'work_area',nullif(p_data->>'default_pic_id','')::uuid,nullif(p_data->>'backup_pic_id','')::uuid,(p_data->>'priority_id')::uuid,(p_data->>'requires_testing')::boolean,(p_data->>'active')::boolean)
 on conflict(id) do update set code=excluded.code,name=excluded.name,description=excluded.description,work_area=excluded.work_area,default_pic_id=excluded.default_pic_id,backup_pic_id=excluded.backup_pic_id,priority_id=excluded.priority_id,requires_testing=excluded.requires_testing,active=excluded.active;
 elsif p_kind='priority' then
 insert into public.fd_desk_priorities(id,owner_id,name,task_priority,sort_order,response_hours,resolution_hours,active) values(i,u,p_data->>'name',p_data->>'task_priority',(p_data->>'sort_order')::integer,(p_data->>'response_hours')::integer,(p_data->>'resolution_hours')::integer,(p_data->>'active')::boolean)
 on conflict(id) do update set name=excluded.name,task_priority=excluded.task_priority,sort_order=excluded.sort_order,response_hours=excluded.response_hours,resolution_hours=excluded.resolution_hours,active=excluded.active;
 elsif p_kind='category' then
 insert into public.fd_desk_categories(id,owner_id,name,description,active) values(i,u,p_data->>'name',coalesce(p_data->>'description',''),(p_data->>'active')::boolean)
 on conflict(id) do update set name=excluded.name,description=excluded.description,active=excluded.active;
 elsif p_kind='route' then
 if (select count(*) from public.fd_desk_routes where application_id=a.id and active and id<>i)>=20 and (p_data->>'active')::boolean then raise exception 'Maksimal 20 kategori aktif per aplikasi';end if;
 if not exists(select 1 from public.fd_desk_categories where id=(p_data->>'category_id')::uuid and owner_id=u) then raise exception 'Kategori tidak valid';end if;
 insert into public.fd_desk_routes(id,application_id,category_id,pic_id,priority_id,active) values(i,a.id,(p_data->>'category_id')::uuid,nullif(p_data->>'pic_id','')::uuid,(p_data->>'priority_id')::uuid,(p_data->>'active')::boolean)
 on conflict(id) do update set category_id=excluded.category_id,pic_id=excluded.pic_id,priority_id=excluded.priority_id,active=excluded.active;
 elsif p_kind='binding' then
 if not exists(select 1 from public.fd_telegram_groups where id=(p_data->>'group_id')::uuid and owner_id=u) then raise exception 'Grup di luar workspace';end if;
 insert into public.fd_desk_groups(id,application_id,group_id,active) values(i,a.id,(p_data->>'group_id')::uuid,(p_data->>'active')::boolean)
 on conflict(id) do update set group_id=excluded.group_id,active=excluded.active;
 elsif p_kind='article' then
 if jsonb_array_length(p_data->'chunks') not between 1 and 200 then raise exception 'Dokumen harus memiliki 1–200 bagian';end if;
 insert into public.fd_knowledge_articles(id,application_id,title,keywords,content_md,status,published_by) values(i,a.id,p_data->>'title',coalesce(p_data->>'keywords',''),p_data->>'content_md',p_data->>'status',case when p_data->>'status'='Published' then u end)
 on conflict(id) do update set title=excluded.title,keywords=excluded.keywords,content_md=excluded.content_md,status=excluded.status,revision=fd_knowledge_articles.revision+1,updated_at=now(),published_by=excluded.published_by returning revision into rev;
 delete from public.fd_knowledge_chunks where article_id=i;
 for rec in select * from jsonb_to_recordset(p_data->'chunks') as t(heading text,content text,position integer) loop
 if length(rec.content)>2500 or length(rec.heading)>160 then raise exception 'Bagian dokumen terlalu panjang';end if;
 insert into public.fd_knowledge_chunks(article_id,heading,content,position,search_vector) values(i,rec.heading,rec.content,rec.position,to_tsvector('simple',coalesce(p_data->>'title','')||' '||coalesce(p_data->>'keywords','')||' '||rec.heading||' '||rec.content));end loop;
 else raise exception 'Operasi master tidak dikenal';end if;
 insert into public.fd_audit(actor_id,action,details) values(u,'desk_master_'||p_kind,jsonb_build_object('id',i));
 return jsonb_build_object('id',i,'revision',rev);
end $$;

-- Service-role only; group/application visibility is rechecked on every action.
create or replace function public.fd_desk_context(p_chat bigint) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('group_id',g.id,'owner_id',g.owner_id,'applications',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'code',a.code,'name',a.name)),'[]') from public.fd_desk_groups b join public.fd_applications a on a.id=b.application_id and a.active where b.group_id=g.id and b.active))
 from public.fd_telegram_groups g join public.fd_profiles p on p.id=g.owner_id and p.is_active where g.chat_id=p_chat and g.active
$$;
create or replace function public.fd_desk_search(p_application uuid,p_chat bigint,p_terms text[]) returns jsonb language sql stable security definer set search_path='' as $$
 with terms as (select distinct x from unnest(p_terms) x where length(x) between 2 and 40 limit 12), matches as (
 select c.id,c.heading,c.content,k.title,k.revision,
 (select count(*) from terms where c.search_vector @@ plainto_tsquery('simple',x)) hits,
 (select count(*) from terms where to_tsvector('simple',c.heading||' '||c.content) @@ plainto_tsquery('simple',x)) section_hits
 from public.fd_knowledge_chunks c join public.fd_knowledge_articles k on k.id=c.article_id and k.status='Published'
 join public.fd_applications a on a.id=k.application_id and a.active
 join public.fd_profiles p on p.id=a.owner_id and p.is_active
 where a.id=p_application and exists(select 1 from public.fd_desk_groups b join public.fd_telegram_groups g on g.id=b.group_id and g.active where b.application_id=a.id and b.active and g.chat_id=p_chat and g.owner_id=a.owner_id)
 ), ranked as (select * from matches where section_hits>0 and hits>=greatest(1,least(2,(select count(*) from terms))) order by section_hits desc,hits desc,id limit 3)
 select coalesce(jsonb_agg(ranked),'[]'::jsonb) from ranked
$$;
create or replace function public.fd_desk_enqueue(p_request uuid,p_group uuid,p_chat bigint,p_reply bigint,p_text text,p_markup jsonb,p_key text) returns void language sql security definer set search_path='' as $$
 insert into public.fd_desk_outbox(request_id,group_id,chat_id,reply_to,text,markup,dedupe_key) values(p_request,p_group,p_chat,p_reply,p_text,p_markup,p_key) on conflict(dedupe_key) do nothing
$$;
create or replace function public.fd_desk_ask(p_update bigint,p_chat bigint,p_message bigint,p_telegram bigint,p_name text,p_application uuid,p_question text,p_terms text[]) returns uuid language plpgsql security definer set search_path='' as $$
declare g public.fd_telegram_groups;a public.fd_applications;r public.fd_support_requests;found_answers jsonb;chosen jsonb; txt text; existing uuid;begin
 select id into existing from public.fd_support_requests where source_update_id=p_update;if found then return existing;end if;
 select * into g from public.fd_telegram_groups where chat_id=p_chat and active;
 select * into a from public.fd_applications where id=p_application and active and owner_id=g.owner_id;
 if a.id is null or not exists(select 1 from public.fd_profiles where id=a.owner_id and is_active) or not exists(select 1 from public.fd_desk_groups where group_id=g.id and application_id=a.id and active) then raise exception 'Aplikasi tidak diizinkan dalam grup ini';end if;
 perform pg_advisory_xact_lock(hashtextextended('desk-ask:'||p_telegram,0));
 select id into existing from public.fd_support_requests where source_update_id=p_update;if found then return existing;end if;
 if (select count(*) from public.fd_support_requests where reporter_telegram_id=p_telegram and created_at>now()-interval '1 minute')>=5 then raise exception 'Maksimal 5 pertanyaan per menit. Coba kembali sebentar.';end if;
 insert into public.fd_support_requests(application_id,group_id,chat_id,message_id,reporter_telegram_id,reporter_name,reporter_user_id,question,source_update_id)
 values(a.id,g.id,p_chat,p_message,p_telegram,left(p_name,100),(select user_id from public.fd_telegram_accounts where telegram_id=p_telegram),p_question,p_update) returning * into r;
 found_answers:=public.fd_desk_search(a.id,p_chat,p_terms);chosen:=found_answers->0;
 if chosen is not null then
 txt:='Panduan terkait — '||a.name||E'\n\n'||(chosen->>'content')||E'\n\nSumber: '||(chosen->>'title')||' · '||(chosen->>'heading')||' · revisi '||(chosen->>'revision')||E'\n\nApakah panduan ini membantu?';
 update public.fd_support_requests set status='Answered',answer_snapshot=chosen->>'content',source_title=chosen->>'title',source_revision=(chosen->>'revision')::integer where id=r.id;
 insert into public.fd_support_notes(request_id,kind,content) values(r.id,'knowledge_answer',(chosen->>'title')||' · revisi '||(chosen->>'revision')||E'\n'||(chosen->>'content'));
 else txt:='Belum ada panduan Published yang cukup cocok untuk pertanyaan ini. Tambahkan detail melalui reply pesan bot, atau pilih Buat laporan untuk diteruskan ke PIC.';end if;
 perform public.fd_desk_enqueue(r.id,g.id,p_chat,p_message,'FD-'||r.number||' · '||a.name||E'\n'||txt,
 jsonb_build_object('inline_keyboard',jsonb_build_array(jsonb_build_array(jsonb_build_object('text','Terbantu','callback_data','k:'||r.id||':ok')),jsonb_build_array(jsonb_build_object('text','Belum membantu / tambah detail','callback_data','k:'||r.id||':more')),jsonb_build_array(jsonb_build_object('text','Buat laporan','callback_data','k:'||r.id||':escalate')))),'ask:'||p_update);
 return r.id;end $$;

create or replace function public.fd_desk_action(p_update bigint,p_chat bigint,p_message bigint,p_telegram bigint,p_request uuid,p_action text,p_value text default null,p_terms text[] default '{}'::text[]) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.fd_support_requests;a public.fd_applications;route public.fd_desk_routes;prio public.fd_desk_priorities;pic uuid;rows jsonb;txt text;t public.fd_tasks;actor uuid;n integer;category_name text; answer jsonb; prior text:=current_setting('request.jwt.claim.sub',true);
begin
 select * into r from public.fd_support_requests where id=p_request for update;
 if r.id is null or r.chat_id<>p_chat or r.reporter_telegram_id<>p_telegram then raise exception 'Tindakan hanya untuk pelapor di percakapan asal';end if;
 if not exists(select 1 from public.fd_desk_outbox where request_id=r.id and chat_id=p_chat and sent_message_id=p_message and status='sent') then raise exception 'Pesan tidak terhubung ke laporan';end if;
 select * into a from public.fd_applications where id=r.application_id and active;
 if a.id is null or not exists(select 1 from public.fd_profiles where id=a.owner_id and is_active) or not exists(select 1 from public.fd_desk_groups b join public.fd_telegram_groups g on g.id=b.group_id where b.application_id=a.id and b.group_id=r.group_id and b.active and g.active) then raise exception 'Aplikasi atau grup tidak aktif';end if;
 insert into public.fd_desk_updates(update_id) values(p_update) on conflict do nothing;get diagnostics n=row_count;if n=0 then return jsonb_build_object('duplicate',true);end if;
 actor:=(select user_id from public.fd_telegram_accounts where telegram_id=p_telegram);
 if p_action='note' then
 if length(trim(coalesce(p_value,''))) not between 3 and 3000 then raise exception 'Isi catatan 3–3000 karakter';end if;
 insert into public.fd_support_notes(request_id,actor_telegram_id,actor_user_id,kind,content) values(r.id,p_telegram,actor,'reporter_correction',p_value);
 txt:='Informasi tambahan tersimpan. Laporan asli tetap utuh.';
 if r.task_id is not null then
 select * into t from public.fd_tasks where id=r.task_id;
 insert into public.fd_telegram_outbox(owner_id,target_user_id,task_id,kind,dedupe_key) values(a.owner_id,coalesce(t.assignee_id,a.owner_id),t.id,'task','support-note:'||p_update) on conflict(dedupe_key) do nothing;
 end if;
 if r.task_id is null then
 -- A follow-up can retrieve a better section, without changing the original question.
 update public.fd_support_requests set status='Clarification' where id=r.id;
 answer:=public.fd_desk_search(a.id,p_chat,p_terms)->0;
 if answer is not null then
 update public.fd_support_requests set status='Answered',answer_snapshot=answer->>'content',source_title=answer->>'title',source_revision=(answer->>'revision')::integer where id=r.id;
 insert into public.fd_support_notes(request_id,kind,content) values(r.id,'knowledge_answer',(answer->>'title')||' · revisi '||(answer->>'revision')||E'\n'||(answer->>'content'));
 txt:='Panduan berdasarkan tambahan informasi:'||E'\n\n'||(answer->>'content')||E'\n\nSumber: '||(answer->>'title')||' · '||(answer->>'heading')||' · revisi '||(answer->>'revision');
 else txt:=txt||E'\nBelum ditemukan panduan tambahan. Pilih Buat laporan untuk bantuan PIC.';end if;
 rows:=jsonb_build_array(jsonb_build_array(jsonb_build_object('text','Buat laporan','callback_data','k:'||r.id||':escalate')));
 end if;
 elsif p_action='more' then txt:='Reply pesan ini dengan rincian kendala, langkah yang dicoba, dan dampaknya. Koreksi dicatat terpisah dari laporan asli.';
 elsif p_action='ok' then
 if r.task_id is not null then txt:='Feedback diterima. Penutupan task tetap mengikuti PIC dan reviewer.';
 else update public.fd_support_requests set status='Resolved' where id=r.id;txt:='Terima kasih. Pertanyaan ditandai selesai.';end if;
 insert into public.fd_support_notes(request_id,actor_telegram_id,actor_user_id,kind,content) values(r.id,p_telegram,actor,'feedback','Panduan membantu');
 elsif p_action='escalate' then
 if r.task_id is not null then txt:='Laporan sudah terhubung ke task. Gunakan tombol Status.';
 else
 select jsonb_agg(jsonb_build_array(jsonb_build_object('text',c.name,'callback_data','k:'||r.id||':c'||left(rt.id::text,8)))) into rows from public.fd_desk_routes rt join public.fd_desk_categories c on c.id=rt.category_id and c.active join public.fd_desk_priorities p on p.id=rt.priority_id and p.active where rt.application_id=a.id and rt.active;
 txt:=case when rows is null then 'Kategori belum dikonfigurasi. Hubungi admin aplikasi.' else 'Pilih kategori laporan:' end;
 end if;
 elsif left(p_action,1)='c' and length(p_action)=9 then
 if r.task_id is not null then raise exception 'Task sudah dibuat';end if;
 if (select count(*) from public.fd_desk_routes where application_id=a.id and active and left(id::text,8)=substring(p_action,2))<>1 then raise exception 'Pilihan kategori berubah. Pilih ulang.';end if;
 select * into route from public.fd_desk_routes where left(id::text,8)=substring(p_action,2) and application_id=a.id and active;
 select name into category_name from public.fd_desk_categories where id=route.category_id and active;
 select * into prio from public.fd_desk_priorities where id=route.priority_id and active;
 if route.id is null or category_name is null or prio.id is null then raise exception 'Kategori tidak tersedia';end if;
 update public.fd_support_requests set category_id=route.category_id where id=r.id;
 select p.id into pic from unnest(array[coalesce(route.pic_id,a.default_pic_id),a.backup_pic_id]) with ordinality candidate(id,ord) join public.fd_pics p on p.id=candidate.id and p.owner_id=a.owner_id and p.is_active where public.fd_tg_pic_matches(p.id,p.linked_user_id) order by candidate.ord limit 1;
 txt:='Konfirmasi laporan FD-'||r.number||E'\nAplikasi: '||a.name||E'\nKategori: '||category_name||E'\nPriority: '||prio.name||E'\nPIC: '||coalesce((select name from public.fd_pics where id=pic),'Application owner — triage')||E'\nReviewer: '||coalesce((select nullif(display_name,'') from public.fd_profiles where id=a.owner_id),'Application owner')||E'\n\n'||left(r.question,1500)||E'\n\nPIC dipilih dari aturan aktif saat dikirim. Laporan asli tidak dapat diedit setelah dikirim.';
 rows:=jsonb_build_array(jsonb_build_array(jsonb_build_object('text','Kirim laporan','callback_data','k:'||r.id||':confirm')),jsonb_build_array(jsonb_build_object('text','Batal','callback_data','k:'||r.id||':cancel')));
 elsif p_action='cancel' then update public.fd_support_requests set category_id=null where id=r.id and task_id is null;txt:='Pembuatan task dibatalkan. Anda tetap dapat menambahkan informasi.';
 elsif p_action='confirm' then
 if r.task_id is not null then txt:='Task sudah dibuat sebelumnya. Tidak ada task duplikat.';
 else
 select * into route from public.fd_desk_routes where application_id=a.id and category_id=r.category_id and active;
 select * into prio from public.fd_desk_priorities where id=route.priority_id and active;
 if route.id is null or prio.id is null or not exists(select 1 from public.fd_desk_categories where id=route.category_id and active) then raise exception 'Pilih kategori aktif terlebih dahulu';end if;
 -- Select only active, paired PICs belonging to the reviewer workspace; fallback to owner triage.
 select p.id into pic from unnest(array[coalesce(route.pic_id,a.default_pic_id),a.backup_pic_id]) with ordinality as candidate(id,ord)
 join public.fd_pics p on p.id=candidate.id and p.owner_id=a.owner_id and p.is_active
 where public.fd_tg_pic_matches(p.id,p.linked_user_id) order by candidate.ord limit 1;
 perform set_config('request.jwt.claim.sub',a.owner_id::text,true);
 insert into public.fd_tasks(user_id,title,category,project,priority,kind,pic_id,scheduled_date,due_date,notes,telegram_group_id,requires_testing,acceptance_criteria)
 values(a.owner_id,left('[FD-'||r.number||'] '||r.question,180),a.work_area,a.name,prio.task_priority,'Delivery',pic,(now() at time zone 'Asia/Jakarta')::date,((now()+make_interval(hours=>prio.resolution_hours)) at time zone 'Asia/Jakarta')::date,
 'Laporan FD-'||r.number||E'\n'||r.question||E'\nLihat Knowledge Desk untuk riwayat dan tambahan informasi.',r.group_id,a.requires_testing,'Verifikasi penyelesaian laporan FD-'||r.number||' dan catat hasil pengujian.') returning * into t;
 perform set_config('request.jwt.claim.sub',coalesce(prior,''),true);
 update public.fd_support_requests set task_id=t.id,status='Escalated',priority_name=prio.name,response_due_at=now()+make_interval(hours=>prio.response_hours),resolution_due_at=now()+make_interval(hours=>prio.resolution_hours) where id=r.id;
 insert into public.fd_support_notes(request_id,actor_telegram_id,actor_user_id,kind,content) values(r.id,p_telegram,actor,'escalated','Task dibuat melalui bot; priority '||prio.name);
 txt:='Task berhasil dibuat. PIC: '||coalesce(t.pic_name,'Application owner — perlu triage')||E'\nStatus: '||t.status||E'\nPriority: '||prio.name;
 end if;
 elsif p_action='status' then
 select * into t from public.fd_tasks where id=r.task_id;
 txt:='Status laporan: '||r.status||case when t.id is not null then E'\nStatus task: '||t.status||E'\nPIC: '||coalesce(t.pic_name,t.owner_name,'Application owner') else '' end;
 else raise exception 'Tindakan tidak dikenal';end if;
 if rows is null then rows:=jsonb_build_array(jsonb_build_array(jsonb_build_object('text','Status','callback_data','k:'||r.id||':status')),jsonb_build_array(jsonb_build_object('text','Tambah informasi','callback_data','k:'||r.id||':more')));end if;
 perform public.fd_desk_enqueue(r.id,r.group_id,p_chat,r.message_id,'FD-'||r.number||E'\n'||txt,case when p_action='more' then jsonb_build_object('force_reply',true,'selective',true) else jsonb_build_object('inline_keyboard',rows) end,'action:'||p_update);
 return jsonb_build_object('ok',true,'owner_id',a.owner_id);
end $$;

create or replace function public.fd_desk_task_event() returns trigger language plpgsql security definer set search_path='' as $$
declare r public.fd_support_requests;begin
 if new.status is not distinct from old.status then return new;end if;
 for r in select * from public.fd_support_requests where task_id=new.id loop
 update public.fd_support_requests set status=case when new.status='Done' then 'Resolved' else 'Escalated' end where id=r.id;
 insert into public.fd_support_notes(request_id,actor_user_id,kind,content) values(r.id,auth.uid(),'task_status',old.status||' → '||new.status);
 perform public.fd_desk_enqueue(r.id,r.group_id,r.chat_id,r.message_id,'FD-'||r.number||E'\nStatus pengerjaan: '||new.status||E'\nPIC: '||coalesce(new.pic_name,new.owner_name,'Application owner')||E'\nCatatan tambahan dapat dikirim dengan reply ke pesan bot.',jsonb_build_object('inline_keyboard',jsonb_build_array(jsonb_build_array(jsonb_build_object('text','Status','callback_data','k:'||r.id||':status')))),'status:'||r.id||':'||new.version);
 end loop;return new;end $$;
drop trigger if exists fd_desk_task_change on public.fd_tasks;
create trigger fd_desk_task_change after update on public.fd_tasks for each row execute function public.fd_desk_task_event();
create or replace function public.fd_desk_claim(p_limit integer default 8) returns setof public.fd_desk_outbox language plpgsql security definer set search_path='' as $$
begin
 update public.fd_desk_outbox set status='uncertain',last_error='Delivery interrupted; use status button',updated_at=now() where status='sending' and updated_at<now()-interval '5 minutes';
 return query with ready as (select id from public.fd_desk_outbox where status in ('pending','failed') and attempts<5 and next_attempt_at<=now() order by created_at for update skip locked limit least(greatest(p_limit,1),20))
 update public.fd_desk_outbox o set status='sending',attempts=o.attempts+1,updated_at=now() from ready where o.id=ready.id returning o.*;
end $$;
revoke all on function public.fd_desk_admin(text,jsonb) from public,anon,authenticated;
grant execute on function public.fd_desk_admin(text,jsonb) to authenticated;
revoke all on function public.fd_desk_can_read(uuid) from public,anon;
grant execute on function public.fd_desk_can_read(uuid) to authenticated;
do $$declare f record;begin
 for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('fd_desk_context','fd_desk_search','fd_desk_enqueue','fd_desk_ask','fd_desk_action','fd_desk_claim') loop
 execute 'revoke all on function '||f.sig||' from public,anon,authenticated';execute 'grant execute on function '||f.sig||' to service_role';end loop;
end $$;
notify pgrst,'reload schema';

commit;
