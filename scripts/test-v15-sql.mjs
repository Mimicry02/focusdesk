import {readFile} from 'node:fs/promises';import assert from 'node:assert/strict';
const {PGlite}=await import(process.env.PGLITE_MODULE||'@electric-sql/pglite');const db=new PGlite();
await db.exec(`create schema auth;create role anon;create role authenticated;create role service_role bypassrls;create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb not null default '{}'::jsonb);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated,anon,service_role;`);
for(const f of ['01_schema.sql','03_pic_reports.sql','04_recurring_tasks.sql','05_telegram_workflow.sql','07_telegram_sync_pic.sql'])await db.exec(await readFile('supabase/'+f,'utf8'));
const A='11111111-1111-4111-8111-111111111111',B='22222222-2222-4222-8222-222222222222',C='33333333-3333-4333-8333-333333333333';
await db.query(`insert into auth.users(id,email) values($1,'owner@example.com'),($2,'dev@example.com'),($3,'other@example.com')`,[A,B,C]);await db.exec('update fd_profiles set is_active=true');
async function user(id,fn){await db.exec('set role authenticated');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);try{return await fn()}finally{await db.exec("reset role;select set_config('request.jwt.claim.sub','',false)")}}
async function service(fn){await db.exec('set role service_role');try{return await fn()}finally{await db.exec('reset role')}}
const query=(s,p=[])=>db.query(s,p);const one=async(s,p=[])=>(await query(s,p)).rows[0];
await query('insert into fd_telegram_accounts(user_id,telegram_id,chat_id) values($1,101,101),($2,202,202),($3,303,303)',[A,B,C]);
const G=(await one("insert into fd_telegram_groups(owner_id,chat_id,title) values($1,-100,'Team A') returning id",[A])).id;
const H=(await one("insert into fd_telegram_groups(owner_id,chat_id,title) values($1,-200,'Other team') returning id",[C])).id;
const pic=(await user(A,()=>one(`select (fd_save_pic(gen_random_uuid(),'Dev','dev@example.com',true,true)).id id`))).id;
const mismatch=(await user(A,()=>one(`select (fd_save_pic_v14(gen_random_uuid(),'Other','other@example.com',true,true,null,'not_matched')).id id`))).id;
const day=(await one("select ((now() at time zone 'Asia/Jakarta')::date)::text d")).d;
const date=n=>{const d=new Date(day+'T12:00:00Z');d.setUTCDate(d.getUTCDate()+n);return d.toISOString().slice(0,10)};
async function make(title,{owner=A,group=G,picid=pic,scheduled=day,due=day,testing=false,status='To do'}={}){return user(owner,()=>one('insert into fd_tasks(user_id,title,category,pic_id,scheduled_date,due_date,telegram_group_id,requires_testing,status) values($1,$2,\'Full Time\',$3,$4,$5,$6,$7,$8) returning *',[owner,title,picid,scheduled,due,group,testing,status]));}
const run=async(slot,time,dayOverride=day)=>service(()=>one('select fd_tg_schedule($1,$2::timestamptz) result',[slot,dayOverride+'T'+time+':00+07:00']));
const work=await make('Today executor'),old=await make('Old plan',{scheduled:date(-1),due:date(2)}),future=await make('Tomorrow',{scheduled:date(1),due:date(1)});
const review=await make('Review stage',{testing:true});
await user(B,()=>query("update fd_tasks set status='In progress' where id=$1",[review.id]));await user(B,()=>query("update fd_tasks set status='Ready for Testing' where id=$1",[review.id]));
await make('PRIVATE MUST NOT LEAK',{group:null});await make('Other owner',{owner:C,group:H,picid:null});
await make('Done excluded',{picid:null,status:'Done'});await make('No plan',{scheduled:null,due:null});await make('Mismatch',{picid:mismatch});
for(let i=0;i<25;i++)await make('Batch '+i);
const before=JSON.stringify((await query('select * from fd_tasks order by id')).rows);
const migration=await readFile('supabase/08_scheduled_briefings.sql','utf8');await db.exec(migration);await db.exec(migration);
assert.equal(JSON.stringify((await query('select * from fd_tasks order by id')).rows),before);
await query('delete from fd_telegram_outbox');
await user(A,()=>assert.rejects(()=>query('select fd_tg_schedule()'),/permission denied/));
await user(A,()=>assert.rejects(()=>query('select * from fd_tg_schedule_runs'),/permission denied/));
assert.equal((await run(null,'08:59')).result.reason,'outside_window');
assert.equal((await run('evening','09:00')).result.reason,'outside_window');
const morning=(await run('morning','09:00')).result;assert.equal(morning.generated,true);assert.equal(morning.summaries,2);assert.ok(morning.cards>20);
assert.equal((await run(null,'09:01')).result.reason,'already_generated');
assert.equal((await run('morning','17:29')).result.reason,'already_generated');
let out=(await query('select * from fd_telegram_outbox')).rows;
assert.equal(out.filter(o=>o.kind==='task'&&o.task_id===work.id)[0].target_user_id,B);
assert.equal(out.filter(o=>o.kind==='task'&&o.task_id===review.id)[0].target_user_id,A);
assert.equal(out.filter(o=>o.task_id===future.id).length,0);
assert.equal(out.filter(o=>o.kind==='task'&&o.target_user_id===C&&o.owner_id===A).length,0);
assert.equal(out.filter(o=>o.kind==='task'&&o.target_group_id).length,0);
assert.ok(out.filter(o=>o.task_id===work.id)[0].depends_on);
const data=(await service(()=>one('select fd_tg_briefing_data($1,$2,$3) result',[A,G,day]))).result;
assert.equal(data.carry.count,1);assert.equal(data.today.count,28);assert.equal(data.today.items.length,5);assert.equal(data.tomorrow.count,1);
assert.ok(!JSON.stringify(data).includes('PRIVATE MUST NOT LEAK'));
const wrong=(await service(()=>one('select fd_tg_briefing_data($1,$2,$3) result',[C,G,day]))).result;assert.equal(wrong.today.count,0);
// Dependency behavior is independent of wall clock; clear slots for this isolated claim test.
await query('update fd_telegram_outbox set schedule_slot=null');
let claimed=(await service(()=>query('select * from fd_tg_claim(null,20)'))).rows;
assert.ok(claimed.some(o=>o.kind==='briefing'));assert.ok(!claimed.some(o=>o.task_id===work.id));
await query("update fd_telegram_outbox set status='sent' where status='sending'");
let delivered=claimed.length;for(let i=0;i<5;i++){claimed=(await service(()=>query('select * from fd_tg_claim(null,20)'))).rows;delivered+=claimed.length;await query("update fd_telegram_outbox set status='sent' where status='sending'");}
assert.equal(delivered,out.length);
assert.equal((await run('morning','17:30')).result.reason,'outside_window');
const evening=(await run(null,'17:30')).result;assert.equal(evening.slot,'evening');assert.equal(evening.summaries,2);assert.equal(evening.cards,0);
assert.equal((await run('evening','23:59')).result.reason,'already_generated');
assert.equal((await run(null,'00:00',date(1))).result.reason,'outside_window');
assert.equal((await run('morning','09:00',date(1))).result.generated,true);
// Unpaired and inactive recipients are excluded on subsequent schedule.
await query('delete from fd_telegram_accounts where user_id=$1',[B]);await query('update fd_profiles set is_active=false where id=$1',[C]);
const unpaired=(await run('morning','09:00',date(2))).result;assert.equal(unpaired.summaries,1);assert.equal(unpaired.cards,1); // owner reviewer only
assert.equal((await query('select * from fd_tasks where id=$1',[old.id])).rows[0].status,'To do');
// Simulate a dormant series not yet materialized: scheduler creates occurrences without duplicate event cards.
const series=(await one("insert into fd_recurrences(owner_id,template,pattern,start_date,end_date) values($1,$2::jsonb,'daily',$3,$4) returning id",[A,JSON.stringify({title:'Daily marketing',category:'Property',kind:'Marketing',priority:'Medium',duration:30,due_offset:0,telegram_group_id:G}),day,date(4)])).id;
const generated=(await run('morning','09:00',date(3))).result;assert.equal(generated.materialized,5);
assert.equal((await one('select count(*)::int n from fd_tasks where recurrence_id=$1',[series])).n,5);
assert.equal((await one("select count(*)::int n from fd_telegram_outbox o join fd_tasks t on t.id=o.task_id where t.recurrence_id=$1 and o.dedupe_key like 'event:%'",[series])).n,0);
assert.equal((await one("select count(*)::int n from fd_telegram_outbox o join fd_tasks t on t.id=o.task_id where t.recurrence_id=$1 and o.schedule_slot='morning'",[series])).n,4);
// Old scheduled messages expire rather than appearing on a later day.
await query("insert into fd_telegram_outbox(owner_id,target_group_id,kind,day,schedule_slot,dedupe_key) values($1,$2,'briefing',$3,'evening','old-expiry-test')",[A,G,date(-1)]);
await service(()=>query('select * from fd_tg_claim(null,20)'));
assert.equal((await one("select status from fd_telegram_outbox where dedupe_key='old-expiry-test'")).status,'skipped');
await db.close();console.log('PASS v1.5 SQL: additive replay, 08:59/09:00/17:29/17:30/23:59/midnight WIB, independent slots/days, retry dedupe, full counts/bounded samples, group privacy, executor/reviewer routing, no future/Done/mismatch cards, summary dependency, >20-card draining, inactive/unpaired exclusion.');
