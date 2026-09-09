import {handler,reply,mutation,identity,sb,secretMatches,HttpError} from '../server/core.js';
import {sendDigest} from '../server/digest.js';
export default handler(async(req,res)=>{
 if(req.method==='POST'){mutation(req);const ctx=await identity(req,res);return reply(res,200,await sendDigest(ctx.user.id));}
 if(req.method!=='GET')throw new HttpError(405,'Method not allowed');
 if(!secretMatches(req.headers.authorization?.replace(/^Bearer /,''),process.env.CRON_SECRET))throw new HttpError(401,'Unauthorized');
 if(!process.env.RESEND_API_KEY||!process.env.EMAIL_FROM)return reply(res,200,{status:'disabled'});
 // Personal/small-team edition: at most ten opted-in active accounts per invocation.
 const list=await sb('/rest/v1/fd_preferences?email_enabled=eq.true&select=user_id,fd_profiles!inner(is_active)&fd_profiles.is_active=eq.true&order=user_id&limit=11',{admin:true});
 if(list.length>10)throw new HttpError(409,'Lebih dari 10 penerima aktif: konfigurasi worker antrean sebelum mengaktifkan cron.');
 const results=[];for(const p of list){try{results.push({user_id:p.user_id,...await sendDigest(p.user_id)})}catch{results.push({user_id:p.user_id,status:'failed'})}}
 return reply(res,200,{results});
});
