// Local browser smoke test with mocked API responses; never contacts a live project/bot.
import {createServer} from 'node:http';import {readFile,mkdir} from 'node:fs/promises';import {resolve} from 'node:path';import assert from 'node:assert/strict';
const {chromium}=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const owner='11111111-1111-4111-8111-111111111111',pic='22222222-2222-4222-8222-222222222222',gid='33333333-3333-4333-8333-333333333333',tid='44444444-4444-4444-8444-444444444444';
const day=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Jakarta',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
let task={id:tid,user_id:owner,assignee_id:pic,title:'GEE Platform — search fix',category:'Full Time',project:'GEE Platform',priority:'High',kind:'Delivery',status:'Testing',version:4,duration:60,scheduled_date:day,due_date:day,notes:'Internal',progress_note:'Ready to test',requires_testing:true,acceptance_criteria:'Empty input must not crash',test_cycle:1,telegram_group_id:gid};
const requests=[];
const server=createServer(async(req,res)=>{try{const p=new URL(req.url,'http://localhost').pathname;const path=resolve('public',p==='/'?'index.html':'.'+p);if(!path.startsWith(resolve('public')+'/'))throw Error();const value=await readFile(path);res.setHeader('Content-Type',path.endsWith('.js')?'text/javascript':path.endsWith('.css')?'text/css':path.endsWith('.svg')?'image/svg+xml':'text/html');res.end(value)}catch{res.statusCode=404;res.end()}});
await new Promise(ok=>server.listen(0,'127.0.0.1',ok));const port=server.address().port;
const browser=await chromium.launch({headless:true});
try{
 const page=await browser.newPage({viewport:{width:1440,height:1000}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/api/**',async route=>{
  const req=route.request(),url=new URL(req.url()),name=url.pathname.split('/').pop(),b=req.postDataJSON();requests.push({name,b,method:req.method()});let data={};
  if(name==='profile')data={profile:{id:owner,email:'owner@example.com',display_name:'Justin',role:'admin',is_active:true},preferences:{capacity:360,email_enabled:false},deliveries:[],emailConfigured:false};
  if(name==='auth')data={};
  if(name==='pics')data={pics:[{id:pic,name:'Programmer',email:'dev@example.com',linked_user_id:pic,is_active:true}]};
  if(name==='telegram')data=req.method()==='POST'?{code:'X'.repeat(32),message:'OK'}:{configured:true,webhookConfigured:true,botUsername:'focusdesk_test_bot',account:{telegram_id:101},groups:[{id:gid,title:'GEE Team',active:true}],history:[]};
  if(name==='tasks'){if(req.method()==='PATCH')task={...task,...b,version:task.version+1};data=url.searchParams.has('activity')?{activity:[]}:{tasks:[task],hasMore:false,task};}
  await route.fulfill({contentType:'application/json',body:JSON.stringify(data)});
 });
 await page.goto(`http://127.0.0.1:${port}`);
 await page.locator('[data-page="Settings"]').click();
 await page.getByRole('heading',{name:'Telegram · Focusdesk v1.3'}).waitFor();
 await page.locator('[data-tg="personal"]').click();assert.match(await page.locator('#telegram-code').innerText(),/\/start X/);
 await mkdir('qa',{recursive:true});await page.screenshot({path:'qa/telegram-settings-desktop.png',fullPage:true});
 await page.locator('[data-page="All tasks"]').first().click();await page.locator('[data-edit="'+tid+'"]').first().click();
 await page.locator('[data-wf="done"]').waitFor();assert.equal(await page.locator('[name="requires_testing"]').isDisabled(),true);
 await page.screenshot({path:'qa/task-testing-desktop.png',fullPage:true});
 await page.locator('[data-wf="done"]').click();await page.waitForFunction(()=>!document.querySelector('#task-dialog').open);
 assert.equal(task.status,'Done');assert.ok(requests.some(x=>x.b?.action==='progress'&&x.b.status==='Done'));
 // Checkbox must open testing task details, never silently reopen as To do.
 const count=requests.filter(x=>x.method==='PATCH').length;await page.locator('[data-complete="'+tid+'"]').uncheck();await page.locator('#task-dialog[open]').waitFor();assert.equal(requests.filter(x=>x.method==='PATCH').length,count);
 await page.locator('[data-action="close-task"]').click();
 await page.locator('[data-action="new"]').first().click();await page.locator('[name="title"]').fill('3 Posts Everyday');await page.locator('[name="repeat_pattern"]').selectOption('daily');
 await page.locator('[name="telegram_group_id"]').selectOption(gid);await page.getByRole('button',{name:'Save task',exact:true}).click();
 const created=requests.find(x=>x.method==='POST'&&x.name==='tasks');assert.equal(created.b.repeat_pattern,'daily');assert.equal(created.b.telegram_group_id,gid);
 await page.setViewportSize({width:390,height:844});await page.locator('[data-action="sidebar"]').first().click();await page.locator('[data-page="Settings"]').click();
 await page.locator('[data-action="sidebar"]').first().click();await page.locator('.mobile-close').click();
 await page.screenshot({path:'qa/telegram-settings-mobile.png',fullPage:true});
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+2),false);
 assert.deepEqual(errors,[]);console.log('PASS browser UI: Settings/pairing, testing buttons, guarded checkbox, recurring/group form payload, mobile overflow, no page errors (mock API).');
}finally{await browser.close();server.close();}
