import test from 'node:test';import assert from 'node:assert/strict';
import {briefingText,scheduledExpired} from '../server/briefing.js';
import {drain,wibDay} from '../server/telegram.js';import cron from '../api/telegram-cron.js';
const A='11111111-1111-4111-8111-111111111111',B='22222222-2222-4222-8222-222222222222',G='33333333-3333-4333-8333-333333333333';
process.env.APP_URL='https://focusdesk.example';process.env.SUPABASE_URL='https://test.supabase.co';process.env.SUPABASE_PUBLISHABLE_KEY='public';process.env.SUPABASE_SECRET_KEY='secret';process.env.CRON_SECRET='c'.repeat(40);
const res=()=>({setHeader(){},status(code){this.code=code;return this},json(data){this.data=data;return this}});
const json=data=>new Response(JSON.stringify(data));
test('morning and evening sections escape content, bound samples, show counts and no internal fields',()=>{
 const entry={title:'<script>'+ 'x'.repeat(180),status:'Testing',pic_name:'A & B',scheduled_date:'2026-09-16',due_date:'2026-09-16',notes:'PRIVATE'};
 const bucket={count:100,items:Array(5).fill(entry)},data={carry:bucket,today:bucket,tomorrow:bucket};
 const morning=briefingText(data,'morning','2026-09-16',process.env.APP_URL),evening=briefingText(data,'evening','2026-09-16',process.env.APP_URL);
 assert.ok(!morning.includes('Agenda besok'));assert.ok(evening.includes('Agenda besok (100)'));assert.ok(evening.includes('Hari ini belum selesai'));assert.ok(evening.includes('&lt;script&gt;'));assert.ok(evening.includes('A &amp; B'));assert.ok(!evening.includes('PRIVATE'));assert.ok(evening.length<4096);
 const empty=briefingText({},'evening','2026-09-16',process.env.APP_URL);assert.equal((empty.match(/Tidak ada tugas terbuka/g)||[]).length,3);
});
test('scheduled expiry uses WIB midnight and morning cutoff',()=>{
 const o={schedule_slot:'morning',day:'2026-09-16'};
 assert.equal(scheduledExpired(o,new Date('2026-09-16T10:29:59Z')),false);
 assert.equal(scheduledExpired(o,new Date('2026-09-16T10:30:00Z')),true);
 assert.equal(scheduledExpired({...o,schedule_slot:'evening'},new Date('2026-09-16T16:59:59Z')),false);
 assert.equal(scheduledExpired({...o,schedule_slot:'evening'},new Date('2026-09-16T17:00:00Z')),true);
 assert.equal(scheduledExpired({kind:'task'}),false);
});
test('cron allowlists modes, passes slot only, uses DB clock and queue mode does not generate',async()=>{
 const previous=global.fetch,calls=[];process.env.TELEGRAM_BOT_TOKEN='123:fake';
 global.fetch=async(url,opt)=>{calls.push({url,data:JSON.parse(opt.body||'{}')});if(url.includes('fd_tg_schedule'))return json({generated:true});if(url.includes('fd_tg_claim')||url.includes('fd_desk_claim'))return json([]);throw Error('unexpected')};
 try{
  for(const mode of ['morning','evening','schedule']){const r=res();await cron({method:'GET',headers:{authorization:'Bearer '+process.env.CRON_SECRET},query:{mode,p_now:'1999-01-01'}},r);assert.equal(r.code,200);assert.deepEqual(calls.at(-3).data,{p_slot:mode==='schedule'?null:mode});}
  const n=calls.length,r=res();await cron({method:'GET',headers:{authorization:'Bearer '+process.env.CRON_SECRET},query:{mode:'queue'}},r);assert.equal(calls.length,n+2);assert.ok(calls.at(-1).url.includes('fd_desk_claim'));
  const bad=res();await cron({method:'GET',headers:{authorization:'Bearer '+process.env.CRON_SECRET},query:{mode:'arbitrary'}},bad);assert.equal(bad.code,400);
 }finally{global.fetch=previous;delete process.env.TELEGRAM_BOT_TOKEN;}
});
test('group evening digest uses scoped RPC and sends no keyboard or private task content',async()=>{
 const previous=global.fetch,calls=[];process.env.TELEGRAM_BOT_TOKEN='123:fake';
 global.fetch=async(url,opt)=>{const data=JSON.parse(opt.body||'{}');calls.push({url,data});
  if(url.includes('fd_tg_claim'))return json([{id:A,owner_id:A,target_group_id:G,kind:'briefing',schedule_slot:'evening',day:wibDay(),attempts:1}]);
  if(url.includes('fd_profiles'))return json([{id:A}]);if(url.includes('fd_telegram_groups'))return json([{chat_id:-900}]);
  if(url.includes('fd_tg_briefing_data'))return json({today:{count:1,items:[{title:'Group task',status:'Testing',pic_name:'Dev'}]}});
  if(url.includes('api.telegram.org'))return json({ok:true,result:{message_id:20}});if(url.includes('fd_telegram_outbox'))return json({});throw Error('unexpected');
 };
 try{await drain();assert.deepEqual(calls.find(c=>c.url.includes('fd_tg_briefing_data')).data,{p_owner:A,p_group:G,p_day:wibDay()});const sent=calls.find(c=>c.url.includes('sendMessage')).data;assert.equal(sent.chat_id,-900);assert.equal(sent.reply_markup,undefined);assert.ok(sent.text.includes('Agenda besok'));assert.ok(calls.some(c=>c.data.status==='sent'));}finally{global.fetch=previous;delete process.env.TELEGRAM_BOT_TOKEN;}
});
test('scheduled card rechecks current status and skips completed work',async()=>{
 const previous=global.fetch,calls=[];process.env.TELEGRAM_BOT_TOKEN='123:fake';
 global.fetch=async(url,opt)=>{const data=JSON.parse(opt.body||'{}');calls.push({url,data});
  if(url.includes('fd_tg_claim'))return json([{id:A,owner_id:A,target_user_id:B,task_id:G,kind:'task',schedule_slot:'evening',day:wibDay(),attempts:1}]);
  if(url.includes('fd_profiles'))return json([{id:B}]);if(url.includes('fd_telegram_accounts'))return json([{chat_id:202}]);if(url.includes('fd_tasks'))return json([{id:G,user_id:A,assignee_id:B,status:'Done'}]);if(url.includes('fd_telegram_outbox'))return json({});throw Error('unexpected');
 };
 try{await drain();assert.ok(!calls.some(c=>c.url.includes('api.telegram.org')));assert.ok(calls.some(c=>c.data.status==='skipped'));}finally{global.fetch=previous;delete process.env.TELEGRAM_BOT_TOKEN;}
});
