// Mock API browser integration. No live accounts, mail, or Telegram traffic.
import {createServer} from 'node:http';import {readFile,mkdir} from 'node:fs/promises';import {resolve} from 'node:path';import assert from 'node:assert/strict';
const {chromium}=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
let launch={headless:true};if(process.env.CHROMIUM_MODULE){const {default:c}=await import(process.env.CHROMIUM_MODULE);launch={...launch,args:c.args,executablePath:process.env.CHROMIUM_EXECUTABLE||await c.executablePath()};}
if(process.env.CHROMIUM_EXECUTABLE)launch={headless:true,executablePath:process.env.CHROMIUM_EXECUTABLE,args:['--disable-gpu','--disable-software-rasterizer','--no-sandbox','--no-zygote','--single-process']};
const A='11111111-1111-4111-8111-111111111111',B='22222222-2222-4222-8222-222222222222',P='33333333-3333-4333-8333-333333333333',G='44444444-4444-4444-8444-444444444444';
const ids=Array.from({length:6},(_,i)=>`55555555-5555-4555-8555-55555555555${i}`);
const day=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Jakarta',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
const base={user_id:A,assignee_id:null,pic_id:null,version:1,category:'Full Time',project:'GEE Platform',kind:'Delivery',status:'To do',priority:'High',scheduled_date:day,due_date:day,duration:60,notes:'Acceptance notes',progress_note:'',owner_name:'Justin',requires_testing:false};
let tasks=[{...base,id:ids[0],title:'Perbaikan pencarian GEE Platform',pic_id:P,assignee_id:B,pic_name:'Raka',requires_testing:true,status:'To do',test_cycle:0},
 {...base,id:ids[1],title:'Review integrasi data MONEV',pic_id:P,assignee_id:B,pic_name:'Raka',requires_testing:true,status:'Ready for Testing',test_cycle:1},
 {...base,id:ids[2],title:'Finalisasi requirement SRL',start_time:'09:00',top_focus:true,duration:90},
 {...base,id:ids[3],title:'3 posting properti · Tangerang',category:'Property',project:'Tangerang listings',kind:'Marketing',priority:'Medium',recurrence_pattern:'daily',start_time:'11:00'},
 {...base,id:ids[4],title:'Follow-up website calon klien',category:'Web Development',project:'Company profile',kind:'Follow-up',priority:'Medium',start_time:'14:00',duration:30},
 {...base,id:ids[5],title:'Susun skenario UAT',status:'In progress',start_time:'15:00'}];
let pics=[{id:P,name:'Raka',email:'raka@example.com',linked_user_id:B,is_active:true,version:1,telegram_username:'raka_dev',observed_username:'raka_dev',telegram_status:'verified'}];
let sessionUser=A;const requests=[];
const server=createServer(async(req,res)=>{try{const p=new URL(req.url,'http://localhost').pathname,f=resolve('public',p==='/'?'index.html':'.'+p);if(!f.startsWith(resolve('public')+'/'))throw Error();res.setHeader('Content-Type',f.endsWith('.js')?'text/javascript':f.endsWith('.css')?'text/css':f.endsWith('.svg')?'image/svg+xml':'text/html');res.end(await readFile(f))}catch{res.statusCode=404;res.end()}});
await new Promise(ok=>server.listen(0,'127.0.0.1',ok));const browser=await chromium.launch(launch);
try{
 const page=await browser.newPage({viewport:{width:1440,height:1050}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.clock.install();
 await page.route('**/api/**',async route=>{const req=route.request(),u=new URL(req.url()),name=u.pathname.split('/').pop(),b=req.postDataJSON();requests.push({name,b,query:u.search,method:req.method()});let data={};
  if(name==='profile')data={profile:{id:sessionUser,email:'justin@example.com',display_name:'Justin',role:'admin',is_active:true},preferences:{capacity:360,email_enabled:false},deliveries:[],emailConfigured:false};
  if(name==='pics'){if(b){pics=[{...pics[0],...b}];data={pic:pics[0]}}else data={pics,hasMore:false};}
  if(name==='telegram')data=b?{code:'X'.repeat(32),message:'OK'}:{configured:true,webhookConfigured:true,botUsername:'focusdesk_test_bot',account:{telegram_id:101,telegram_username:'justin_sa'},groups:[{id:G,title:'GEE Team',active:true}],history:[]};
  if(name==='tasks'){
   if(req.method()==='PATCH'){let current=tasks.find(t=>t.id===b.id);if(current.version!==b.version){await route.fulfill({status:409,contentType:'application/json',body:'{"error":"Stale version"}'});return;}tasks=tasks.map(t=>t.id===b.id?{...t,...b,version:t.version+1}:t);}
   if(req.method()==='POST')tasks.push({...base,...b,version:1});
   data=u.searchParams.has('activity')?{activity:[]}:{tasks:sessionUser===A?tasks:tasks.filter(t=>t.assignee_id===B),hasMore:false,task:tasks.find(t=>t.id===b?.id)};
  }
  await route.fulfill({contentType:'application/json',body:JSON.stringify(data)});
 });
 await page.goto(`http://127.0.0.1:${server.address().port}`);await page.locator('.metrics-grid').waitFor();
 await mkdir('qa',{recursive:true});await page.screenshot({path:'qa/dashboard-desktop.png',fullPage:true});
 // A Telegram mutation while this tab stays focused must update the dashboard.
 tasks[0]={...tasks[0],status:'In progress',version:2};await page.clock.fastForward(10001);
 await page.waitForFunction(()=>document.querySelector('.metric-card.blue strong')?.textContent==='2');
 assert.ok(requests.some(r=>r.query.includes('sync=1')));
 // Preserve unsaved text in a modal and prevent overwriting the new server version.
 await page.locator('[data-edit="'+ids[0]+'"]').first().click();await page.locator('[name="notes"]').fill('UNSAVED PERSONAL DRAFT');
 tasks[0]={...tasks[0],status:'Ready for Testing',test_cycle:1,version:3};await page.clock.fastForward(10001);
 await page.getByText('Status terbaru: Ready for Testing',{exact:true}).waitFor();assert.equal(await page.locator('[name="notes"]').inputValue(),'UNSAVED PERSONAL DRAFT');
 assert.equal(await page.getByRole('button',{name:'Save task',exact:true}).isDisabled(),true);
 await page.screenshot({path:'qa/live-status-modal.png'});
 page.once('dialog',d=>d.accept());await page.locator('[data-action="reload-task"]').click();await page.locator('[data-wf="test"]').waitFor();
 await page.locator('[data-wf="test"]').click();await page.waitForFunction(()=>!document.querySelector('#task-dialog').open);assert.equal(tasks[0].status,'Testing');
 await page.locator('[data-edit="'+ids[0]+'"]').first().click();await page.locator('[data-wf="done"]').click();await page.waitForFunction(()=>!document.querySelector('#task-dialog').open);assert.equal(tasks[0].status,'Done');
 await page.locator('.side [data-page="PIC contacts"]').click();await page.getByText('@raka_dev',{exact:true}).waitFor();await page.locator('[data-editpic]').click();
 await page.locator('[name="telegram_username"]').fill('@raka_engineer');await page.getByRole('button',{name:'Save PIC',exact:true}).click();await page.waitForFunction(()=>!document.querySelector('#account-dialog').open);assert.equal(requests.find(r=>r.name==='pics'&&r.b).b.telegram_username,'@raka_engineer');
 await page.locator('.side [data-page="Settings"]').click();await page.locator('[data-tg="personal"]').click();await page.getByText('/start '+'X'.repeat(32),{exact:true}).waitFor();
 // New recurring + Telegram group payload remains intact.
 await page.locator('[data-action="new"]').first().click();await page.locator('[name="title"]').fill('Recurring test');await page.locator('[name="repeat_pattern"]').selectOption('daily');await page.locator('[name="telegram_group_id"]').selectOption(G);await page.getByRole('button',{name:'Save task',exact:true}).click();await page.waitForFunction(()=>!document.querySelector('#task-dialog').open);assert.equal(requests.find(r=>r.name==='tasks'&&r.method==='POST').b.repeat_pattern,'daily');
 await page.locator('.side [data-page="Overview"]').click();await page.setViewportSize({width:390,height:844});await page.clock.fastForward(6500);await page.screenshot({path:'qa/dashboard-mobile.png',fullPage:true});
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+2),false);
 await page.locator('.sidebar-toggle').click();await page.locator('.side [data-page="PIC contacts"]').click();await page.screenshot({path:'qa/pic-mobile.png',fullPage:true});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+2),false);
 // A different PIC session must not see reviewer actions.
 sessionUser=B;tasks[0]={...tasks[0],status:'Testing',version:9};await page.setViewportSize({width:1440,height:1050});await page.reload();await page.locator('.side [data-page="Assigned to me"]').click();await page.locator('[data-edit="'+ids[0]+'"]').first().click();assert.equal(await page.locator('[data-wf="done"],[data-wf="test"],[data-wf="fail"]').count(),0);
 assert.deepEqual(errors,[]);console.log('PASS v1.4 browser: active-tab polling, live dashboard, unsaved modal protection/reload, reviewer test→done, PIC role controls, username save, pairing, recurring/group payload, desktop/mobile overflow and no JS errors.');
}finally{await browser.close();server.close();}
