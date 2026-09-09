import {handler,reply,mutation,body,identity,sb,uuid,HttpError} from '../server/core.js';
import {validateTask} from '../server/task-validation.js';
export default handler(async(req,res)=>{
 if(req.method!=='GET')mutation(req);const ctx=await identity(req,res);
 if(req.method==='GET'){const page=Math.max(0,Math.min(1000,Number(req.query.page)||0));const rows=await sb('/rest/v1/fd_tasks?select=*&order=created_at.desc,id.desc&limit=200&offset='+page*200,{token:ctx.token});return reply(res,200,{tasks:rows,hasMore:rows.length===200});}
 const b=body(req);
 if(req.method==='POST'){const t=validateTask(b);const rows=await sb('/rest/v1/fd_tasks',{method:'POST',token:ctx.token,data:{...t,id:uuid(b.id),user_id:ctx.user.id},headers:{Prefer:'return=representation'}});return reply(res,201,{task:rows[0]});}
 if(!Number.isInteger(b.version)||b.version<1)throw new HttpError(400,'Versi tugas diperlukan');const path='/rest/v1/fd_tasks?id=eq.'+uuid(b.id)+'&version=eq.'+b.version;
 if(req.method==='PATCH'||req.method==='DELETE'){
  const rows=await sb(path,{method:req.method,token:ctx.token,...(req.method==='PATCH'?{data:validateTask(b)}:{}),headers:{Prefer:'return=representation'}});
  if(!rows.length)throw new HttpError(409,'Tugas telah berubah atau dihapus. Muat ulang data sebelum mengedit.');return reply(res,200,{task:rows[0]});
 }throw new HttpError(405,'Method not allowed');
});
