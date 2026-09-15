-- Focusdesk v1.4: apply AFTER 05. No task deletion, status reset, or pairing reset.
begin;
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
commit;
