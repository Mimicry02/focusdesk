-- Focusdesk v1.1 migration. Existing v1 users: run ONLY this file after backup.
-- Fresh installation: run 01_schema.sql, this file, then 02_bootstrap_admin.sql.
begin;
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
commit;
