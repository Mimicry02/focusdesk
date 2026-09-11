import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const {PGlite}=await import(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const db=new PGlite();
await db.exec(`create schema auth;create role anon;create role authenticated;create role service_role bypassrls;
create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb not null default '{}'::jsonb);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema auth to authenticated,anon,service_role;grant execute on function auth.uid() to authenticated,anon,service_role;`);
const files=['01_schema.sql','03_pic_reports.sql','04_recurring_tasks.sql','05_telegram_workflow.sql'];
for(const f of files)await db.exec(await readFile('supabase/'+f,'utf8'));
const A='11111111-1111-4111-8111-111111111111',B='22222222-2222-4222-8222-222222222222',C='33333333-3333-4333-8333-333333333333';
await db.query(`insert into auth.users(id,email) values($1,'owner@example.com'),($2,'dev@example.com'),($3,'stranger@example.com')`,[A,B,C]);
await db.exec('update fd_profiles set is_active=true');
async function asUser(id,fn){await db.exec('set role authenticated');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);try{return await fn()}finally{await db.exec('reset role');await db.exec("select set_config('request.jwt.claim.sub','',false)")}}
async function asService(fn){await db.exec('set role service_role');try{return await fn()}finally{await db.exec('reset role')}}
let task,pic,group;
await asUser(A,async()=>{
 await db.query(`select fd_tg_new_code($1,'personal')`,['a'.repeat(64)]);
 await assert.rejects(()=>db.query(`select fd_tg_redeem($1,101,101,'personal','x')`,['a'.repeat(64)]),/permission denied/);
});
await asService(()=>db.query(`select fd_tg_redeem($1,101,101,'personal','x')`,['a'.repeat(64)]));
await assert.rejects(()=>asService(()=>db.query(`select fd_tg_redeem($1,101,101,'personal','x')`,['a'.repeat(64)])),/Kode/);
await asUser(B,()=>db.query(`select fd_tg_new_code($1,'personal')`,['b'.repeat(64)]));
await asService(()=>db.query(`select fd_tg_redeem($1,202,202,'personal','x')`,['b'.repeat(64)]));
await asUser(A,()=>db.query(`select fd_tg_new_code($1,'group')`,['c'.repeat(64)]));
await assert.rejects(()=>asService(()=>db.query(`select fd_tg_redeem($1,202,-900,'group','Team')`,['c'.repeat(64)])),/pemilik/);
await asService(()=>db.query(`select fd_tg_redeem($1,101,-900,'group','Team')`,['c'.repeat(64)]));
group=(await db.query('select id from fd_telegram_groups')).rows[0].id;
await asUser(A,async()=>{
 pic=(await db.query(`select (fd_save_pic(gen_random_uuid(),'Developer','dev@example.com',true,true)).id id`)).rows[0].id;
 task=(await db.query(`insert into fd_tasks(user_id,title,category,requires_testing,pic_id,telegram_group_id) values($1,'GEE Platform','Full Time',true,$2,$3) returning *`,[A,pic,group])).rows[0];
 await assert.rejects(()=>db.query(`update fd_tasks set status='Done' where id=$1`,[task.id]),/Transisi/);
 await assert.rejects(()=>db.query(`update fd_tasks set requires_testing=false where id=$1`,[task.id]),/dinonaktifkan/);
 await assert.rejects(()=>db.query(`update fd_tasks set test_cycle=99 where id=$1`,[task.id]),/cycle/);
});
assert.equal((await db.query('select count(*)::int n from fd_telegram_outbox')).rows[0].n,3);
await asUser(C,async()=>{
 assert.equal((await db.query('select * from fd_tasks')).rows.length,0);
 assert.equal((await db.query('select * from fd_task_activity')).rows.length,0);
 await assert.rejects(()=>db.query('select * from fd_telegram_codes'),/permission denied/);
 await assert.rejects(()=>db.query('select * from fd_telegram_outbox'),/permission denied/);
});
await asUser(B,async()=>{
 await assert.rejects(()=>db.query(`update fd_tasks set title='hack' where id=$1`,[task.id]),/PIC hanya/);
 await db.query(`update fd_tasks set status='In progress' where id=$1`,[task.id]);
 await db.query(`update fd_tasks set status='Ready for Testing' where id=$1`,[task.id]);
 await assert.rejects(()=>db.query(`update fd_tasks set status='Done' where id=$1`,[task.id]),/Transisi/);
 await assert.rejects(()=>db.query(`update fd_tasks set status='Testing' where id=$1`,[task.id]),/Transisi/);
});
await asUser(A,async()=>{
 await db.query(`update fd_tasks set status='Testing' where id=$1`,[task.id]);
 await assert.rejects(()=>db.query(`update fd_tasks set status='Rework' where id=$1`,[task.id]),/alasan/);
 await db.query(`update fd_tasks set status='Rework',progress_note='Search fails on empty input' where id=$1`,[task.id]);
});
await asUser(B,async()=>{
 await db.query(`update fd_tasks set status='In progress' where id=$1`,[task.id]);
 await db.query(`update fd_tasks set status='Ready for Testing' where id=$1`,[task.id]);
});
await asUser(A,()=>db.query(`update fd_tasks set status='Testing' where id=$1`,[task.id]));
task=(await db.query('select * from fd_tasks where id=$1',[task.id])).rows[0];
assert.equal(task.test_cycle,2);
await db.query(`insert into fd_telegram_messages(chat_id,message_id,task_id,task_version,target_group_id) values(-900,42,$1,$2,$3)`,[task.id,task.version,group]);
const call=(tg,ver,status,upd=7)=>asService(()=>db.query(`select fd_tg_action($1,$2,-900,42,$3,$4,$5,null) result`,[upd,tg,task.id,ver,status]));
await assert.rejects(()=>call(202,task.version,'Done'),/Transisi/);
await assert.rejects(()=>call(999,task.version,'Done'),/Hubungkan/);
await assert.rejects(()=>call(101,task.version-1,'Done'),/Pesan/);
await call(101,task.version,'Done');
assert.equal((await call(101,task.version,'Done')).rows[0].result.duplicate,true);
await assert.rejects(()=>call(101,task.version,'Done',8),/Pesan sudah lama/);
assert.ok((await db.query('select completed_at from fd_tasks where id=$1',[task.id])).rows[0].completed_at);
await db.query('update fd_profiles set is_active=false where id=$1',[A]);
await assert.rejects(()=>call(101,task.version,'Done',9),/Hubungkan/);
await db.query('update fd_profiles set is_active=true where id=$1',[A]);
// Add an old-style task then replay the combined migration: preserve IDs/data/versions.
const before=JSON.stringify((await db.query('select * from fd_tasks order by id')).rows);
for(const f of files.slice(1))await db.exec(await readFile('supabase/'+f,'utf8'));
assert.equal(JSON.stringify((await db.query('select * from fd_tasks order by id')).rows),before);
const day=(await db.query(`select (now() at time zone 'Asia/Jakarta')::date::text d`)).rows[0].d;
await asUser(A,async()=>{
 const template={title:'Posting daily',category:'Property',kind:'Marketing',priority:'Medium',scheduled_date:day,duration:60,requires_testing:true,acceptance_criteria:'3 posts',telegram_group_id:group};
 await db.query(`select fd_create_recurrence($1,'daily',1,null)`,[template]);
 assert.ok((await db.query('select * from fd_tasks where recurrence_id is not null')).rows.every(t=>t.requires_testing&&t.telegram_group_id===group&&t.acceptance_criteria==='3 posts'));
});
await asService(()=>db.query('select fd_tg_daily()'));
const count=(await db.query('select count(*)::int n from fd_telegram_outbox')).rows[0].n;
await asService(()=>db.query('select fd_tg_daily()'));
assert.equal((await db.query('select count(*)::int n from fd_telegram_outbox')).rows[0].n,count);
await asUser(B,()=>assert.rejects(()=>db.query('select fd_tg_daily()'),/permission denied/));
const claimed=(await asService(()=>db.query('select * from fd_tg_claim(null,2)'))).rows;
assert.equal(claimed.length,2);
await db.exec(`update fd_telegram_outbox set attempted_at=now()-interval '6 minutes' where status='sending'`);
await asService(()=>db.query('select * from fd_tg_claim(null,1)'));
assert.equal((await db.query("select count(*)::int n from fd_telegram_outbox where status='uncertain'")).rows[0].n,2);
console.log('PASS Telegram SQL: migration/replay, RLS, one-use pairing, roles, testing cycles/failures, stale callback, update dedup, outbox, recurrence templates, daily dedup, uncertain recovery.');
await db.close();
