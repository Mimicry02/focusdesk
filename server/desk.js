import {sb,HttpError} from './core.js';
import {terms,askInput,deskCallback} from './knowledge.js';
import {aiConfig,answerFromGuides} from './ai.js';
const rpc=(name,data)=>sb('/rest/v1/rpc/'+name,{method:'POST',admin:true,data});
// Dependency injection keeps the Telegram transport shared with the existing workflow.
export async function receiveDesk(update,telegram){
 const q=update.callback_query,m=q?.message||update.message,from=q?.from||m?.from;
 if(!m||!from||from.is_bot||m.sender_chat||!['group','supergroup'].includes(m.chat?.type)||!Number.isSafeInteger(from.id)||!Number.isSafeInteger(m.chat.id))return false;
 const text=update.message?.text||'',cb=deskCallback(q?.data),ask=askInput(text),isList=/^\/(apps|ask)(?:@[A-Za-z0-9_]+)?$/.test(text.trim());
 let binding;
 if(!q&&m.reply_to_message){binding=(await sb(`/rest/v1/fd_desk_outbox?chat_id=eq.${m.chat.id}&sent_message_id=eq.${m.reply_to_message.message_id}&status=eq.sent&select=request_id&limit=1`,{admin:true}))[0];}
 if(!cb&&!ask&&!isList&&!binding?.request_id)return false;
 // Commands explicitly addressed to another bot are not consumed.
 const address=/^\/\w+@([A-Za-z0-9_]+)/.exec(text)?.[1];
 if(address){const me=await telegram('getMe',{});if(address.toLowerCase()!==me.username?.toLowerCase())return false;}
 if(q)try{await telegram('answerCallbackQuery',{callback_query_id:q.id,text:'Memeriksa laporan…'});}catch{}
 const context=await rpc('fd_desk_context',{p_chat:m.chat.id});
 if(!context)return false;
 const say=async(msg)=>rpc('fd_desk_enqueue',{p_request:null,p_group:context.group_id,p_chat:m.chat.id,p_reply:m.message_id,p_text:msg,p_markup:null,p_key:'info:'+update.update_id});
 try{
 if(cb){await rpc('fd_desk_action',{p_update:update.update_id,p_chat:m.chat.id,p_message:m.message_id,p_telegram:from.id,p_request:cb.request,p_action:cb.action,p_value:null});}
 else if(binding?.request_id&&!ask&&!isList){
 if(!text.trim())await say('Tambahkan keterangan dalam bentuk teks. Lampiran belum diimpor; jelaskan error atau sertakan tautan yang dapat diakses PIC.');
 else await rpc('fd_desk_action',{p_update:update.update_id,p_chat:m.chat.id,p_message:m.reply_to_message.message_id,p_telegram:from.id,p_request:binding.request_id,p_action:'note',p_value:text.trim(),p_terms:terms(text)});
 }else if(isList){await say('Aplikasi dalam grup ini:\n'+context.applications.map(a=>a.code+' — '+a.name).join('\n')+'\n\nGunakan /ask KODE pertanyaan. Contoh: /ask GEE Bagaimana cara membuat preset filter?\nBalasan hanya memakai panduan Published.');}
 else {
 let input=ask.input;const first=input.split(/\s+/)[0];let app=context.applications.find(a=>a.code.toLowerCase()===first.toLowerCase());
 if(app)input=input.slice(first.length).trim();else if(context.applications.length===1)app=context.applications[0];
 if(!app){await say('Pilih kode aplikasi: '+context.applications.map(a=>a.code).join(', ')+'. Format: /ask KODE pertanyaan');}
 else if(input.length<3||input.length>3000)await say('Tulis pertanyaan sepanjang 3–3000 karakter.');
 else await rpc('fd_desk_ask',{p_update:update.update_id,p_chat:m.chat.id,p_message:m.message_id,p_telegram:from.id,p_name:from.username?'@'+from.username:from.first_name||'Pelapor',p_application:app.id,p_question:input,p_terms:terms(input)});
 }
 }catch(e){await say(e.status===400||e.status===403?e.message:'Permintaan belum selesai. Coba kembali; jika berulang, hubungi admin Knowledge Desk.');}
 await drainDesk(telegram,6);return true;
}
export async function drainDesk(telegram,limit=8){
 if(!process.env.TELEGRAM_BOT_TOKEN)return {disabled:true};
 // One answer per invocation when AI is enabled keeps inference within Vercel's time budget.
 // Remaining entries are drained by the existing one-minute worker.
 const config=aiConfig();
 const rows=await rpc('fd_desk_claim',{p_limit:config.enabled&&config.configured?1:limit});
 for(const o of rows){
 const finish=data=>sb('/rest/v1/fd_desk_outbox?id=eq.'+o.id,{method:'PATCH',admin:true,data:{...data,updated_at:new Date().toISOString()}});
 let accepted=false;
 try{
 const context=await rpc('fd_desk_context',{p_chat:o.chat_id});
 if(!context||context.group_id!==o.group_id){await finish({status:'skipped',last_error:'Group inactive'});continue;}
 if(o.request_id){const r=(await sb('/rest/v1/fd_support_requests?id=eq.'+o.request_id+'&select=application_id',{admin:true}))[0];if(!r||!context.applications.some(a=>a.id===r.application_id)){await finish({status:'skipped',last_error:'Application visibility revoked'});continue;}}
 let text=o.text;
 if(o.ai_state&&o.ai_state!=='none'){
 const ctx=await rpc('fd_desk_ai_context',{p_outbox:o.id});
 if(!ctx){await finish({status:'skipped',last_error:'Access revoked'});continue;}
 const cachedValid=o.ai_state==='complete'&&(o.ai_result?.mode==='unanswered'||(o.ai_result?.sources?.length&&o.ai_result.sources.every(s=>ctx.sources.some(c=>c.id===s.id))));
 if(!cachedValid){
 let result={mode:'fallback',answer:'',sourceIds:[],model:config.model,reason:o.ai_state==='complete'?'sources_changed':'disabled'};
 if(o.ai_state==='pending'&&config.enabled&&config.configured&&ctx.sources.length){
 const reserved=await rpc('fd_desk_ai_reserve',{p_outbox:o.id,p_limit:config.dailyLimit});
 result=reserved?await answerFromGuides(ctx.question,ctx.sources):{...result,reason:'daily_limit'};
 }
 const saved=await rpc('fd_desk_ai_finish',{p_outbox:o.id,p_mode:result.mode,p_answer:result.answer,p_source_ids:result.sourceIds,p_model:result.model,p_reason:result.reason});
 if(saved.skip)continue;text=saved.text;
 }
 }
 const sent=await telegram('sendMessage',{chat_id:o.chat_id,text,link_preview_options:{is_disabled:true},...(o.reply_to?{reply_parameters:{message_id:o.reply_to,allow_sending_without_reply:true}}:{}),...(o.markup?{reply_markup:o.markup}:{})});accepted=true;
 await finish({status:'sent',sent_message_id:sent.message_id,last_error:null});
 }catch(e){await finish({status:accepted||e.uncertain?'uncertain':e.permanent?'skipped':'failed',last_error:accepted?'Sent; bookkeeping failed':e.message?.startsWith('Telegram')?e.message:'Delivery unavailable',next_attempt_at:new Date(Date.now()+Math.max(60,e.retryAfter||0)*1000).toISOString()});}
 }
 return {processed:rows.length};
}
