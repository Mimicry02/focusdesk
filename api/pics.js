import {handler,reply,mutation,body,identity,sb,uuid,email,HttpError} from '../server/core.js';
export default handler(async(req,res)=>{
 if(req.method!=='GET')mutation(req);const ctx=await identity(req,res);
 if(req.method==='GET'){
  const page=Math.max(0,Math.min(1000,Number(req.query.page)||0));
  const pics=await sb('/rest/v1/fd_pics?select=*&order=name.asc,id.asc&limit=100&offset='+page*100,{token:ctx.token});
  return reply(res,200,{pics,hasMore:pics.length===100});
 }
 if(req.method==='POST'){
  const b=body(req);if(typeof b.name!=='string'||!b.name.trim()||b.name.length>80||typeof b.link_account!=='boolean'||typeof b.is_active!=='boolean')throw new HttpError(400,'Data PIC tidak valid');
  const pic=await sb('/rest/v1/rpc/fd_save_pic',{method:'POST',token:ctx.token,data:{p_id:uuid(b.id),p_name:b.name,p_email:email(b.email),p_link:b.link_account,p_active:b.is_active,p_version:b.version||null}});
  return reply(res,200,{pic});
 }throw new HttpError(405,'Method not allowed');
});
