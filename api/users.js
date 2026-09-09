import {handler,reply,mutation,body,adminIdentity,sb,env,uuid,email,HttpError} from '../server/core.js';
export default handler(async(req,res)=>{
 if(req.method!=='GET')mutation(req);const ctx=await adminIdentity(req,res);
 if(req.method==='GET'){const page=Math.max(0,Math.min(10000,Number(req.query.page)||0));const users=await sb('/rest/v1/fd_profiles?select=*&order=created_at.desc,id.desc&limit=50&offset='+page*50,{token:ctx.token});const audit=await sb('/rest/v1/fd_audit?select=*&order=created_at.desc&limit=20',{token:ctx.token});return reply(res,200,{users,audit,hasMore:users.length===50});}
 const b=body(req);
 if(b.action==='invite'){
  const recipient=email(b.email);if(typeof b.display_name!=='string'||b.display_name.length>80)throw new HttpError(400,'Nama maksimal 80 karakter');
  const invited=await sb('/auth/v1/invite?redirect_to='+encodeURIComponent(env().app+'/?flow=invite'),{method:'POST',admin:true,data:{email:recipient,data:{display_name:b.display_name.trim()}}});
  const target=invited.id||invited.user?.id;uuid(target);
  try{await sb('/rest/v1/rpc/fd_set_user_access',{method:'POST',token:ctx.token,data:{p_target:target,p_role:'user',p_active:true}})}catch{throw new HttpError(409,'Undangan telah diproses, tetapi aktivasi belum berhasil. Refresh daftar pengguna dan aktifkan akun tersebut; jangan kirim ulang undangan.');}
  return reply(res,200,{message:'Undangan diproses. Pengguna dapat membuka email untuk membuat password.'});
 }
 if(b.action==='access'){
  uuid(b.id);if(!['admin','user'].includes(b.role)||typeof b.is_active!=='boolean')throw new HttpError(400,'Akses tidak valid');
  await sb('/rest/v1/rpc/fd_set_user_access',{method:'POST',token:ctx.token,data:{p_target:b.id,p_role:b.role,p_active:b.is_active}});return reply(res,200,{ok:true});
 }
 if(b.action==='reset'){
  const p=(await sb('/rest/v1/fd_profiles?id=eq.'+uuid(b.id)+'&select=email',{token:ctx.token}))[0];if(!p)throw new HttpError(404,'User tidak ditemukan');
  await sb('/auth/v1/recover?redirect_to='+encodeURIComponent(env().app+'/?flow=recovery'),{method:'POST',data:{email:p.email}});return reply(res,200,{message:'Permintaan reset password diproses.'});
 }throw new HttpError(400,'Unknown action');
});
