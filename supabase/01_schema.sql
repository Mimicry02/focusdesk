-- Focusdesk v1.0 · Run in Supabase SQL Editor as project owner.
-- Namespaced tables: does not change unrelated application tables.
-- New accounts start INACTIVE; admin approval is required even if public signup is enabled.
begin;
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
commit;
