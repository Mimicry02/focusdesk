import {handler,reply,body,secretMatches,HttpError} from '../server/core.js';
import {receive} from '../server/telegram.js';
export default handler(async(req,res)=>{
 if(req.method!=='POST')throw new HttpError(405,'Method not allowed');
 if(!secretMatches(req.headers['x-telegram-bot-api-secret-token'],process.env.TELEGRAM_WEBHOOK_SECRET))throw new HttpError(401,'Unauthorized');
 // Telegram sends no browser Origin; webhook authentication is the secret header.
 await receive(body(req));return reply(res,200,{ok:true});
});
