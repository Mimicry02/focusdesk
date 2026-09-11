import test from 'node:test';import assert from 'node:assert/strict';
import {card,keyboard,parseCallback,parseReply,hashCode,telegram,drain} from '../server/telegram.js';
import {actions} from '../public/js/workflow.js';
import webhook from '../api/telegram-webhook.js';import cron from '../api/telegram-cron.js';
const id='11111111-1111-4111-8111-111111111111';
process.env.APP_URL='https://focusdesk.example';process.env.SUPABASE_URL='https://example.supabase.co';process.env.SUPABASE_PUBLISHABLE_KEY='public-key';process.env.SUPABASE_SECRET_KEY='server-key';
const response=()=>({headers:{},setHeader(k,v){this.headers[k]=v},status(n){this.code=n;return this},json(v){this.data=v;return this}});
test('Telegram parser only accepts contextual explicit actions, never guesses free text',()=>{
 assert.equal(parseReply('not done'),null);assert.equal(parseReply('Done fixing GEE Platform ya'),null);
 assert.deepEqual(parseReply('fail: Search still broken'),{action:'fail',note:'Search still broken'});
 assert.deepEqual(parseReply('Done'),{action:'done'});assert.equal(parseReply('fail: '),null);assert.equal(parseReply('FAIL: Still broken').action,'fail');
 assert.equal(hashCode('private-code').length,64);assert.notEqual(hashCode('a'),hashCode('b'));
});
test('Telegram task cards escape content and exclude notes/email',()=>{
 const t={id,title:'<script>bad</script>',category:'Full Time',status:'Testing',notes:'PRIVATE NOTE',pic_email:'private@example.com',version:2000000000,requires_testing:true,test_cycle:2,progress_note:'<b>escaped</b>'};
 const text=card(t);assert.ok(text.includes('&lt;script&gt;'));assert.ok(!text.includes('PRIVATE NOTE'));assert.ok(!text.includes('private@example.com'));
 for(const row of keyboard(t).inline_keyboard)for(const b of row){assert.ok(Buffer.byteLength(b.callback_data)<=64);assert.ok(parseCallback(b.callback_data));}
 assert.equal(parseCallback('t:bad:4:done'),null);
 assert.deepEqual(actions(t,false),[]);assert.ok(actions(t,true).some(a=>a[0]==='done'));
});
test('Webhook and cron fail closed before making downstream requests',async()=>{
 const old=global.fetch;global.fetch=()=>{throw Error('must not call')};
 process.env.TELEGRAM_WEBHOOK_SECRET='s'.repeat(40);process.env.CRON_SECRET='c'.repeat(40);
 try{const r=response();await webhook({method:'POST',headers:{},body:{update_id:1}},r);assert.equal(r.code,401);
 const c=response();await cron({method:'GET',headers:{}},c);assert.equal(c.code,401);}finally{global.fetch=old;}
});
test('Telegram timeout is ambiguous; 429 is retryable; no token leaked in errors',async()=>{
 const old=global.fetch;process.env.TELEGRAM_BOT_TOKEN='123:secret';
 try{
  global.fetch=async()=>{throw Error('contains-token-do-not-forward')};
  await assert.rejects(()=>telegram('sendMessage',{}),e=>e.uncertain&&!e.message.includes('secret'));
  global.fetch=async()=>new Response(JSON.stringify({ok:false,error_code:429,parameters:{retry_after:45}}),{status:429});
  await assert.rejects(()=>telegram('sendMessage',{}),e=>e.retryAfter===45&&!e.permanent);
 }finally{global.fetch=old;delete process.env.TELEGRAM_BOT_TOKEN;}
});
test('Disconnected target is skipped without calling Telegram',async()=>{
 const old=global.fetch;process.env.TELEGRAM_BOT_TOKEN='123:fake';const calls=[];
 global.fetch=async(url,opts)=>{calls.push({url,opts});if(url.includes('fd_tg_claim'))return new Response(JSON.stringify([{id,owner_id:id,target_user_id:id,kind:'task',attempts:1}]));if(url.includes('fd_profiles'))return new Response(JSON.stringify([{id}]));if(url.includes('fd_telegram_accounts'))return new Response('[]');if(url.includes('fd_telegram_outbox'))return new Response('');throw Error('unexpected')};
 try{await drain(id);assert.ok(!calls.some(x=>x.url.includes('api.telegram.org')));assert.ok(calls.some(x=>x.opts.body?.includes('skipped')));}finally{global.fetch=old;delete process.env.TELEGRAM_BOT_TOKEN;}
});
