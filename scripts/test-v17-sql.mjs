// Reuse the v1.6 behavioral fixture, then exercise additive AI boundaries.
import {readFile} from 'node:fs/promises';
let code=await readFile(new URL('./test-v16-sql.mjs',import.meta.url),'utf8');
code=code.replace("process.env.PGLITE_MODULE||'@electric-sql/pglite'",JSON.stringify(import.meta.resolve(process.env.PGLITE_MODULE||'@electric-sql/pglite')));
code=code.replace("'10_knowledge_desk.sql','10_knowledge_desk.sql'", "'10_knowledge_desk.sql','12_ai_workspace.sql','12_ai_workspace.sql'");
const tests=`
const aiRequest=(await ask(100)).id;
const box=(await one("select * from fd_desk_outbox where request_id=$1",[aiRequest]));
assert.equal(box.ai_state,'pending');assert.equal(box.ai_sources.length,1);
await db.query("update fd_desk_outbox set status='sending' where id=$1",[box.id]);
const context=async()=>service(()=>one('select fd_desk_ai_context($1) ctx',[box.id]));
assert.equal((await context()).ctx.sources.length,1);
assert.equal((await service(()=>one('select fd_desk_ai_reserve($1,1) ok',[box.id]))).ok,true);
assert.equal((await service(()=>one('select fd_desk_ai_reserve($1,1) ok',[box.id]))).ok,false);
const finish=(id,mode='ai',answer='Gunakan panduan preset filter.',ids=[box.ai_sources[0].id])=>service(()=>one('select fd_desk_ai_finish($1,$2,$3,$4,$5,$6) result',[id,mode,answer,ids,'gpt-4.1-mini','ok']));
await finish(box.id);
assert.equal((await one('select ai_result from fd_desk_outbox where id=$1',[box.id])).ai_result.mode,'ai');
assert.equal((await one('select question from fd_support_requests where id=$1',[aiRequest])).question,'Gimana preset filter?');
assert.equal((await user(A,()=>one('select fd_desk_ai_health() h'))).h.today,1);
assert.equal((await user(C,()=>one('select fd_desk_ai_health() h'))).h.today,0);
await assert.rejects(()=>user(B,()=>one('select fd_desk_ai_health()')),/Admin/);
await assert.rejects(()=>user(A,()=>one('select fd_desk_ai_reserve($1,99)',[box.id])),/permission denied/);
const capped=(await ask(101)).id,cappedBox=await one('select * from fd_desk_outbox where request_id=$1',[capped]);
await db.query("update fd_desk_outbox set status='sending' where id=$1",[cappedBox.id]);
assert.equal((await service(()=>one('select fd_desk_ai_reserve($1,1) ok',[cappedBox.id]))).ok,false);
await finish(cappedBox.id,'ai','invented',['not-a-source']);
assert.equal((await one('select ai_result from fd_desk_outbox where id=$1',[cappedBox.id])).ai_result.mode,'fallback');
// Publication revocation between generation and delivery cannot leak archived text.
await master('article',{...art,id:article,status:'Archived'});
assert.equal((await context()).ctx.sources.length,0);
const archived=await finish(box.id,'fallback','',[]);assert.ok(!archived.result.text.includes('Gunakan panduan aplikasi'));
assert.equal(archived.result.mode,'unanswered');
await master('article',{...art,id:article,status:'Published'});
// Follow-up answers receive their own queued context, while original question stays immutable.
await db.query("update fd_desk_outbox set status='sent',sent_message_id=222 where id=$1",[box.id]);
await service(()=>one("select fd_desk_action(102,-100,222,999,$1,'note','Preset filter gagal',ARRAY['preset','filter'])",[aiRequest]));
const follow=await one("select * from fd_desk_outbox where dedupe_key='action:102'");assert.equal(follow.ai_state,'pending');assert.ok(follow.ai_question.includes('Tambahan terbaru: Preset filter gagal'));
await db.query("update fd_desk_outbox set status='sending' where id=$1",[follow.id]);
await finish(follow.id,'unanswered','',[]);
assert.equal((await one('select status from fd_support_requests where id=$1',[aiRequest])).status,'Clarification');
`;
code=code.replace("await db.query('update fd_desk_groups set active=false where group_id=$1',[G]);",tests+"\nawait db.query('update fd_desk_groups set active=false where group_id=$1',[G]);\nassert.equal((await service(()=>one('select fd_desk_ai_context($1) ctx',[box.id]))).ctx,null);");
code=code.replace('PASS v1.6 SQL:', 'PASS v1.7 SQL: AI queue, atomic budget, source revocation, immutable report, follow-up, admin-only health,');
try{await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));}catch(err){console.error(err.message,err.detail||'',err.where||'');process.exitCode=1;}
