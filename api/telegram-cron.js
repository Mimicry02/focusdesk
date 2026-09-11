import {handler,reply,secretMatches,HttpError} from '../server/core.js';
import {rpc,drain} from '../server/telegram.js';
export default handler(async(req,res)=>{
 if(req.method!=='GET')throw new HttpError(405,'Method not allowed');
 if(!secretMatches(req.headers.authorization?.replace(/^Bearer /,''),process.env.CRON_SECRET))throw new HttpError(401,'Unauthorized');
 const generated=req.query?.mode==='queue'?0:await rpc('fd_tg_daily',{});
 return reply(res,200,{generated,...await drain(null,20)});
});
