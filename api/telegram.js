import {randomBytes} from 'node:crypto';
import {handler,reply,mutation,body,identity,sb,env,uuid,HttpError} from '../server/core.js';
import {telegram,rpc,drain,hashCode,wibDay} from '../server/telegram.js';
export default handler(async(req,res)=>{
 if(req.method!=='GET')mutation(req);
 const ctx=await identity(req,res);
 if(req.method==='GET'){
  const [accounts,groups,history]=await Promise.all([
   sb('/rest/v1/fd_telegram_accounts?select=*',{token:ctx.token}),
   sb('/rest/v1/fd_telegram_groups?select=*&order=created_at',{token:ctx.token}),
   sb('/rest/v1/fd_telegram_outbox?owner_id=eq.'+ctx.user.id+'&select=id,kind,status,attempts,last_error,created_at&order=created_at.desc&limit=20',{admin:true})
  ]);
  return reply(res,200,{configured:!!process.env.TELEGRAM_BOT_TOKEN,webhookConfigured:!!process.env.TELEGRAM_WEBHOOK_SECRET,botUsername:process.env.TELEGRAM_BOT_USERNAME||'',account:accounts[0]||null,groups,history});
 }
 const b=body(req);if(req.method!=='POST')throw new HttpError(405,'Method not allowed');
 if(b.action==='code'){
  if(!['personal','group'].includes(b.kind))throw new HttpError(400,'Invalid pairing kind');
  const code=randomBytes(24).toString('base64url');
  await sb('/rest/v1/rpc/fd_tg_new_code',{method:'POST',token:ctx.token,data:{p_hash:hashCode(code),p_kind:b.kind}});
  return reply(res,200,{code,expiresMinutes:10});
 }
 if(b.action==='disconnect'){
  await sb('/rest/v1/rpc/fd_tg_disconnect',{method:'POST',token:ctx.token,data:{p_group:b.group_id?uuid(b.group_id):null}});
  return reply(res,200,{message:'Koneksi diputus. Pesan yang sudah ada di Telegram tidak terhapus.'});
 }
 if(b.action==='webhook'){
  if(ctx.profile.role!=='admin')throw new HttpError(403,'Hanya admin');
  if(!/^[A-Za-z0-9_-]{32,256}$/.test(process.env.TELEGRAM_WEBHOOK_SECRET||''))throw new HttpError(503,'TELEGRAM_WEBHOOK_SECRET harus 32–256 karakter A-Z/a-z/0-9/_/-');
  const me=await telegram('getMe',{});
  if(me.username!==process.env.TELEGRAM_BOT_USERNAME)throw new HttpError(503,'TELEGRAM_BOT_USERNAME harus sama dengan username dari BotFather (tanpa @)');
  await telegram('setWebhook',{url:env().app+'/api/telegram-webhook',secret_token:process.env.TELEGRAM_WEBHOOK_SECRET,allowed_updates:['message','callback_query'],max_connections:5,drop_pending_updates:false});
  return reply(res,200,{message:'Webhook terdaftar untuk @'+me.username});
 }
 if(b.action==='webhook-status'){
  if(ctx.profile.role!=='admin')throw new HttpError(403,'Hanya admin');
  const w=await telegram('getWebhookInfo',{});
  return reply(res,200,{message:JSON.stringify({url:w.url,pending:w.pending_update_count,last_error:w.last_error_message||null})});
 }
 if(b.action==='daily'){
  const day=wibDay();const account=(await sb('/rest/v1/fd_telegram_accounts?select=user_id',{token:ctx.token}))[0];
  if(!account)throw new HttpError(400,'Hubungkan Telegram pribadi dahulu');
  await sb('/rest/v1/fd_telegram_outbox?on_conflict=dedupe_key',{method:'POST',admin:true,headers:{Prefer:'resolution=ignore-duplicates'},data:{owner_id:ctx.user.id,target_user_id:ctx.user.id,kind:'digest',day,dedupe_key:`daily:${day}:u:${ctx.user.id}`}});
  await drain(ctx.user.id,8);return reply(res,200,{message:'Briefing hari ini diproses maksimal satu kali. Periksa riwayat pengiriman.'});
 }
 if(b.action==='drain'){const r=await drain(ctx.user.id,12);return reply(res,200,{message:r.disabled?'Token Telegram belum diatur':`${r.processed} pesan diproses. Muat ulang riwayat untuk melihat hasil.`});}
 throw new HttpError(400,'Unknown action');
});
