import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const {PGlite}=await import(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const db=new PGlite();
await db.exec(`create schema auth; create role anon; create role authenticated; create role service_role bypassrls;
create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb not null default '{}'::jsonb);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema auth to authenticated,anon,service_role; grant execute on function auth.uid() to authenticated,anon,service_role;`);
await db.exec(await readFile('supabase/01_schema.sql','utf8'));
const A='11111111-1111-4111-8111-111111111111',B='22222222-2222-4222-8222-222222222222',C='33333333-3333-4333-8333-333333333333';
await db.query(`insert into auth.users values($1,'owner@example.com','{}'),($2,'dev@example.com','{}'),($3,'other@example.com','{}')`,[A,B,C]);
await db.exec('update fd_profiles set is_active=true');
await db.query(`insert into fd_tasks(user_id,title,category) values($1,'Legacy private','Full Time')`,[A]);
const before=(await db.query('select * from fd_tasks')).rows[0];
const migration=await readFile('supabase/03_pic_reports.sql','utf8');await db.exec(migration);await db.exec(migration);
const after=(await db.query('select * from fd_tasks')).rows[0];assert.equal(after.version,before.version);assert.equal(after.owner_email,'owner@example.com');
async function asUser(id,fn){await db.exec('set role authenticated');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);try{return await fn()}finally{await db.exec('reset role');await db.exec("select set_config('request.jwt.claim.sub','',false)")}}
let pic,task,claim,contact;
await asUser(A,async()=>{
 pic=(await db.query(`select * from fd_save_pic(null,'Programmer','dev@example.com',true,true,null)`)).rows[0];assert.equal(pic.linked_user_id,B);
 contact=(await db.query(`select * from fd_save_pic(null,'External','external@example.com',false,true,null)`)).rows[0];assert.equal(contact.linked_user_id,null);
 await assert.rejects(db.query(`select fd_save_pic(null,'Unknown','unknown@example.com',true,true,null)`),/Belum ada akun aktif/);
 task=(await db.query(`insert into fd_tasks(user_id,title,category,pic_id,assignee_id,scheduled_date,due_date,duration,notes) values($1,'Build UI','Full Time',$2,$3,'2026-09-30','2026-10-02',90,'Acceptance criteria') returning *`,[A,pic.id,C])).rows[0];assert.equal(task.assignee_id,B);assert.equal(task.pic_email,'dev@example.com');
 assert.equal((await db.query('select * from fd_profiles')).rows.length,1);
 claim=(await db.query('select fd_prepare_assignment($1,$2) result',[task.id,task.version])).rows[0].result;assert.equal(claim.claimed,true);assert.equal(claim.message.recipient_email,'dev@example.com');
 assert.equal((await db.query('select fd_prepare_assignment($1,$2) result',[task.id,task.version])).rows[0].result.claimed,false);
 await assert.rejects(db.query('select fd_prepare_assignment($1,$2)',[task.id,999]),/Tugas telah berubah/);
 await assert.rejects(db.query(`select fd_save_pic($1,'Changed','new@example.com',false,true,1)`,[pic.id]),/PIC sedang digunakan/);
});
await asUser(C,async()=>{
 assert.equal((await db.query('select * from fd_tasks')).rows.length,0);
 await assert.rejects(db.query('select fd_prepare_assignment($1,$2)',[task.id,task.version]),/Hanya pemilik/);
 await assert.rejects(db.query(`insert into fd_tasks(user_id,title,category,pic_id) values($1,'Bad','Full Time',$2)`,[C,pic.id]),/PIC tidak dimiliki/);
 assert.equal((await db.query("select fd_report_tasks('2026-09-01','2026-10-01','scheduled','all') report")).rows[0].report.length,0);
});
await asUser(B,async()=>{
 assert.equal((await db.query('select * from fd_tasks')).rows.length,1);
 assert.equal((await db.query('select * from fd_pics')).rows.length,0);
 assert.equal((await db.query('select * from fd_assignment_messages')).rows.length,0);
 await assert.rejects(db.query("update fd_tasks set title='Spoof' where id=$1",[task.id]),/PIC hanya/);
 await assert.rejects(db.query('update fd_tasks set assignee_id=$1 where id=$2',[C,task.id]),/PIC hanya/);
 await assert.rejects(db.query('update fd_tasks set version=999 where id=$1',[task.id]),/PIC hanya/);
 assert.equal((await db.query('delete from fd_tasks where id=$1 returning id',[task.id])).rows.length,0);
 task=(await db.query("update fd_tasks set status='Done',progress_note='Ready for UAT' where id=$1 returning *",[task.id])).rows[0];assert.ok(task.completed_at);assert.equal(task.version,2);
 const r=(await db.query("select fd_report_tasks('2026-09-01','2026-10-01','scheduled','assigned') report")).rows[0].report;assert.equal(r.length,1);assert.equal(r[0].progress_note,'Ready for UAT');
 assert.equal((await db.query("select fd_report_tasks('2026-09-01','2026-10-01','due','assigned') report")).rows[0].report.length,0);
});
// A failed request retries the original immutable task snapshot; old ambiguous sends stop.
await db.query("update fd_assignment_messages set status='failed' where id=$1",[claim.message.id]);
await asUser(A,async()=>{await assert.rejects(db.query('select fd_prepare_assignment($1,1)',[task.id]),/Tugas telah berubah/);const fresh=(await db.query('select fd_prepare_assignment($1,$2) result',[task.id,task.version])).rows[0].result;assert.equal(fresh.message.payload.status,'Done');});
// Completion filters use WIB: Sep 30 17:00 UTC belongs to October.
await db.exec('alter table fd_tasks disable trigger fd_tasks_rules');await db.query("update fd_tasks set completed_at='2026-09-30T17:00:00Z' where id=$1",[task.id]);await db.exec('alter table fd_tasks enable trigger fd_tasks_rules');
await asUser(A,async()=>{
 assert.equal((await db.query("select fd_report_tasks('2026-09-01','2026-10-01','completed','owned') report")).rows[0].report.length,0);
 assert.equal((await db.query("select fd_report_tasks('2026-10-01','2026-11-01','completed','owned') report")).rows[0].report.length,1);
 await assert.rejects(db.query("select fd_report_tasks('2026-09-02','2026-10-01','scheduled','owned')"),/Invalid report/);
 await db.query('update fd_tasks set pic_id=$1 where id=$2',[contact.id,task.id]);
 const t=(await db.query('select * from fd_tasks where id=$1',[task.id])).rows[0];assert.equal(t.assignee_id,null);assert.equal(t.pic_email,'external@example.com');
 const c=(await db.query('select fd_prepare_assignment($1,$2) result',[task.id,t.version])).rows[0].result;
 await db.exec('reset role');await db.query("update fd_assignment_messages set status='failed' where id=$1",[c.message.id]);await db.exec('set role authenticated');
 const retry=(await db.query('select fd_prepare_assignment($1,$2) result',[task.id,t.version])).rows[0].result;assert.equal(retry.message.id,c.message.id);assert.deepEqual(retry.message.payload,c.message.payload);
 await db.exec('reset role');await db.query("update fd_assignment_messages set status='failed',created_at=now()-interval '25 hours' where id=$1",[c.message.id]);await db.exec('set role authenticated');await assert.rejects(db.query('select fd_prepare_assignment($1,$2)',[task.id,t.version]),/Percobaan lama/);
});
await asUser(B,async()=>{assert.equal((await db.query('select * from fd_tasks')).rows.length,0);assert.equal((await db.query("update fd_tasks set status='To do' returning id")).rows.length,0)});
await db.query('update fd_profiles set is_active=false where id=$1',[A]);
await asUser(A,async()=>{assert.equal((await db.query('select * from fd_tasks')).rows.length,0);await assert.rejects(db.query(`select fd_save_pic(null,'Blocked','blocked@example.com',false,true,null)`),/Active account/);});
console.log('PASS v1.1: migration replay/data preservation, linked/email PIC, assignment snapshots, RLS/field permissions, revocation, stale version, idempotency retry boundary, monthly scopes and WIB completion boundary.');await db.close();
