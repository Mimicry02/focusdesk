import {handler,reply,mutation,body,sb,env,identity,email,password,setSession,clearSession,cookies,HttpError} from '../server/core.js';
export default handler(async(req,res)=>{
 if(req.method==='GET'){const ctx=await identity(req,res);return reply(res,200,{profile:ctx.profile});}
 mutation(req);const b=body(req);
 if(b.action==='login'){
  const s=await sb('/auth/v1/token?grant_type=password',{method:'POST',data:{email:email(b.email),password:typeof b.password==='string'?b.password:''}});
  const p=(await sb('/rest/v1/fd_profiles?id=eq.'+s.user.id+'&select=*',{token:s.access_token}))[0];
  if(!p?.is_active)throw new HttpError(403,'Akun belum aktif. Hubungi admin.');setSession(res,s);return reply(res,200,{profile:p});
 }
 if(b.action==='accept-link'){
  if(typeof b.access_token!=='string'||typeof b.refresh_token!=='string'||b.access_token.length>8000||b.refresh_token.length>2048)throw new HttpError(400,'Tautan tidak valid.');
  const linkedUser=await sb('/auth/v1/user',{token:b.access_token});setSession(res,{access_token:b.access_token,refresh_token:b.refresh_token,expires_in:3600});return reply(res,200,{ok:true,email:linkedUser.email});
 }
 if(b.action==='recover'){
  const recipient=email(b.email);try{await sb('/auth/v1/recover?redirect_to='+encodeURIComponent(env().app+'/?flow=recovery'),{method:'POST',data:{email:recipient}})}catch(e){if(e.status>=500||e.status===429)throw e;}
  return reply(res,200,{message:'Jika akun tersedia, instruksi reset akan dikirim. Periksa inbox dan spam.'});
 }
 if(b.action==='logout'){
  const token=cookies(req).fd_access;clearSession(res);if(token)try{await sb('/auth/v1/logout?scope=local',{method:'POST',token})}catch{}return reply(res,200,{ok:true});
 }
 if(b.action==='password'){const ctx=await identity(req,res,{active:false});await sb('/auth/v1/user',{method:'PUT',token:ctx.token,data:{password:password(b.password)}});return reply(res,200,{ok:true});}
 throw new HttpError(400,'Unknown action');
});
