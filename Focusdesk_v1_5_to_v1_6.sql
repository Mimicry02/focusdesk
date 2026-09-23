-- Focusdesk 1.6.0 — additive migration, run AFTER 08_scheduled_briefings.sql.
begin;
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
