import {readFile} from 'node:fs/promises';import assert from 'node:assert/strict';import unzipper from 'unzipper';import {resolve} from 'node:path';
const folder=resolve(process.argv[2]||'release');
const archive=await unzipper.Open.file(folder+'/Focusdesk_Vercel_v1_4.zip');const names=archive.files.map(x=>x.path);
for(const f of ['README.md','package.json','api/telegram.js','api/telegram-webhook.js','api/telegram-cron.js','supabase/05_telegram_workflow.sql','supabase/06_optional_queue_worker.sql','docs/PRD.md','docs/TEST_RESULTS.md','Focusdesk_Upgrade_to_v1_4.sql'])assert.ok(names.includes(f),f);
assert.ok(!names.some(x=>/(^|\/)(node_modules|dist|\.git|qa)\//.test(x)));
assert.ok(!names.includes('.env'));assert.ok(!names.includes('.env.local'));
assert.equal(JSON.parse((await archive.files.find(x=>x.path==='package.json').buffer()).toString()).version,'1.4.0');
const full=await readFile(folder+'/Focusdesk_Supabase_v1_4.sql','utf8'),upgrade=await readFile(folder+'/Focusdesk_Upgrade_to_v1_4.sql','utf8');
for(const sql of [full,upgrade]){assert.equal((sql.match(/^begin;$/gm)||[]).length,1);assert.equal((sql.match(/^commit;$/gm)||[]).length,1);assert.ok(!sql.includes("cron.schedule('focusdesk-telegram-queue'"));}
assert.equal((await archive.files.find(x=>x.path==='Focusdesk_Upgrade_to_v1_4.sql').buffer()).toString(),upgrade);
const {PGlite}=await import(process.env.PGLITE_MODULE||'@electric-sql/pglite');const db=new PGlite();
await db.exec(`create schema auth;create role anon;create role authenticated;create role service_role bypassrls;create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb not null default '{}'::jsonb);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated,anon,service_role;`);
await db.exec(full);await db.exec(upgrade);
assert.equal((await db.query("select count(*)::int n from information_schema.tables where table_name='fd_telegram_accounts'")).rows[0].n,1);
await db.close();console.log('PASS release: archive structure/version/no env or node_modules, exact SQL bytes, single transaction, optional worker excluded, combined fresh SQL and upgrade replay execute.');
