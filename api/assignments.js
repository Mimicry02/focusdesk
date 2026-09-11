import {handler,reply,mutation,body,identity,sb,uuid,HttpError,env} from '../server/core.js';
import {assignmentMessage} from '../server/assignment-email.js';
export default handler(async(req,res)=>{
 if(req.method!=='GET')mutation(req);const ctx=await identity(req,res);
 if(req.method==='GET'){
  const id=uuid(req.query.task);const t=(await sb('/rest/v1/fd_tasks?id=eq.'+id+'&user_id=eq.'+ctx.user.id+'&select=*',{token:ctx.token}))[0];
  if(!t)throw new HttpError(404,'Tugas milik Anda tidak ditemukan');
  if(!t.pic_email)throw new HttpError(400,'Pilih PIC dan simpan tugas terlebih dahulu');
  const history=await sb('/rest/v1/fd_assignment_messages?task_id=eq.'+id+'&select=id,recipient_email,task_version,status,attempt_at,accepted_at&order=created_at.desc&limit=5',{token:ctx.token});
  return reply(res,200,{task_id:t.id,version:t.version,recipient:t.pic_email,pic_name:t.pic_name,...assignmentMessage(t,env().app),history,emailConfigured:!!(process.env.RESEND_API_KEY&&process.env.EMAIL_FROM)});
 }
 if(req.method!=='POST')throw new HttpError(405,'Method not allowed');
 const b=body(req);uuid(b.task_id);if(!Number.isInteger(b.version)||b.version<1)throw new HttpError(400,'Task version required');
 if(!process.env.RESEND_API_KEY||!process.env.EMAIL_FROM)throw new HttpError(503,'Konfigurasikan RESEND_API_KEY dan EMAIL_FROM di Vercel untuk email penugasan');
 const prepared=await sb('/rest/v1/rpc/fd_prepare_assignment',{method:'POST',token:ctx.token,data:{p_task:b.task_id,p_version:b.version}});
 if(!prepared.claimed)return reply(res,200,{status:prepared.message.status,message:'Versi tugas ini sudah dikirim atau sedang diproses.'});
 const m=prepared.message;const payload=assignmentMessage(m.payload,env().app);
 try{
  const r=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:'Bearer '+process.env.RESEND_API_KEY,'Content-Type':'application/json','Idempotency-Key':'fd-assignment-'+m.id},body:JSON.stringify({from:process.env.EMAIL_FROM,to:[m.recipient_email],reply_to:m.payload.owner_email,subject:payload.subject,text:payload.text}),signal:AbortSignal.timeout(15000)});
  const result=await r.json();if(!r.ok)throw new HttpError(502,'Pengiriman ditolak penyedia email. Periksa konfigurasi/domain pengirim.');
  await sb('/rest/v1/fd_assignment_messages?id=eq.'+m.id,{method:'PATCH',admin:true,data:{status:'accepted',provider_id:result.id,accepted_at:new Date().toISOString()}});
  return reply(res,200,{status:'accepted',message:'Email penugasan diterima penyedia email. Status ini belum membuktikan masuk inbox PIC.'});
 }catch(err){try{await sb('/rest/v1/fd_assignment_messages?id=eq.'+m.id,{method:'PATCH',admin:true,data:{status:'failed',last_error:'Periksa provider dan konfigurasi sebelum retry.'}})}catch{}throw err;}
});
