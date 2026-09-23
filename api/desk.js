import {handler,reply,mutation,body,identity,sb,uuid,HttpError} from '../server/core.js';
import {chunks} from '../server/knowledge.js';
export default handler(async(req,res)=>{
 if(req.method!=='GET')mutation(req);const ctx=await identity(req,res);
 if(req.method==='GET'){
 if(req.query?.request){const id=uuid(req.query.request);const requests=await sb('/rest/v1/fd_support_requests?id=eq.'+id+'&select=*',{token:ctx.token});if(!requests.length)throw new HttpError(404,'Laporan tidak ditemukan');const notes=await sb('/rest/v1/fd_support_notes?request_id=eq.'+id+'&select=*&order=created_at.asc',{token:ctx.token});return reply(res,200,{request:requests[0],notes});}
 if(req.query?.view==='reports'){const page=Math.max(0,Math.min(1000,Number(req.query.page)||0));const reports=await sb('/rest/v1/fd_support_requests?select=*&order=created_at.desc&limit=50&offset='+page*50,{token:ctx.token});return reply(res,200,{reports,hasMore:reports.length===50});}
 if(ctx.profile.role!=='admin')return reply(res,200,{profile:ctx.profile,master:null});
 const master=await sb('/rest/v1/rpc/fd_desk_admin',{method:'POST',token:ctx.token,data:{p_kind:'list',p_data:{}}});return reply(res,200,{profile:ctx.profile,master});
 }
 if(req.method!=='POST')throw new HttpError(405,'Method not allowed');
 if(ctx.profile.role!=='admin')throw new HttpError(403,'Master hanya untuk admin');
 const b=body(req,350000);if(!['seed','application','category','priority','route','binding','article'].includes(b.kind))throw new HttpError(400,'Operasi tidak valid');
 const d=b.data||{};if(b.kind==='article'){try{d.chunks=chunks(d.content_md,d.title);}catch(e){throw new HttpError(400,e.message);}}
 const result=await sb('/rest/v1/rpc/fd_desk_admin',{method:'POST',token:ctx.token,data:{p_kind:b.kind,p_data:d}});return reply(res,200,result);
});
