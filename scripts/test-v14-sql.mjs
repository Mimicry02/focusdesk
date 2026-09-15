import {readFile} from 'node:fs/promises';import assert from 'node:assert/strict';
const {PGlite}=await import(process.env.PGLITE_MODULE||'@electric-sql/pglite');const db=new PGlite();
await db.exec(`create schema auth;create role anon;create role authenticated;create role service_role bypassrls;create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb not null default '{}'::jsonb);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated,anon,service_role;`);
for(const f of ['01_schema.sql','03_pic_reports.sql','04_recurring_tasks.sql','05_telegram_workflow.sql'])await db.exec(await readFile('supabase/'+f,'utf8'));
const A='11111111-1111-4111-8111-111111111111',B='22222222-2222-4222-8222-222222222222',C='33333333-3333-4333-8333-333333333333';
await db.query(`insert into auth.users(id,email) values($1,'owner@example.com'),($2,'dev@example.com'),($3,'other@example.com')`,[A,B,C]);await db.exec('update fd_profiles set is_active=true');
async function user(id,fn){await db.exec('set role authenticated');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);try{return await fn()}finally{await db.exec("reset role;select set_config('request.jwt.claim.sub','',false)")}}
async function service(fn){await db.exec('set role service_role');try{return await fn()}finally{await db.exec('reset role')}}
await db.query('insert into fd_telegram_accounts(user_id,telegram_id,chat_id) values($1,101,101),($2,202,202),($3,303,303)',[A,B,C]);
const pic=(await user(A,()=>db.query(`select (fd_save_pic(gen_random_uuid(),'Dev','dev@example.com',true,true)).id id`))).rows[0].id;
let task=(await user(A,()=>db.query(`insert into fd_tasks(user_id,title,category,pic_id,requires_testing) values($1,'GEE Platform','Full Time',$2,true) returning *`,[A,pic]))).rows[0];
const before=JSON.stringify(task),migration=await readFile('supabase/07_telegram_sync_pic.sql','utf8');
await db.exec(migration);await db.exec(migration);
assert.equal(JSON.stringify((await db.query('select * from fd_tasks where id=$1',[task.id])).rows[0]),before);
assert.equal((await db.query('select count(*)::int n from fd_telegram_accounts')).rows[0].n,3);
await user(A,()=>db.query(`select fd_save_pic_v14($1,'Dev','dev@example.com',true,true,1,'programmer_gee')`,[pic]));
assert.equal((await user(A,()=>db.query('select * from fd_pic_telegram_status()'))).rows[0].telegram_status,'username_mismatch');
assert.equal((await user(C,()=>db.query('select * from fd_pic_telegram_status()'))).rows.length,0);
await user(B,()=>assert.rejects(()=>db.query('select fd_tg_pic_matches($1,$2)',[pic,B]),/permission denied/));
let sequence=100;
async function call(tg,status,note=null,chat=tg,version=task.version,update=++sequence){
 await db.query('insert into fd_telegram_messages(chat_id,message_id,task_id,task_version,target_user_id) values($1,$2,$3,$4,$5) on conflict do nothing',[chat,update,task.id,version,tg===101?A:tg===202?B:C]);
 return service(()=>db.query('select fd_tg_action($1,$2,$3,$1,$4,$5,$6,$7) result',[update,tg,chat,task.id,version,status,note]));
}
async function refresh(){task=(await db.query('select * from fd_tasks where id=$1',[task.id])).rows[0];}
await assert.rejects(()=>call(202,'In progress'),/Username/);
await db.exec("update fd_telegram_accounts set telegram_username='programmer_gee' where telegram_id=202");
assert.equal((await user(A,()=>db.query('select * from fd_pic_telegram_status()'))).rows[0].telegram_status,'verified');
await assert.rejects(()=>call(101,'In progress'),/peran/);
await assert.rejects(()=>call(303,'In progress'),/bukan/);
await assert.rejects(()=>call(202,'In progress',null,-900),/chat pribadi/);
const start=await call(202,'In progress');assert.equal(start.rows[0].result.status,'In progress');
await refresh();assert.equal(task.status,'In progress');
// Same row is read by the web owner's RLS session immediately after Telegram commit.
assert.equal((await user(A,()=>db.query('select status,version from fd_tasks where id=$1',[task.id]))).rows[0].version,task.version);
await assert.rejects(()=>call(202,'Done'),/peran/);
await call(202,'Ready for Testing');await refresh();assert.equal(task.test_cycle,1);
await assert.rejects(()=>call(202,'Testing'),/peran/);
await call(101,'Testing');await refresh();
await assert.rejects(()=>call(101,'Rework'),/alasan/);
await call(101,'Rework','Empty search crashes');await refresh();
await call(202,'In progress');await refresh();await call(202,'Ready for Testing');await refresh();
await call(101,'Testing');await refresh();assert.equal(task.test_cycle,2);
const ver=task.version,update=++sequence;await call(101,'Done',null,101,ver,update);await refresh();assert.ok(task.completed_at);
assert.equal((await call(101,'Done',null,101,ver,update)).rows[0].result.duplicate,true);
await assert.rejects(()=>call(101,'Done',null,101,ver),/Pesan sudah lama/);
await db.exec("update fd_telegram_accounts set telegram_username='different_handle' where telegram_id=202");
await assert.rejects(()=>call(202,'Done','Spoof progress'),/Username/);
await db.query('update fd_profiles set is_active=false where id=$1',[B]);
await assert.rejects(()=>call(202,'Done'),/chat pribadi/);
console.log('PASS v1.4 SQL: additive/replayed migration preserves tasks/pairing, scoped PIC username verification, DM-only roles, stranger/username/stale/inactive rejection, Telegram → same web row, complete test/rework cycles, callback idempotency.');await db.close();
