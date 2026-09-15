import {sb,env,HttpError} from './core.js';
import {actions,actionStatus,roleFor} from '../public/js/workflow.js';
import {createHash} from 'node:crypto';
export const hashCode=v=>createHash('sha256').update(v).digest('hex');
export const wibDay=()=>new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Jakarta',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
export const rpc=(name,data)=>sb('/rest/v1/rpc/'+name,{method:'POST',admin:true,data});
export const html=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export async function telegram(method,data){
 const token=process.env.TELEGRAM_BOT_TOKEN;
 if(!token)throw new HttpError(503,'TELEGRAM_BOT_TOKEN belum diatur');
 let r,j;try{
  r=await fetch('https://api.telegram.org/bot'+token+'/'+method,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data),signal:AbortSignal.timeout(8000)});
  j=await r.json();
 }catch{const e=new Error('Telegram response uncertain');e.uncertain=true;throw e;}
 if(!r.ok||!j.ok){const e=new Error('Telegram rejected request ('+(j.error_code||r.status)+')');e.retryAfter=j.parameters?.retry_after;e.permanent=[400,401,403,404].includes(j.error_code||r.status);throw e;}
 return j.result;
}
export function card(t,mentions={}){
 const pic=mentions[t.assignee_id]?`<a href="tg://user?id=${mentions[t.assignee_id]}">${html(t.pic_name||'PIC')}</a>`:html(t.pic_name||t.owner_name||'Pemilik');
 const reviewer=mentions[t.user_id]?`<a href="tg://user?id=${mentions[t.user_id]}">${html(t.owner_name||'Reviewer')}</a>`:html(t.owner_name||'Reviewer');
 return `<b>${html(t.title)}</b>\n${html(t.category)} · ${html(t.project||'Tanpa project')}\nStatus: <b>${html(t.status)}</b> · ${html(t.priority)}\nPIC: ${pic}${t.requires_testing?'\nReviewer: '+reviewer+' · Cycle '+t.test_cycle:''}\nJadwal: ${html(t.scheduled_date||'Belum diatur')} ${html(t.start_time?.slice(0,5)||'')} WIB\nDeadline: ${html(t.due_date||'Belum diatur')}${t.progress_note?'\nProgres / hasil test: '+html(t.progress_note.slice(0,700)):''}${t.requires_testing&&t.acceptance_criteria?'\nKriteria: '+html(t.acceptance_criteria.slice(0,500)):''}\n\nVersi ${t.version} · Catatan internal tidak dikirim.\n<a href="${env().app}">Buka Focusdesk</a>`;
}
export function keyboard(t,owner=true,executor=true){return {inline_keyboard:[...actions(t,owner,executor).map(([a,label])=>[{text:label,callback_data:`t:${t.id}:${t.version}:${a}`}]),...(executor||owner&&t.requires_testing&&['Ready for Testing','Testing','Done'].includes(t.status)?[ [{text:'Add progress',callback_data:`t:${t.id}:${t.version}:note`}] ]:[])]};}
export async function picTelegramAllowed(t,user){
 if(user!==t.assignee_id||!t.pic_id)return true;
 return await rpc('fd_tg_pic_matches',{p_pic:t.pic_id,p_user:user});
}
export function parseCallback(value){const m=/^t:([0-9a-f-]{36}):(\d{1,10}):(start|ready|test|done|fail|todo|note)$/.exec(value||'');return m?{id:m[1],version:Number(m[2]),action:m[3]}:null;}
export function parseReply(value){const s=String(value||'').trim();const m=/^(fail|progress):\s*([\s\S]+)$/i.exec(s);if(m)return{action:m[1].toLowerCase()==='fail'?'fail':'note',note:m[2].trim()};const exact={start:'start',ready:'ready',done:'done',testing:'test'};return exact[s.toLowerCase()]?{action:exact[s.toLowerCase()]}:null;}
async function active(id){return !!(await sb('/rest/v1/fd_profiles?id=eq.'+id+'&is_active=eq.true&select=id',{admin:true}))[0];}
async function target(o){
 if(!await active(o.owner_id))return null;
 if(o.target_user_id){if(!await active(o.target_user_id))return null;return (await sb('/rest/v1/fd_telegram_accounts?user_id=eq.'+o.target_user_id+'&select=chat_id',{admin:true}))[0]?.chat_id;}
 return (await sb('/rest/v1/fd_telegram_groups?id=eq.'+o.target_group_id+'&owner_id=eq.'+o.owner_id+'&active=eq.true&select=chat_id',{admin:true}))[0]?.chat_id;
}
export async function visibleTasks(user,group=null,day=wibDay()){
 let filter=group?'telegram_group_id=eq.'+group+'&user_id=eq.'+user:'or=(user_id.eq.'+user+',assignee_id.eq.'+user+')';
 return sb('/rest/v1/fd_tasks?select=*&'+filter+'&status=neq.Done&and=(or(scheduled_date.lte.'+day+',due_date.lte.'+day+'))&order=due_date.asc.nullslast,created_at.asc&limit=51',{admin:true});
}
async function delivery(o){
 let accepted=false;
 const path='/rest/v1/fd_telegram_outbox?id=eq.'+o.id;
 const finish=data=>sb(path,{method:'PATCH',admin:true,data});
 try{
  const chat=await target(o);if(!chat)return await finish({status:'skipped',last_error:'Recipient disconnected or inactive'});
  let text,markup,t;
  if(o.kind==='task'){
   t=(await sb('/rest/v1/fd_tasks?id=eq.'+o.task_id+'&select=*',{admin:true}))[0];
   if(!t||(o.target_user_id&&![t.user_id,t.assignee_id].includes(o.target_user_id))||(o.target_group_id&&t.telegram_group_id!==o.target_group_id))return await finish({status:'skipped',last_error:'Task access changed'});
   const rows=await sb('/rest/v1/fd_telegram_accounts?user_id=in.('+[t.user_id,t.assignee_id].filter(Boolean).join(',')+')&select=user_id,telegram_id',{admin:true});
   text=card(t,Object.fromEntries(rows.map(r=>[r.user_id,r.telegram_id])));
   // A shared group card is read-only. Role-specific keyboards go to paired DMs.
   if(o.target_user_id){
    const role=roleFor(t,o.target_user_id),matched=await picTelegramAllowed(t,o.target_user_id);
    markup=matched?keyboard(t,role.owner,role.executor):undefined;
    if(!matched)text+='\n\nUsername Telegram belum cocok dengan kontak PIC. Hubungi pemilik tugas.';
   }else text+='\n\nTombol pengerjaan dikirim ke chat pribadi PIC; tombol testing ke reviewer.';
  }else{
   if(o.day!==wibDay())return await finish({status:'skipped',last_error:'Old daily summary expired'});
   const ts=await visibleTasks(o.target_user_id||o.owner_id,o.target_group_id,o.day);
   text=`<b>Focusdesk · ${html(o.day)} WIB</b>\nTugas hari ini & tertunda (${ts.length>50?'50+':ts.length}):\n\n`+ts.slice(0,15).map((x,i)=>`${i+1}. ${html(x.title.slice(0,90))}\n${html(x.status)} · ${html(x.pic_name||x.owner_name||'Saya')} · Due ${html(x.due_date||'—')}`).join('\n\n')+(ts.length>15?'\n\nDaftar dipersingkat; lihat seluruh tugas di Focusdesk.':!ts.length?'Tidak ada tugas terjadwal/terlambat yang terbuka.':'')+`\n\nKetik /tasks untuk kartu tindakan (maks. 10).\n<a href="${env().app}">Buka Focusdesk</a>`;
  }
  const sent=await telegram('sendMessage',{chat_id:chat,text,parse_mode:'HTML',link_preview_options:{is_disabled:true},...(markup?{reply_markup:markup}:{})});accepted=true;
  if(t)await sb('/rest/v1/fd_telegram_messages',{method:'POST',admin:true,data:{chat_id:chat,message_id:sent.message_id,task_id:t.id,task_version:t.version,target_user_id:o.target_user_id,target_group_id:o.target_group_id}});
  await finish({status:'sent',sent_at:new Date().toISOString(),last_error:null});
 }catch(e){
  await finish({status:accepted||e.uncertain?'uncertain':e.permanent?'skipped':'failed',last_error:accepted?'Sent but bookkeeping failed; use /tasks':e.message?.startsWith('Telegram')?e.message:'Database unavailable; retry pending',next_attempt_at:new Date(Date.now()+Math.max(60,e.retryAfter||0,2**o.attempts*30)*1000).toISOString()});
 }
}
export async function drain(owner=null,limit=8){
 if(!process.env.TELEGRAM_BOT_TOKEN)return {disabled:true};
 const rows=await rpc('fd_tg_claim',{p_owner:owner,p_limit:limit});
 for(let i=0;i<rows.length;i+=4)await Promise.all(rows.slice(i,i+4).map(delivery));
 return {processed:rows.length};
}
export async function flushQuietly(owner){try{return await drain(owner,4)}catch{return {queued:true}}}

export async function receive(update){
 if(!Number.isSafeInteger(update.update_id))throw new HttpError(400,'Invalid update');
 const q=update.callback_query,m=q?.message||update.message,from=q?.from||m?.from;
 if(!m||!from||from.is_bot||m.sender_chat||!['private','group','supergroup'].includes(m.chat?.type))return;
 const chat=m.chat.id;
 if(!Number.isSafeInteger(chat)||!Number.isSafeInteger(from.id))return;
 const respond=text=>telegram('sendMessage',{chat_id:chat,text,reply_parameters:{message_id:m.message_id}});
 // Acknowledge before database/outbox work; acknowledgement is NOT success confirmation.
 if(q)try{await telegram('answerCallbackQuery',{callback_query_id:q.id,text:'Memeriksa tindakan…'})}catch{}
 try{
  const text=update.message?.text||'';
  const connect=/^\/(start|connect)(?:@[A-Za-z0-9_]+)?\s+([A-Za-z0-9_-]{32})$/.exec(text.trim());
  if(connect){
   const personal=connect[1]==='start';
   if(personal&&m.chat.type!=='private'||!personal&&!['group','supergroup'].includes(m.chat.type))throw Error('Gunakan /start di chat pribadi dan /connect di grup.');
   if(!personal){const member=await telegram('getChatMember',{chat_id:chat,user_id:from.id});if(!['creator','administrator'].includes(member.status))throw Error('Penghubung harus admin grup Telegram.');}
   await rpc('fd_tg_redeem',{p_hash:hashCode(connect[2]),p_telegram:from.id,p_chat:chat,p_kind:personal?'personal':'group',p_title:m.chat.title||'Personal'});
   if(personal)await sb('/rest/v1/fd_telegram_accounts?telegram_id=eq.'+from.id,{method:'PATCH',admin:true,data:{telegram_username:from.username?.toLowerCase()||null,username_seen_at:new Date().toISOString()}});
   await respond('Terhubung dengan Focusdesk. Ketik /tasks untuk kartu tugas; /help untuk panduan.');return;
  }
  const account=(await sb('/rest/v1/fd_telegram_accounts?telegram_id=eq.'+from.id+'&select=user_id',{admin:true}))[0];
  if(!account||!await active(account.user_id)){if(q||/^\//.test(text))await respond('Hubungkan akun aktif melalui Focusdesk → Settings → Telegram → Connect personal.');return;}
  const user=account.user_id;
  await sb('/rest/v1/fd_telegram_accounts?telegram_id=eq.'+from.id,{method:'PATCH',admin:true,data:{telegram_username:from.username?.toLowerCase()||null,username_seen_at:new Date().toISOString()}});
  let group=null;
  if(chat<0){group=(await sb('/rest/v1/fd_telegram_groups?chat_id=eq.'+chat+'&active=eq.true&select=*',{admin:true}))[0];if(!group)throw Error('Grup belum terhubung.');}
  if(/^\/(tasks|today)(?:@[A-Za-z0-9_]+)?$/.test(text.trim())){
   // Group members may fetch only tasks they own/are assigned, never every group task.
   let ts=await visibleTasks(user);if(group)ts=ts.filter(t=>t.telegram_group_id===group.id&&t.user_id===group.owner_id);
   for(const t of ts.slice(0,10))await sb('/rest/v1/fd_telegram_outbox?on_conflict=dedupe_key',{method:'POST',admin:true,headers:{Prefer:'resolution=ignore-duplicates'},data:{owner_id:t.user_id,target_user_id:user,target_group_id:null,task_id:t.id,kind:'task',dedupe_key:`command:${update.update_id}:${t.id}`}});
   await respond(ts.length?`${Math.min(ts.length,10)} kartu dikirim melalui antrean ke chat pribadi Anda. Tugas lain tersedia di Focusdesk.`:'Tidak ada tugas hari ini/tertunda yang dapat Anda akses.');
   await drain(null,12);return;
  }
  if(/^\/(help|start)(?:@[A-Za-z0-9_]+)?$/.test(text.trim())){await respond('Buat/assign tugas di Focusdesk. /tasks: kartu hari ini & tertunda. Gunakan tombol atau reply kartu: start, ready, testing, done, fail: alasan, progress: catatan. Fail wajib alasan; hanya pemilik dapat meluluskan testing. Kalimat bebas tidak mengubah status.');return;}
  let input,binding;
  if(q){input=parseCallback(q.data);if(!input)return;binding=(await sb(`/rest/v1/fd_telegram_messages?chat_id=eq.${chat}&message_id=eq.${m.message_id}&select=*`,{admin:true}))[0];}
  else if(m.reply_to_message){binding=(await sb(`/rest/v1/fd_telegram_messages?chat_id=eq.${chat}&message_id=eq.${m.reply_to_message.message_id}&select=*`,{admin:true}))[0];const parsed=parseReply(text);if(binding&&parsed)input={...parsed,id:binding.task_id,version:binding.task_version};}
  if(!input||!binding)return;
  if(group){if(q)try{await telegram('editMessageReplyMarkup',{chat_id:chat,message_id:m.message_id,reply_markup:{inline_keyboard:[]}})}catch{}throw Error('Kartu grup hanya untuk informasi. Ketik /tasks; tombol tindakan dikirim ke chat pribadi Anda.');}
  const t=(await sb('/rest/v1/fd_tasks?id=eq.'+input.id+'&select=*',{admin:true}))[0];
  if(!t||![t.user_id,t.assignee_id].includes(user)||!await active(t.user_id)||binding.task_id!==t.id||binding.task_version!==input.version||t.version!==input.version||(group?(t.telegram_group_id!==group.id||binding.target_group_id!==group.id):binding.target_user_id!==user))throw Error('Akses atau versi tugas berubah. Ketik /tasks untuk tombol terbaru.');
  const role=roleFor(t,user);
  if(role.executor&&!await picTelegramAllowed(t,user))throw Error('Username Telegram tidak cocok dengan PIC. Periksa PIC contacts dan hubungkan akun yang benar.');
  if(input.action!=='note'&&!actions(t,role.owner,role.executor).some(([a])=>a===input.action))throw Error('Tindakan ini bukan untuk peran Anda atau tahap tugas saat ini.');
  if(q&&['fail','note'].includes(input.action)){
   if(input.action==='fail'&&(!t.requires_testing||user!==t.user_id||!['Ready for Testing','Testing','Done'].includes(t.status)))throw Error('Hanya reviewer/pemilik dapat mengembalikan tugas pada tahap review.');
   const prompt=await telegram('sendMessage',{chat_id:chat,text:input.action==='fail'?'Reply pesan ini: fail: alasan / hasil testing yang gagal':'Reply pesan ini: progress: catatan pengerjaan',reply_markup:{force_reply:true},reply_parameters:{message_id:m.message_id}});
   await sb('/rest/v1/fd_telegram_messages',{method:'POST',admin:true,data:{chat_id:chat,message_id:prompt.message_id,task_id:t.id,task_version:t.version,target_user_id:group?null:user,target_group_id:group?.id||null}});return;
  }
  const status=input.action==='note'?t.status:actionStatus[input.action];
  const result=await rpc('fd_tg_action',{p_update:update.update_id,p_telegram:from.id,p_chat:chat,p_message:q?m.message_id:m.reply_to_message.message_id,p_task:t.id,p_version:input.version,p_status:status,p_note:input.note??null});
  if(result.duplicate)return;
  // Confirm only committed database state; notification delivery can finish separately.
  try{await respond(`✓ ${t.title}\nStatus tersimpan: ${result.status}\nDashboard akan menyinkronkan otomatis (sekitar 10 detik saat tab aktif).`)}catch{}
  if(q)try{await telegram('editMessageReplyMarkup',{chat_id:chat,message_id:m.message_id,reply_markup:{inline_keyboard:[]}})}catch{}
  await flushQuietly(t.user_id);
 }catch(e){await respond(e.status?e.message:e.message?.startsWith('Telegram')?'Telegram sedang bermasalah. Coba kembali.':e.message||'Tidak dapat memproses tindakan.');}
}
