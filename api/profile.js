import {handler,reply,mutation,body,identity,sb,HttpError} from '../server/core.js';
export default handler(async(req,res)=>{
 if(req.method!=='GET')mutation(req);const ctx=await identity(req,res);
 if(req.method==='GET'){const preferences=(await sb('/rest/v1/fd_preferences?user_id=eq.'+ctx.user.id,{token:ctx.token}))[0];const deliveries=await sb('/rest/v1/fd_deliveries?select=day,status,accepted_at&order=day.desc&limit=5',{token:ctx.token});return reply(res,200,{profile:ctx.profile,preferences,deliveries,emailConfigured:!!(process.env.RESEND_API_KEY&&process.env.EMAIL_FROM&&process.env.CRON_SECRET)});}
 if(req.method==='PATCH'){const b=body(req);if(typeof b.display_name!=='string'||!b.display_name.trim()||b.display_name.length>80||!Number.isInteger(b.capacity)||b.capacity<30||b.capacity>1440||typeof b.email_enabled!=='boolean')throw new HttpError(400,'Preferensi tidak valid');
 await sb('/rest/v1/fd_profiles?id=eq.'+ctx.user.id,{method:'PATCH',token:ctx.token,data:{display_name:b.display_name.trim()}});
 await sb('/rest/v1/fd_preferences?user_id=eq.'+ctx.user.id,{method:'PATCH',token:ctx.token,data:{capacity:b.capacity,email_enabled:b.email_enabled}});return reply(res,200,{ok:true});
 }throw new HttpError(405,'Method not allowed');
});
