import {readFile,writeFile,copyFile,mkdir,readdir} from 'node:fs/promises';
import {createWriteStream} from 'node:fs';import {resolve} from 'node:path';import archiver from 'archiver';
const output=resolve(process.argv[2]||'release');await mkdir(output,{recursive:true});
const schema=['01_schema.sql','03_pic_reports.sql','04_recurring_tasks.sql','05_telegram_workflow.sql'];
const sql=await Promise.all(schema.map(f=>readFile('supabase/'+f,'utf8')));
// One transaction, including all migration parts; do not leave an incomplete upgrade.
const combine=(parts,title)=>`-- ${title}\n-- Backup first. Run the ENTIRE file in Supabase SQL Editor.\nbegin;\n\n`+parts.map(s=>s.replace(/^begin;\s*$/gm,'').replace(/^commit;\s*$/gm,'')).join('\n\n')+'\ncommit;\n';
const full=combine(sql,'Focusdesk v1.3.0 FRESH INSTALL ONLY'),upgrade=combine(sql.slice(1),'Focusdesk v1.0/v1.1/v1.2 → v1.3.0 ADDITIVE UPGRADE');
const fullName='Focusdesk_Supabase_v1_3.sql',upgradeName='Focusdesk_Upgrade_to_v1_3.sql';
await writeFile(resolve(output,fullName),full);await writeFile(resolve(output,upgradeName),upgrade);
await copyFile('README.md',resolve(output,'Focusdesk_README_v1_3.md'));
const stream=createWriteStream(resolve(output,'Focusdesk_Vercel_v1_3.zip')),zip=archiver('zip',{zlib:{level:9}});
const done=new Promise((ok,fail)=>{stream.on('close',ok);stream.on('error',fail);zip.on('error',fail);zip.on('warning',fail)});zip.pipe(stream);
for(const f of ['package.json','package-lock.json','vercel.json','.env.example','.gitignore','.vercelignore','README.md'])zip.file(f,{name:f});
for(const f of ['public','api','server','supabase','tests'])zip.directory(f,f);
for(const f of await readdir('scripts'))if(f==='build.mjs'||f==='package-release.mjs'||f.startsWith('test-'))zip.file('scripts/'+f,{name:'scripts/'+f});
for(const f of ['PRD','ARCHITECTURE','USER_GUIDE','TEST_RESULTS'])zip.file('docs/'+f+'.md',{name:'docs/'+f+'.md'});
zip.append(full,{name:fullName});zip.append(upgrade,{name:upgradeName});
await zip.finalize();await done;console.log('Created Focusdesk v1.3.0 ZIP, full SQL, additive upgrade SQL and README in '+output);
