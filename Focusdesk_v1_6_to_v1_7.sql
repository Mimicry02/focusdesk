-- Focusdesk 1.7.0: apply after 10_knowledge_desk.sql. Additive, replay-safe.
begin;
alter table public.fd_desk_outbox add column if not exists ai_state text not null default 'none'
 check(ai_state in ('none','pending','reserved','complete'));
alter table public.fd_desk_outbox add column if not exists ai_question text;
alter table public.fd_desk_outbox add column if not exists ai_sources jsonb not null default '[]';
alter table public.fd_desk_outbox add column if not exists ai_result jsonb;
create table if not exists public.fd_ai_daily_usage (
 owner_id uuid not null references public.fd_profiles(id), day date not null, requests integer not null default 0 check(requests>=0),
 primary key(owner_id,day)
);
alter table public.fd_ai_daily_usage enable row level security;
revoke all on public.fd_ai_daily_usage from public,anon,authenticated;
grant all on public.fd_ai_daily_usage to service_role;

create or replace function public.fd_desk_ai_prepare(p_key text,p_question text,p_terms text[]) returns void
 language plpgsql security definer set search_path='' as $$
declare o public.fd_desk_outbox;r public.fd_support_requests;begin
 select * into o from public.fd_desk_outbox where dedupe_key=p_key for update;
 if o.id is null or o.ai_state<>'none' then return;end if;
 select * into r from public.fd_support_requests where id=o.request_id;
 update public.fd_desk_outbox set ai_state='pending',ai_question=left(p_question,6000),
 ai_sources=public.fd_desk_search(r.application_id,o.chat_id,p_terms) where id=o.id;
end $$;

-- Revalidate publication, revision and group access before sending excerpts to OpenAI.
create or replace function public.fd_desk_ai_context(p_outbox uuid) returns jsonb
 language sql stable security definer set search_path='' as $$
 select jsonb_build_object('owner_id',a.owner_id,'number',r.number,'application',a.name,'question',o.ai_question,
 'sources',coalesce((select jsonb_agg(s.value order by s.ord) from jsonb_array_elements(o.ai_sources) with ordinality s(value,ord)
 join public.fd_knowledge_chunks c on c.id::text=s.value->>'id'
 join public.fd_knowledge_articles k on k.id=c.article_id and k.application_id=a.id and k.status='Published'
 where k.revision=(s.value->>'revision')::integer and c.content=s.value->>'content'), '[]'::jsonb))
 from public.fd_desk_outbox o join public.fd_support_requests r on r.id=o.request_id
 join public.fd_applications a on a.id=r.application_id and a.active
 join public.fd_profiles p on p.id=a.owner_id and p.is_active
 join public.fd_telegram_groups g on g.id=o.group_id and g.owner_id=a.owner_id and g.active and g.chat_id=o.chat_id
 join public.fd_desk_groups b on b.application_id=a.id and b.group_id=g.id and b.active
 where o.id=p_outbox
$$;

-- Atomic per-workspace daily cap (WIB). Failed OpenAI attempts count too.
create or replace function public.fd_desk_ai_reserve(p_outbox uuid,p_limit integer) returns boolean
 language plpgsql security definer set search_path='' as $$
declare o public.fd_desk_outbox;ctx jsonb;used integer;begin
 select * into o from public.fd_desk_outbox where id=p_outbox for update;
 if o.id is null or o.status<>'sending' or o.ai_state<>'pending' then return false;end if;
 ctx:=public.fd_desk_ai_context(o.id);
 if ctx is null or jsonb_array_length(ctx->'sources')=0 then return false;end if;
 insert into public.fd_ai_daily_usage(owner_id,day,requests) values((ctx->>'owner_id')::uuid,(now() at time zone 'Asia/Jakarta')::date,1)
 on conflict(owner_id,day) do update set requests=public.fd_ai_daily_usage.requests+1
 where public.fd_ai_daily_usage.requests<least(greatest(coalesce(p_limit,100),1),500) returning requests into used;
 if used is null then return false;end if;
 update public.fd_desk_outbox set ai_state='reserved' where id=o.id;
 return true;
end $$;

-- Persist the generated answer and audit entry BEFORE Telegram delivery.
-- This RPC cannot change tasks, PICs, or original report fields.
create or replace function public.fd_desk_ai_finish(p_outbox uuid,p_mode text,p_answer text,p_source_ids text[],p_model text,p_reason text) returns jsonb
 language plpgsql security definer set search_path='' as $$
declare o public.fd_desk_outbox;r public.fd_support_requests;ctx jsonb;sources jsonb;labels text;txt text;mode text:=p_mode;reason text:=p_reason;begin
 select * into o from public.fd_desk_outbox where id=p_outbox for update;
 if o.id is null or o.status<>'sending' then raise exception 'Outbox not claimed';end if;
 ctx:=public.fd_desk_ai_context(o.id);
 if ctx is null then
 update public.fd_desk_outbox set status='skipped',last_error='Access revoked' where id=o.id;
 return jsonb_build_object('skip',true);end if;
 sources:=ctx->'sources';
 if mode not in ('ai','fallback','unanswered') then raise exception 'Invalid answer mode';end if;
 if mode='ai' and (o.ai_state<>'reserved' or length(trim(coalesce(p_answer,''))) not between 1 and 1800 or
 coalesce(cardinality(p_source_ids),0) not between 1 and 3 or exists(select 1 from unnest(p_source_ids) x where not exists(select 1 from jsonb_array_elements(sources) s where s->>'id'=x))) then
 mode:='fallback';reason:='invalid_output';end if;
 if mode='ai' then
 select jsonb_agg(s) into sources from jsonb_array_elements(sources) s where s->>'id'=any(p_source_ids);
 select string_agg((s->>'title')||' · '||(s->>'heading')||' · revisi '||(s->>'revision'),E'\n') into labels from jsonb_array_elements(sources) s;
 txt:='Jawaban AI berdasarkan panduan:'||E'\n\n'||trim(p_answer)||E'\n\nSumber:\n'||labels;
 elsif mode='unanswered' or jsonb_array_length(sources)=0 then
 mode:='unanswered';
 txt:='Panduan yang tersedia belum cukup untuk menjawab pertanyaan ini. Tambahkan detail melalui reply, atau pilih Buat laporan untuk bantuan PIC.';
 else
 sources:=jsonb_build_array(sources->0);
 labels:=(sources->0->>'title')||' · '||(sources->0->>'heading')||' · revisi '||(sources->0->>'revision');
 txt:=case when reason='disabled' then 'Kutipan panduan (mode pencarian):' else 'Jawaban AI belum tersedia. Berikut kutipan panduan terkait:' end||E'\n\n'||(sources->0->>'content')||E'\n\nSumber: '||labels;
 end if;
 txt:='FD-'||(ctx->>'number')||' · '||(ctx->>'application')||E'\n'||txt;
 select * into r from public.fd_support_requests where id=o.request_id for update;
 if o.ai_state<>'complete' then
 insert into public.fd_support_notes(request_id,kind,content) values(o.request_id,'answer_'||mode,left(txt,4000));
 end if;
 update public.fd_desk_outbox set text=left(txt,4000),ai_state='complete',
 ai_result=jsonb_build_object('mode',mode,'reason',left(reason,40),'model',left(p_model,100),'sources',sources,'at',now()) where id=o.id;
 -- Do not move an already resolved/escalated report backwards during a concurrent action.
 if r.task_id is null and r.status in ('Asked','Answered','Clarification') then
 update public.fd_support_requests set status=case when mode='unanswered' then 'Clarification' else 'Answered' end,
 answer_snapshot=case when mode='unanswered' then null else left(txt,4000) end,
 source_title=case when mode='unanswered' then null else sources->0->>'title' end,
 source_revision=case when mode='unanswered' then null else (sources->0->>'revision')::integer end where id=r.id;
 end if;
 return jsonb_build_object('text',left(txt,4000),'mode',mode);
end $$;

create or replace function public.fd_desk_ai_health() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.fd_is_admin() then raise exception 'Admin aktif diperlukan' using errcode='42501';end if;
 return jsonb_build_object('today',coalesce((select requests from public.fd_ai_daily_usage where owner_id=auth.uid() and day=(now() at time zone 'Asia/Jakarta')::date),0),
 'recent',(select coalesce(jsonb_agg(x),'[]') from (select r.number,o.ai_state,o.ai_result->>'mode' as mode,o.ai_result->>'reason' as reason,o.status,o.created_at
 from public.fd_desk_outbox o join public.fd_support_requests r on r.id=o.request_id join public.fd_applications a on a.id=r.application_id
 where a.owner_id=auth.uid() and o.ai_state<>'none' order by o.created_at desc limit 10) x));
end $$;
revoke all on function public.fd_desk_ai_health() from public,anon,authenticated;
grant execute on function public.fd_desk_ai_health() to authenticated;
do $$declare f record;begin
 for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
 and p.proname in ('fd_desk_ai_prepare','fd_desk_ai_context','fd_desk_ai_reserve','fd_desk_ai_finish') loop
 execute 'revoke all on function '||f.sig||' from public,anon,authenticated';execute 'grant execute on function '||f.sig||' to service_role';end loop;
end $$;
-- ASK/ACTION overrides generated from v1.6.
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
 perform public.fd_desk_ai_prepare('ask:'||p_update,p_question,p_terms);
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
 if p_action='note' and r.task_id is null then
 perform public.fd_desk_ai_prepare('action:'||p_update,r.question||E'\nTambahan terbaru: '||p_value,p_terms);
 end if;
 return jsonb_build_object('ok',true,'owner_id',a.owner_id);
end $$;


notify pgrst,'reload schema';
commit;
