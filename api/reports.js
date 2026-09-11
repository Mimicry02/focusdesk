import {handler,reply,identity,HttpError} from '../server/core.js';
import {buildReport,csvReport} from '../server/report.js';
export default handler(async(req,res)=>{
 if(req.method!=='GET')throw new HttpError(405,'Method not allowed');const ctx=await identity(req,res);
 const format=req.query.format||'json';if(!['json','csv','xlsx'].includes(format))throw new HttpError(400,'Format tidak didukung');
 const r=await buildReport(ctx,req.query);if(format==='json')return reply(res,200,r);
 const filename=`focusdesk-${r.filters.month}-${r.filters.basis}.${format}`;
 let data;
 if(format==='csv')data=Buffer.from(csvReport(r),'utf8');else{const {workbookReport}=await import('../server/report-workbook.js');data=await workbookReport(r);}
 if(data.length>4000000)throw new HttpError(413,'File laporan terlalu besar. Persempit filter kategori/PIC.');
 res.setHeader('Cache-Control','no-store');res.setHeader('Vercel-CDN-Cache-Control','no-store');res.setHeader('Content-Disposition',`attachment; filename="${filename}"`);
 res.setHeader('Content-Type',format==='csv'?'text/csv; charset=utf-8':'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');return res.status(200).send(data);
});
