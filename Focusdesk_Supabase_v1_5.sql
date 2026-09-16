-- Focusdesk v1.5.0 FRESH INSTALL ONLY
-- Backup first. Run the ENTIRE file in Supabase SQL Editor.
begin;

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

commit;
