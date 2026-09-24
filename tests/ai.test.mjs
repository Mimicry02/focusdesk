import test from 'node:test';
import assert from 'node:assert/strict';
import {answerFromGuides,aiConfig} from '../server/ai.js';
import {drainDesk} from '../server/desk.js';
import deskAPI from '../api/desk.js';
const S={id:'11111111-1111-4111-8111-111111111111',title:'Preset',heading:'Filter',content:'Pilih Simpan preset.',revision:1};
const cfg={enabled:true,configured:true,model:'gpt-4.1-mini',dailyLimit:100};
process.env.OPENAI_API_KEY='test-only-key';
const json=d=>new Response(JSON.stringify(d));
const completion=r=>json({status:'completed',output:[{type:'message',content:[{type:'output_text',text:JSON.stringify(r)}]}]});
test('Responses API only receives question and scoped excerpts, store false, no tools',async()=>{
 let body,url;
 const r=await answerFromGuides('Cara preset?',[S],{config:cfg,fetcher:async(u,o)=>{url=u;body=JSON.parse(o.body);return completion({answered:true,answer:'Pilih Simpan preset.',source_ids:[S.id]});}});
 assert.equal(r.mode,'ai');assert.equal(url,'https://api.openai.com/v1/responses');assert.equal(body.store,false);assert.equal(body.tools,undefined);assert.equal(body.text.format.strict,true);assert.equal(body.max_output_tokens,1000);assert.ok(!JSON.stringify(body).includes('test-only-key'));assert.equal(JSON.parse(body.input).sources.length,1);
});
test('disabled or missing knowledge never calls OpenAI',async()=>{
 const fetcher=()=>{throw Error('must not call')};
 assert.equal((await answerFromGuides('question',[],{config:cfg,fetcher})).reason,'no_sources');
 assert.equal((await answerFromGuides('question',[S],{config:{...cfg,enabled:false},fetcher})).reason,'disabled');
});
test('unknown citations, empty answer, malformed and oversized outputs fail closed',async()=>{
 for(const out of [{answered:true,answer:'invented',source_ids:['unknown']},{answered:true,answer:'',source_ids:[S.id]},{answered:true,answer:'x'.repeat(1801),source_ids:[S.id]},{answered:'yes',answer:'hello',source_ids:[S.id]}]){
 assert.equal((await answerFromGuides('question',[S],{config:cfg,fetcher:async()=>completion(out)})).mode,'fallback');
 }
 assert.equal((await answerFromGuides('question',[S],{config:cfg,fetcher:async()=>json({status:'incomplete'})})).reason,'incomplete');
});
test('insufficient evidence does not invent an answer',async()=>{
 const r=await answerFromGuides('unrelated',[S],{config:cfg,fetcher:async()=>completion({answered:false,answer:'',source_ids:[]})});assert.equal(r.mode,'unanswered');assert.equal(r.answer,'');
});
test('provider errors and refusal expose no provider body or key',async()=>{
 for(const status of [401,404,429,500]){const r=await answerFromGuides('q',[S],{config:cfg,fetcher:async()=>new Response('SECRET PROVIDER BODY',{status})});assert.equal(r.mode,'fallback');assert.ok(!JSON.stringify(r).includes('SECRET'));}
 const r=await answerFromGuides('q',[S],{config:cfg,fetcher:async()=>json({status:'completed',output:[{type:'message',content:[{type:'refusal',refusal:'blocked'}]}]})});assert.equal(r.reason,'refusal');
});
test('public AI configuration never returns the key and clamps spending cap',()=>{
 process.env.OPENAI_DAILY_LIMIT='9999';assert.equal(aiConfig().dailyLimit,500);assert.equal(aiConfig().key,undefined);delete process.env.OPENAI_DAILY_LIMIT;
});
test('worker persists answer before send, limits inference queue, and retries cached answer without another charge',async()=>{
 const saved=fetch,calls=[];process.env.APP_URL='https://focusdesk.example';process.env.SUPABASE_URL='https://test.supabase.co';process.env.SUPABASE_PUBLISHABLE_KEY='public';process.env.SUPABASE_SECRET_KEY='secret';process.env.TELEGRAM_BOT_TOKEN='test';process.env.OPENAI_ENABLED='true';
 let cached=false;
 global.fetch=async(url,opt)=>{const b=JSON.parse(opt.body||'{}');calls.push(url);
 if(url.includes('fd_desk_claim')){assert.equal(b.p_limit,1);return json([{id:'outbox',group_id:'group',chat_id:-100,request_id:'report',text:'Cached AI',ai_state:cached?'complete':'pending',ai_result:{mode:'ai',sources:[S]}}]);}
 if(url.includes('fd_desk_context'))return json({group_id:'group',applications:[{id:'app'}]});
 if(url.includes('fd_support_requests'))return json([{application_id:'app'}]);
 if(url.includes('fd_desk_ai_context'))return json({question:'Preset?',sources:[S]});
 if(url.includes('fd_desk_ai_reserve'))return json(true);
 if(url.includes('/responses'))return completion({answered:true,answer:'Simpan preset.',source_ids:[S.id]});
 if(url.includes('fd_desk_ai_finish'))return json({text:'Persisted AI'});
 if(url.includes('fd_desk_outbox'))return json(null);
 throw Error(url);};
 try{
 await drainDesk(async(m,b)=>{assert.ok(calls.some(u=>u.includes('fd_desk_ai_finish')));assert.equal(b.text,'Persisted AI');return {message_id:3};});
 cached=true;await drainDesk(async(m,b)=>{assert.equal(b.text,'Cached AI');return {message_id:4};});
 assert.equal(calls.filter(u=>u.includes('/responses')).length,1);
 }finally{global.fetch=saved;delete process.env.OPENAI_ENABLED;}
});
test('AI connection test is admin-only and rejects cross-origin requests',async()=>{
 const saved=fetch;const response=()=>({statusCode:0,setHeader(){},status(n){this.statusCode=n;return this;},json(d){this.data=d;return this;}});
 global.fetch=async(url)=>url.includes('/auth/v1/user')?json({id:S.id}):json([{id:S.id,role:'user',is_active:true}]);
 try{let res=response();await deskAPI({method:'POST',headers:{origin:'https://focusdesk.example','content-type':'application/json',cookie:'fd_access=token'},body:{kind:'ai-test'}},res);assert.equal(res.statusCode,403);
 res=response();await deskAPI({method:'POST',headers:{origin:'https://evil.example','content-type':'application/json'},body:{kind:'ai-test'}},res);assert.equal(res.statusCode,403);
 }finally{global.fetch=saved;}
});
