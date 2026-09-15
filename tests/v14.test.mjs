import test from 'node:test';import assert from 'node:assert/strict';
import {receive,drain,keyboard} from '../server/telegram.js';import {actions,roleFor} from '../public/js/workflow.js';import {fetchTasks,taskSnapshot} from '../public/js/sync.js';import tasksAPI from '../api/tasks.js';
const owner='11111111-1111-4111-8111-111111111111',pic='22222222-2222-4222-8222-222222222222',id='33333333-3333-4333-8333-333333333333',group='44444444-4444-4444-8444-444444444444';
const fixture={id,user_id:owner,pic_id:pic,assignee_id:pic,status:'To do',version:1,requires_testing:true,title:'GEE Platform'};
process.env.APP_URL='https://focusdesk.example';process.env.SUPABASE_URL='https://test.supabase.co';process.env.SUPABASE_PUBLISHABLE_KEY='public';process.env.SUPABASE_SECRET_KEY='server';
const json=x=>new Response(JSON.stringify(x));
test('role keyboards separate executor and reviewer; unrelated users have no actions',()=>{
 const o=roleFor(fixture,owner),p=roleFor(fixture,pic),x=roleFor(fixture,'stranger');
 assert.deepEqual(actions(fixture,o.owner,o.executor),[]);assert.deepEqual(actions(fixture,p.owner,p.executor),[['start','Start work']]);assert.deepEqual(keyboard(fixture,x.owner,x.executor).inline_keyboard,[]);
 assert.deepEqual(actions({...fixture,status:'Testing'},false,true),[]);assert.ok(actions({...fixture,status:'Testing'},true,false).some(([a])=>a==='done'));
});
test('background fetch uses read-only pages and detects updates and deletions',async()=>{
 const paths=[];const rows=await fetchTasks(async p=>{paths.push(p);return{tasks:[{id:paths.length,version:1}],hasMore:paths.length===1}},true);
 assert.deepEqual(paths,['tasks?page=0&sync=1','tasks?page=1&sync=1']);assert.equal(rows.length,2);assert.notEqual(taskSnapshot(rows),taskSnapshot(rows.slice(1)));assert.notEqual(taskSnapshot(rows),taskSnapshot([{...rows[0],version:2},rows[1]]));
});
test('Telegram start acknowledges first, commits status, then confirms; web GET sees same status without recurrence writes',async()=>{
 const saved=global.fetch,calls=[];let task={...fixture};process.env.TELEGRAM_BOT_TOKEN='123:fake';
 global.fetch=async(url,opts)=>{const data=opts.body?JSON.parse(opts.body):null;calls.push({url,data});
  if(url.includes('api.telegram.org'))return json({ok:true,result:{message_id:99}});
  if(url.endsWith('/auth/v1/user'))return json({id:owner});
  if(url.includes('fd_profiles'))return json([{id:owner,is_active:true,role:'user'}]);
  if(url.includes('fd_telegram_accounts'))return json([{user_id:pic}]);
  if(url.includes('fd_telegram_messages'))return json([{task_id:id,task_version:1,target_user_id:pic}]);
  if(url.includes('fd_tg_pic_matches'))return json(true);
  if(url.includes('fd_tg_action')){task={...task,status:data.p_status,version:2};return json({status:task.status,version:2})}
  if(url.includes('fd_tg_claim'))return json([]);
  if(url.includes('fd_tasks?'))return json([task]);
  throw Error('Unexpected mock route');
 };
 try{
  await receive({update_id:50,callback_query:{id:'callback',from:{id:202,username:'programmer_gee'},data:`t:${id}:1:start`,message:{message_id:10,chat:{id:202,type:'private'}}}});
  assert.match(calls[0].url,/answerCallbackQuery$/);assert.equal(task.status,'In progress');
  const commit=calls.findIndex(c=>c.url.includes('fd_tg_action')),confirmation=calls.findIndex(c=>c.data?.text?.includes('Status tersimpan: In progress'));assert.ok(commit>=0&&confirmation>commit);
  const res={setHeader(){},status(n){this.code=n;return this},json(v){this.body=v;return this}};
  await tasksAPI({method:'GET',query:{sync:'1'},headers:{cookie:'fd_access=valid'}},res);
  assert.equal(res.code,200);assert.equal(res.body.tasks[0].status,'In progress');assert.ok(!calls.some(c=>c.url.includes('fd_materialize_recurrences')));
 }finally{global.fetch=saved;delete process.env.TELEGRAM_BOT_TOKEN;}
});
test('shared group delivery contains no action keyboard; paired PIC receives Start work',async()=>{
 const saved=global.fetch,sends=[];process.env.TELEGRAM_BOT_TOKEN='123:fake';
 global.fetch=async(url,opts)=>{
  if(url.includes('fd_tg_claim'))return json([{id:'out1',owner_id:owner,target_group_id:group,kind:'task',task_id:id},{id:'out2',owner_id:owner,target_user_id:pic,kind:'task',task_id:id}]);
  if(url.includes('fd_profiles'))return json([{id:owner}]);
  if(url.includes('fd_telegram_groups'))return json([{chat_id:-900}]);
  if(url.includes('fd_telegram_accounts'))return json([{chat_id:202,user_id:pic,telegram_id:202}]);
  if(url.includes('fd_tasks?'))return json([{...fixture,telegram_group_id:group}]);
  if(url.includes('fd_tg_pic_matches'))return json(true);
  if(url.includes('api.telegram.org')){sends.push(JSON.parse(opts.body));return json({ok:true,result:{message_id:sends.length}})}
  if(url.includes('fd_telegram_messages')||url.includes('fd_telegram_outbox'))return json({});
  throw Error('Unexpected mock route');
 };
 try{await drain(owner);const shared=sends.find(s=>s.chat_id===-900),personal=sends.find(s=>s.chat_id===202);assert.ok(shared);assert.equal(shared.reply_markup,undefined);assert.ok(personal.reply_markup.inline_keyboard.flat().some(b=>b.text==='Start work'));}finally{global.fetch=saved;delete process.env.TELEGRAM_BOT_TOKEN;}
});
