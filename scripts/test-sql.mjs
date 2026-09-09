// Optional database verification: PGLITE_MODULE=/absolute/path/to/pglite/dist/index.js node scripts/test-sql.mjs
import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const {PGlite}=await import(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const db=new PGlite();
await db.exec(`create schema auth; create role anon; create role authenticated; create role service_role bypassrls;
create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb not null default '{}'::jsonb);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema auth to authenticated,anon,service_role;
grant execute on function auth.uid() to authenticated,anon,service_role;`);
const sql=await readFile('supabase/01_schema.sql','utf8');await db.exec(sql);await db.exec(sql);
const A='11111111-1111-4111-8111-111111111111',B='22222222-2222-4222-8222-222222222222',C='33333333-3333-4333-8333-333333333333';
await db.query(`insert into auth.users values($1,'owner@example.com','{"role":"admin","is_active":true}'),($2,'user@example.com','{}'),($3,'other@example.com','{}')`,[A,B,C]);
assert.equal((await db.query('select role,is_active from public.fd_profiles where id=$1',[A])).rows[0].is_active,false);
assert.equal((await db.query('select role from public.fd_profiles where id=$1',[A])).rows[0].role,'user');
await db.query(`update fd_profiles set role='admin',is_active=true where id=$1`,[A]);
async function asUser(id,fn){await db.exec('set role authenticated');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);try{return await fn()}finally{await db.exec('reset role')}}
await asUser(A,async()=>{await db.query("select fd_set_user_access($1,'user',true)",[B]);await db.query("select fd_set_user_access($1,'user',true)",[C]);});
await asUser(B,async()=>{await db.query(`insert into fd_tasks(user_id,title,category) values($1,'Private B','Full Time')`,[B]);assert.equal((await db.query('select * from fd_profiles')).rows.length,1);await assert.rejects(db.query(`update fd_profiles set role='admin' where id=$1`,[B]),/permission denied/);await assert.rejects(db.query(`select fd_set_user_access($1,'admin',true)`,[C]),/Admin access/);await assert.rejects(db.query(`insert into fd_tasks(user_id,title,category) values($1,'Attack','Property')`,[C]),/row-level security/);});
await asUser(C,async()=>{assert.equal((await db.query('select * from fd_tasks')).rows.length,0);assert.equal((await db.query("update fd_tasks set title='Attack' returning id")).rows.length,0);});
await asUser(A,async()=>{assert.equal((await db.query('select * from fd_tasks')).rows.length,0);assert.equal((await db.query('select * from fd_profiles')).rows.length,3);await assert.rejects(db.query("select fd_set_user_access($1,'user',false)",[A]),/akun sendiri/);});
await asUser(B,async()=>{for(let i=0;i<3;i++)await db.query(`insert into fd_tasks(user_id,title,category,scheduled_date,top_focus) values($1,$2,'Full Time','2026-09-09',true)`,[B,'Top '+i]);await assert.rejects(db.query(`insert into fd_tasks(user_id,title,category,scheduled_date,top_focus) values($1,'Fourth','Full Time','2026-09-09',true)`,[B]),/Maksimal tiga/);const t=(await db.query('select * from fd_tasks where top_focus limit 1')).rows[0];await db.query("update fd_tasks set status='Done' where id=$1",[t.id]);const after=(await db.query('select * from fd_tasks where id=$1',[t.id])).rows[0];assert.equal(after.version,t.version+1);assert.ok(after.completed_at);await db.query(`insert into fd_tasks(user_id,title,category,scheduled_date,top_focus) values($1,'Next top','Full Time','2026-09-09',true)`,[B]);await assert.rejects(db.query(`insert into fd_tasks(user_id,title,category,scheduled_date,start_time,duration) values($1,'Midnight','Full Time','2026-09-09','23:30',90)`,[B]),/check constraint/);await assert.rejects(db.query("select fd_claim_digest($1,'2026-09-09')",[B]),/permission denied/);});
await asUser(A,async()=>await db.query("select fd_set_user_access($1,'user',false)",[B]));
await asUser(B,async()=>{assert.equal((await db.query('select * from fd_tasks')).rows.length,0);await assert.rejects(db.query(`insert into fd_tasks(user_id,title,category) values($1,'Inactive','Full Time')`,[B]),/row-level security/)});
await db.exec('set role service_role');assert.equal((await db.query("select fd_claim_digest($1,'2026-09-09') as claimed",[C])).rows[0].claimed,true);assert.equal((await db.query("select fd_claim_digest($1,'2026-09-09') as claimed",[C])).rows[0].claimed,false);await db.exec('reset role');
console.log('PASS: idempotent schema, inactive signup, metadata escalation rejected, own-only RLS, admin task privacy, RPC role gate, self-protection, focus limit, versioning, midnight constraint, disabled-account access, digest deduplication.');await db.close();
