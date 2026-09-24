import {readFile,writeFile,copyFile,mkdir,readdir} from 'node:fs/promises';
import {createWriteStream} from 'node:fs';import {resolve} from 'node:path';import archiver from 'archiver';
const output=resolve(process.argv[2]||'../focusdesk-v1_7-release');await mkdir(output,{recursive:true});
const files=['01_schema.sql','03_pic_reports.sql','04_recurring_tasks.sql','05_telegram_workflow.sql','07_telegram_sync_pic.sql','08_scheduled_briefings.sql','10_knowledge_desk.sql','12_ai_workspace.sql'];
const sql=await Promise.all(files.map(f=>readFile('supabase/'+f,'utf8')));
const combine=(parts,title)=>`-- ${title}\n-- Backup first. Run the ENTIRE file in Supabase SQL Editor.\nbegin;\n\n`+parts.map(s=>s.replace(/^begin;\s*$/gm,'').replace(/^commit;\s*$/gm,'')).join('\n\n')+'\ncommit;\n';
const generated={
 'Focusdesk_Supabase_v1_7.sql':combine(sql,'Focusdesk 1.7.0 FRESH INSTALL ONLY'),
 'Focusdesk_Upgrade_to_v1_7.sql':combine(sql.slice(1),'Focusdesk older versions → 1.7.0 ADDITIVE UPGRADE'),
 'Focusdesk_v1_6_to_v1_7.sql':sql.at(-1),
};
for(const [name,data] of Object.entries(generated))await writeFile(resolve(output,name),data);
await copyFile('README.md',resolve(output,'Focusdesk_README_v1_7.md'));
await copyFile('public/guide-v1-7.html',resolve(output,'Focusdesk_AI_Telegram_Guide_v1_7.html'));
await copyFile('qa/workspace-desktop.png',resolve(output,'Focusdesk_Workspace_Preview_v1_7.png'));
const stream=createWriteStream(resolve(output,'Focusdesk_Vercel_v1_7.zip')),zip=archiver('zip',{zlib:{level:9}});
const done=new Promise((ok,fail)=>{stream.on('close',ok);stream.on('error',fail);zip.on('error',fail);zip.on('warning',fail);});zip.pipe(stream);
for(const f of ['package.json','package-lock.json','vercel.json','.env.example','.gitignore','.vercelignore','README.md'])zip.file(f,{name:f});
for(const dir of ['public','api','server','supabase','tests','docs'])zip.directory(dir,dir);
for(const f of await readdir('scripts'))if(f==='build.mjs'||f==='package-v17.mjs'||f.startsWith('test-'))zip.file('scripts/'+f,{name:'scripts/'+f});
for(const f of ['workspace-desktop.png','workspace-mobile.png','ai-desktop.png','ai-mobile.png','knowledge-overview.png'])zip.file('qa/'+f,{name:'docs/screenshots/v1_7-'+f});
for(const [name,data] of Object.entries(generated))zip.append(data,{name});
await zip.finalize();await done;console.log('Focusdesk 1.7.0 release created at '+output);
