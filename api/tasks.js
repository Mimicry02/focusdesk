import {handler,reply,mutation,body,identity,sb,uuid,HttpError} from '../server/core.js';
import {validateTask,validateRepeat} from '../server/task-validation.js';
import {flushQuietly} from '../server/telegram.js';
export default handler(async(req,res)=>{
 if(req.method!=='GET')mutation(req);const ctx=await identity(req,res);
 if(req.method==='GET'&&req.query.activity){const activity=await sb('/rest/v1/fd_task_activity?task_id=eq.'+uuid(req.query.activity)+'&select=*&order=created_at.desc&limit=200',{token:ctx.token});return reply(res,200,{activity});}
 if(req.method==='GET'){const page=Math.max(0,Math.min(1000,Number(req.query.page)||0));if(page===0){const wib=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Jakarta',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date()),horizon=new Date(wib+'T12:00:00Z');horizon.setUTCDate(horizon.getUTCDate()+14);await sb('/rest/v1/rpc/fd_materialize_recurrences',{method:'POST',token:ctx.token,data:{p_until:horizon.toISOString().slice(0,10)}});}const rows=await sb('/rest/v1/fd_tasks?select=*&order=created_at.desc,id.desc&limit=200&offset='+page*200,{token:ctx.token});return reply(res,200,{tasks:rows,hasMore:rows.length===200});}
 const b=body(req);
 if(req.method==='POST'){const t=validateTask(b),repeat=validateRepeat(b,t);if(repeat.pattern!=='once'){const recurrence=await sb('/rest/v1/rpc/fd_create_recurrence',{method:'POST',token:ctx.token,data:{p_template:t,p_pattern:repeat.pattern,p_interval:repeat.interval,p_end_date:repeat.endDate}});await flushQuietly(ctx.user.id);return reply(res,201,{recurrence});}const rows=await sb('/rest/v1/fd_tasks',{method:'POST',token:ctx.token,data:{...t,id:uuid(b.id),user_id:ctx.user.id},headers:{Prefer:'return=representation'}});await flushQuietly(ctx.user.id);return reply(res,201,{task:rows[0]});}
 if(!Number.isInteger(b.version)||b.version<1)throw new HttpError(400,'Versi tugas diperlukan');const path='/rest/v1/fd_tasks?id=eq.'+uuid(b.id)+'&version=eq.'+b.version;
 if(req.method==='PATCH'||req.method==='DELETE'){
  const current=(await sb(path+'&select=*',{token:ctx.token}))[0];
  if(!current)throw new HttpError(409,'Tugas telah berubah atau tidak lagi tersedia. Muat ulang data.');
  const owner=current.user_id===ctx.user.id;
  if(!owner&&(req.method==='DELETE'||b.action!=='progress'))throw new HttpError(403,'PIC hanya dapat memperbarui progres tugas.');
  if(req.method==='PATCH'&&b.action==='stop-recurrence'){if(!owner||!current.recurrence_id)throw new HttpError(403,'Hanya pemilik dapat menghentikan pengulangan');const removed=await sb('/rest/v1/rpc/fd_stop_recurrence',{method:'POST',token:ctx.token,data:{p_id:current.recurrence_id,p_after:current.recurrence_date,p_delete_future:true}});return reply(res,200,{removed,message:'Pengulangan dihentikan dan tugas mendatang yang belum selesai dihapus.'});}
  let data;
  if(req.method==='PATCH'){
   if(b.action==='progress'){
    if(!['Backlog','To do','In progress','Ready for Testing','Testing','Rework','Done'].includes(b.status)||typeof b.progress_note!=='string'||b.progress_note.length>4000)throw new HttpError(400,'Status/progres tidak valid');
    data={status:b.status,progress_note:b.progress_note};
   }else data=validateTask(b);
  }
  const rows=await sb(path,{method:req.method,token:ctx.token,...(data?{data}:{}),headers:{Prefer:'return=representation'}});
  if(!rows.length)throw new HttpError(409,'Tugas telah berubah atau dihapus. Muat ulang data sebelum mengedit.');await flushQuietly(current.user_id);return reply(res,200,{task:rows[0]});
 }throw new HttpError(405,'Method not allowed');
});
