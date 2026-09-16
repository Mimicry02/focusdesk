import {handler,reply,secretMatches,HttpError} from '../server/core.js';
import {rpc,drain} from '../server/telegram.js';
export default handler(async(req,res)=>{
 if(req.method!=='GET')throw new HttpError(405,'Method not allowed');
 if(!secretMatches(req.headers.authorization?.replace(/^Bearer /,''),process.env.CRON_SECRET))throw new HttpError(401,'Unauthorized');
 const mode=req.query?.mode||'schedule';
 if(!['queue','schedule','morning','evening'].includes(mode))throw new HttpError(400,'Invalid cron mode');
 if(!process.env.TELEGRAM_BOT_TOKEN)return reply(res,200,{disabled:true,reason:'Telegram token not configured'});
 const generated=mode==='queue'?0:await rpc('fd_tg_schedule',{p_slot:['morning','evening'].includes(mode)?mode:null});
 return reply(res,200,{generated,...await drain(null,20)});
});
