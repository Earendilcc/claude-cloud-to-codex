import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import readline from 'node:readline';
import {spawn} from 'node:child_process';
import {isDeepStrictEqual} from 'node:util';
import {fileURLToPath,pathToFileURL} from 'node:url';

const check = (ok, message) => { if (!ok) throw Error(message); };
const hash = data => crypto.createHash('sha256').update(data).digest('hex');
const json = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
const key = p => process.platform === 'win32'
  ? path.resolve(p).replace(/^\\\\\?\\/, '').toLowerCase() : path.resolve(p);
const absolute = p => typeof p === 'string' && path.isAbsolute(p);
const within = (p, dir) => key(p) === key(dir) || key(p).startsWith(key(dir) + path.sep);
function plannedPath(p) {
  let existing=path.resolve(p);
  const suffix=[];
  while(!fs.existsSync(existing)) {
    suffix.unshift(path.basename(existing));
    const parent=path.dirname(existing);
    check(parent!==existing,'Cannot locate a parent for the staging directory.');
    existing=parent;
  }
  return path.join(fs.realpathSync(existing),...suffix);
}
function checkLocalStoreConfig(home) {
  const config=path.join(home,'config.toml');
  if(!fs.existsSync(config))return;
  const text=fs.readFileSync(config,'utf8');
  // Handle ordinary quoted TOML strings. Fail closed on multiline, dotted or
  // computed forms instead of guessing where a custom installation keeps state.
  for(const line of text.split(/\r?\n/)){
    if(!/^[^#]*\bsqlite_home\b[^#]*=/.test(line))continue;
    const m=line.match(/^\s*sqlite_home\s*=\s*(?:"((?:\\.|[^"\\])*)"|'([^']*)')\s*(?:#.*)?$/);
    check(m,'Cannot establish the configured SQLite destination in config.toml.');
    const dir=m[1]===undefined ? m[2] : JSON.parse('"'+m[1]+'"');
    check(absolute(dir) && key(plannedPath(dir))===key(home),'Custom SQLite destination in config.toml differs from the explicit Codex home.');
  }
}
const sourceType = 'external_conversation_source';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function uuid(seed) {
  const bytes = Buffer.from(hash(seed).slice(0, 32), 'hex');
  bytes[6] = (bytes[6] & 15) | 80;
  bytes[8] = (bytes[8] & 63) | 128;
  const s = bytes.toString('hex');
  return [s.slice(0,8), s.slice(8,12), s.slice(12,16), s.slice(16,20), s.slice(20)].join('-');
}

function conversations(manifest) {
  check(manifest.version === 1 && Array.isArray(manifest.projects) && manifest.projects.length, 'Expected a version 1 manifest with projects.');
  const results = [], seen = new Set(), projectIds = new Set(), roots = new Set();
  for (const p of manifest.projects) {
    check(absolute(p.root) && fs.statSync(p.root).isDirectory(), 'Project root must be an existing absolute directory.');
    check(typeof p.sourceId === 'string' && p.sourceId.trim() && !projectIds.has(p.sourceId), 'Missing or duplicate source project ID.');
    projectIds.add(p.sourceId);
    check(Array.isArray(p.chats) && p.chats.length, 'No chats selected.');
    const root = fs.realpathSync(p.root);
    check(!roots.has(key(root)), 'Two source projects point to the same destination root.');
    roots.add(key(root));
    for (const c of p.chats) {
      check(typeof c.sourceId === 'string' && c.sourceId.trim() && typeof c.title === 'string' && c.title.trim(), 'Missing conversation ID or title.');
      const identity = 'claude-cloud/' + encodeURIComponent(p.sourceId) + '/' + encodeURIComponent(c.sourceId);
      check(!seen.has(identity), 'Duplicate source identity.');
      seen.add(identity);
      check(Array.isArray(c.messages) && c.messages.length, 'No verified messages in a conversation.');
      for (const m of c.messages) {
        check(['user','assistant'].includes(m.role) && typeof m.text === 'string' && m.text.length, 'Expected an attributed, nonempty text item.');
        if (m.timestamp !== undefined) check(typeof m.timestamp === 'string' && /^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(m.timestamp) && Number.isFinite(Date.parse(m.timestamp)), 'Use a dated timestamp with an explicit offset, or omit it.');
        if (m.meta !== undefined) check(m.meta !== null && typeof m.meta === 'object' && !Array.isArray(m.meta), 'Message metadata must be an object.');
      }
      if (c.sourceUrl !== undefined) check(typeof c.sourceUrl === 'string', 'Invalid source URL.');
      results.push({...c, root, projectSource:p.sourceId, identity});
    }
  }
  return results;
}

function serverEnvironment(home, profile) {
  // Explicit allowlist: a parent process may have an alternate account, database
  // location, plugin socket or remote agent endpoint in its environment.
  const forwarded = new Set(['PATH','PATHEXT','SYSTEMROOT','WINDIR','SYSTEMDRIVE','COMSPEC',
    'NUMBER_OF_PROCESSORS','PROCESSOR_ARCHITECTURE','LANG','LC_ALL','LC_CTYPE','TZ',
    'CODEX_SANDBOX_NETWORK_DISABLED']);
  const env = Object.fromEntries(Object.entries(process.env).filter(([k])=>forwarded.has(k.toUpperCase())));
  Object.assign(env,{CODEX_HOME:home, CODEX_SQLITE_HOME:home, HOME:profile, USERPROFILE:profile,
    CLAUDE_CONFIG_DIR:path.join(profile,'.claude'), APPDATA:path.join(profile,'roaming'),
    LOCALAPPDATA:path.join(profile,'local'), XDG_CONFIG_HOME:path.join(profile,'config'),
    XDG_DATA_HOME:path.join(profile,'data'), XDG_STATE_HOME:path.join(profile,'state'),
    XDG_CACHE_HOME:path.join(profile,'cache'), XDG_RUNTIME_DIR:path.join(profile,'runtime'),
    TMPDIR:path.join(profile,'tmp'), TEMP:path.join(profile,'tmp'), TMP:path.join(profile,'tmp')});
  for (const dir of [env.TEMP,env.XDG_RUNTIME_DIR,env.APPDATA,env.LOCALAPPDATA])fs.mkdirSync(dir,{recursive:true,mode:0o700});
  return env;
}
export async function withServer(home, profile, run, {memoryProbe=false}={}) {
  fs.mkdirSync(home, {recursive:true, mode:0o700});
  fs.mkdirSync(profile, {recursive:true, mode:0o700});
  const exe = process.env.CODEX_BIN || 'codex';
  if (process.env.CODEX_BIN) check(absolute(exe), 'CODEX_BIN must be the absolute path to a trusted Codex executable.');
  const logDir=path.join(profile,'logs');
  const flags = memoryProbe ? ['--enable','external_agent_memory_import'] : [];
  const child = spawn(exe, [...flags,'app-server','--stdio','-c','sqlite_home='+JSON.stringify(home),'-c','log_dir='+JSON.stringify(logDir)], {
    windowsHide:true,cwd:profile,env:serverEnvironment(home,profile),stdio:['pipe','pipe','pipe']});
  const pending = new Map(), imports = new Map();
  let sequence = 0, dead;
  const stop = e => {
    dead = e;
    for (const p of pending.values()) p.reject(e);
    pending.clear();
  };
  child.on('error', stop);
  child.on('exit', code => stop(Error('Codex app-server exited: ' + code)));
  child.stdin.on('error', stop);
  child.stderr.resume();
  readline.createInterface({input:child.stdout}).on('line', line => {
    let packet; try { packet = JSON.parse(line); } catch { return; }
    const reply = pending.get(packet.id);
    if (reply) {
      pending.delete(packet.id);
      if (packet.error) reply.reject(Error(reply.method + ': ' + packet.error.message));
      else reply.resolve(packet.result);
    } else if (packet.method === 'externalAgentConfig/import/completed') imports.set(packet.params.importId, packet.params);
  });
  const rpc = (method, params) => new Promise((resolve,reject) => {
    if (dead) return reject(dead);
    const id = ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(Error(method + ' timed out. Inspect any pending native operation before retry.')); }, 60000);
    pending.set(id, {method,resolve:v=>{clearTimeout(timer);resolve(v);},reject:e=>{clearTimeout(timer);reject(e);}});
    child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params}) + '\n');
  });
  const closed = new Promise(resolve => child.once('close',resolve));
  try {
    const init = await rpc('initialize', {clientInfo:{name:'claude-cloud-to-codex',version:'1'},capabilities:{experimentalApi:true}});
    check(key(init.codexHome) === key(home), 'App server opened the wrong Codex home.');
    child.stdin.write('{"jsonrpc":"2.0","method":"initialized"}\n');
    const effective=(await rpc('config/read',{includeLayers:false})).config;
    check(typeof effective.sqlite_home==='string' && key(effective.sqlite_home)===key(home),'Unable to verify the effective SQLite destination.');
    check(typeof effective.log_dir==='string' && key(effective.log_dir)===key(logDir),'Unable to verify the effective log destination.');
    const policy=(await rpc('configRequirements/read',{})).requirements;
    if(policy?.sqliteHome)check(key(fileURLToPath(policy.sqliteHome))===key(home),'Managed SQLite location differs from the requested destination.');
    return await run({rpc,imports,profile,home});
  } finally {
    child.stdin.end();
    child.kill();
    await closed;
  }
}

async function resolveProjects(server, entries, isolated) {
  const ids = new Map();
  for (const dir of new Set(entries.map(c=>c.root))) {
    if (isolated) {
      const r = await server.rpc('project/create',{name:'Migration rehearsal '+hash(dir).slice(0,8),roots:[{path:dir}],idempotencyKey:uuid(dir)});
      ids.set(dir,r.project.id);
      continue;
    }
    const matches = [];
    let cursor;
    do {
      const page = await server.rpc('project/list',{cursor,limit:100});
      matches.push(...page.data.filter(p=>p.roots.some(r=>key(r.path)===key(dir))));
      cursor = page.nextCursor;
    } while (cursor);
    check(matches.length === 1, 'Expected exactly one existing Codex project for ' + dir);
    const r = await server.rpc('project/read',{projectId:matches[0].id});
    check(r.project.roots.some(root=>key(root.path)===key(dir)), 'Project root changed during preflight.');
    ids.set(dir,r.project.id);
  }
  return ids;
}

function verify(thread, entry) {
  check(key(thread.cwd)===key(entry.root),'Incorrect native workspace.');
  const items = thread.turns.flatMap(t=>t.items);
  // Only disregard an additional native import marker after all source messages.
  if (items.length===entry.messages.length+1 && items.at(-1).type==='agentMessage' && items.at(-1).text==='<EXTERNAL SESSION IMPORTED>') items.pop();
  check(items.length===entry.messages.length, 'Source/native message count differs.');
  for (const [i,item] of items.entries()) {
    const m = entry.messages[i];
    const user = item.type==='userMessage' && item.content.every(c=>c.type==='text');
    const text = user ? item.content.map(c=>c.text).join('') : item.text;
    const role = user ? 'user' : item.type==='agentMessage' ? 'assistant' : null;
    check(role===m.role && text===m.text,'Native role/text differs at source index '+(i+1));
  }
}

async function standardImport(server, entry, label) {
  const sessionId = uuid(entry.identity+'/'+label);
  let parentUuid = null;
  const lines = entry.messages.map((m,i) => {
    const id=uuid(sessionId+'/'+i);
    const row={type:m.role,message:{role:m.role,content:[{type:'text',text:m.text}]},uuid:id,parentUuid,sessionId,cwd:entry.root,isSidechain:false};
    if(m.timestamp)row.timestamp=m.timestamp;
    parentUuid=id;
    return JSON.stringify(row);
  });
  const dir=path.join(server.profile,'.claude','projects',entry.root.replace(/[^a-zA-Z0-9]/g,'-'));
  fs.mkdirSync(dir,{recursive:true,mode:0o700});
  const file=path.join(dir,sessionId+'.jsonl');
  const bytes=lines.join('\n')+'\n';
  if(fs.existsSync(file))check(fs.readFileSync(file,'utf8')===bytes,'Staged transcript changed.');
  else fs.writeFileSync(file,bytes,{flag:'wx', mode:0o600});
  // Pass exactly one checked session. Never submit a full discovered migration
  // item, which could also select other projects, skills, hooks or settings.
  const details={sessions:[{path:file,cwd:entry.root,title:entry.title}],skills:[],commands:[],mcpServers:[],subagents:[],hooks:[],plugins:[]};
  const result=await server.rpc('externalAgentConfig/import',{migrationSource:'claude',source:'Claude project chats',migrationItems:[{itemType:'SESSIONS',description:entry.title,cwd:entry.root,details}]});
  const deadline=Date.now()+120000;
  while(!server.imports.has(result.importId) && Date.now()<deadline)await sleep(100);
  const done=server.imports.get(result.importId);
  check(done,'Native completion not received. Reconcile the import ledger before retry.');
  const hits=done.itemTypeResults.flatMap(r=>r.successes);
  check(!done.itemTypeResults.some(r=>r.failures.length) && hits.length===1 && typeof hits[0].source==='string' && key(hits[0].source)===key(file) && hits[0].target, 'No unique native receipt for the selected session; check the native ledger.');
  return hits[0].target;
}

async function convertAssistantFirst(server, entry, temp) {
  const marker = 'Temporary migration starter ' + crypto.randomUUID();
  check(!entry.messages.some(m=>m.text.includes(marker)), 'Temporary marker collision.');
  const padded={...entry,messages:[{role:'user',text:marker},...entry.messages]};
  const id=await standardImport(server,padded,'assistant-conversion');
  const t=(await server.rpc('thread/read',{threadId:id,includeTurns:true})).thread;
  verify(t,padded);
  check(within(t.path,server.home),'Converter returned a path outside the isolated store.');
  const parent=uuid(entry.identity+'/converted-parent');
  const rows=[],removed={event_msg:0,response_item:0};
  let metaCount=0;
  for(const line of fs.readFileSync(t.path,'utf8').split('\n').filter(Boolean)) {
    const r=JSON.parse(line), v=r.payload;
    if(JSON.stringify(r).includes(marker)) {
      const userEvent = r.type==='event_msg' && (v.type==='user_message'||v.item?.type==='UserMessage');
      const userItem = r.type==='response_item' && v.role==='user';
      check(userEvent || userItem,'Unknown starter representation from this Codex build.');
      removed[r.type]++;
      continue;
    }
    if(r.type==='session_meta') {
      check(v.id===id,'Unexpected conversion metadata.');
      metaCount++; v.id=parent;
      if(v.session_id===id)v.session_id=parent;
    }
    if(v?.thread_id===id)v.thread_id=parent;
    rows.push(JSON.stringify(r));
  }
  check(metaCount===1 && removed.event_msg===1 && removed.response_item===1,'Codex rollout format changed; preserve source and stop.');
  const file=path.join(temp,parent+'.jsonl');
  fs.writeFileSync(file,rows.join('\n')+'\n',{flag:'wx',mode:0o600});
  return {threadId:parent,path:file,cwd:entry.root};
}
async function owner(server,entry) {
  const page=await server.rpc('thread/attachmentOwner/list',{attachmentType:sourceType,identityKey:entry.identity,limit:2});
  check(!page.nextCursor && page.data.length<=1,'Multiple native chats claim the same source ID.');
  return page.data[0]?.threadId;
}
function provenance(entry) {
  return {provider:'Claude',sourceProject:entry.projectSource,sourceId:entry.sourceId,sourceUrl:entry.sourceUrl??null,
    messages:entry.messages.map((m,i)=>({index:i+1,...(m.timestamp?{timestamp:m.timestamp}:{}),...(m.meta?{meta:m.meta}:{})}))};
}
async function bind(server,id,entry,projectId,prior) {
  const read=async()=>{
    const thread=(await server.rpc('thread/read',{threadId:id,includeTurns:true})).thread;
    check(absolute(thread.path) && within(fs.realpathSync(thread.path),server.home),'Native transcript was written outside the selected store.');
    return thread;
  };
  let t=await read();
  verify(t,entry);
  const payload=provenance(entry);
  if (!prior) {
    await server.rpc('thread/attachment/add',{threadId:id,attachmentType:sourceType,identityKey:entry.identity,payload});
    if (t.name!==entry.title) await server.rpc('thread/name/set',{threadId:id,name:entry.title});
    if (t.projectId!==projectId) await server.rpc('thread/metadata/update',{threadId:id,projectId});
  }
  const page=await server.rpc('thread/attachment/list',{threadId:id,limit:100});
  const attachment=page.data.find(a=>a.attachmentType===sourceType && a.identityKey===entry.identity);
  check(isDeepStrictEqual(attachment?.payload,payload),'Source metadata differs from the saved native binding.');
  check(await owner(server,entry)===id,'Native reverse lookup failed.');
  t=await read();
  verify(t,entry);
  check(t.name===entry.title && t.projectId===projectId,'Native name/project mismatch. Review the existing chat.');
}

async function importSelected(server, entries, converted, isolated) {
  const ids=await resolveProjects(server,entries,isolated);
  const result=[];
  async function existing(entry) {
    const prior=await owner(server,entry);
    if(isolated || !entry.existingThreadId)return {prior,id:prior};
    if(prior) {
      check(prior===entry.existingThreadId,'Conflicting explicit native chat ID.');
      return {prior,id:prior};
    }
    const r=await server.rpc('thread/read',{threadId:entry.existingThreadId,includeTurns:true});
    check(absolute(r.thread.path) && within(fs.realpathSync(r.thread.path),server.home),'Explicit native chat lives outside the selected store.');
    verify(r.thread,entry);
    check(r.thread.projectId===ids.get(entry.root),'Explicit existing chat belongs to another project.');
    const previous=await server.rpc('thread/attachment/list',{threadId:entry.existingThreadId,limit:100});
    check(!previous.nextCursor && !previous.data.some(a=>a.attachmentType===sourceType),'Explicit chat already has a source binding.');
    return {prior,id:entry.existingThreadId};
  }
  if(!isolated) {
    // Read back every previously bound source before making any new chat.
    const reused=new Set();
    for(const entry of entries) {
      check(!fs.existsSync(path.join(server.home,'.claude-cloud-import-'+hash(entry.identity)+'.lock')), 'A source has a pending import. Inspect its checkpoint before retry.');
      const {prior,id}=await existing(entry);
      if(id){check(!reused.has(id),'Multiple source chats target the same native thread.');reused.add(id);}
      if(prior)await bind(server,prior,entry,ids.get(entry.root),true);
    }
  }
  for (const entry of entries) {
    const projectId=ids.get(entry.root);
    // Atomic and source-specific, shared even if another process uses different staging.
    // Keep the marker after an ambiguous import to prevent duplicate retries.
    const lock=path.join(server.home,'.claude-cloud-import-'+hash(entry.identity)+'.lock');
    let fd;
    try { fd=fs.openSync(lock,'wx',0o600); }
    catch(e){ if(e.code!=='EEXIST')throw e; throw Error('Import already in progress or needs reconciliation: '+lock); }
    fs.closeSync(fd);
    const writeReceipt=record=>fs.writeFileSync(lock,JSON.stringify({source:entry.identity,...record}),{mode:0o600});
    let mutationStarted=false, complete=false;
    try {
      writeReceipt({state:'preflight'});
      const state=await existing(entry);
      const prior=state.prior;
      let id=state.id;
      if(!prior) {
        writeReceipt({state:'started',nativeId:id??null});
        mutationStarted=true;
        if(!id) {
          const src=converted.get(entry.identity);
          id=src ? (await server.rpc('thread/fork',src)).thread.id : await standardImport(server,entry,'direct');
        }
        writeReceipt({state:'received',nativeId:id});
      }
      await bind(server,id,entry,projectId,!!prior);
      complete=true;
      result.push({sourceProject:entry.projectSource,sourceId:entry.sourceId,nativeId:id,messages:entry.messages.length});
    } finally { if(complete || !mutationStarted) fs.unlinkSync(lock); }
  }
  return result;
}

async function main() {
  const [mode,file,stageArg,homeArg,...extra]=process.argv.slice(2);
  check(!extra.length && ((mode==='verify' && file && !stageArg && !homeArg)||(mode==='apply' && file && absolute(stageArg) && absolute(homeArg))), 'Usage: node native-chats.mjs verify MANIFEST | apply MANIFEST ABS_PRIVATE_STAGE ABS_EXISTING_CODEX_HOME');
  const entries=conversations(json(file));
  let liveHome,stage;
  if(mode==='apply') {
    liveHome=fs.realpathSync(homeArg);
    const expected=process.env.CODEX_HOME || path.join(os.homedir(),'.codex');
    check(key(fs.realpathSync(expected))===key(liveHome),'Explicit Codex home must match the active host.');
    const sqlite=process.env.CODEX_SQLITE_HOME;
    check(!sqlite || (absolute(sqlite) && key(plannedPath(sqlite))===key(liveHome)),'Custom CODEX_SQLITE_HOME differs from the explicit target. Verify the intended store independently.');
    const unknown=Object.keys(process.env).filter(k=>k.toUpperCase()!=='CODEX_SQLITE_HOME' && /^CODEX_.*(SQLITE|STORAGE|STATE_DB|STATE_DIR|DATA_DIR|CONFIG_DIR|SESSIONS_DIR|PROFILE_DIR)/i.test(k));
    check(!unknown.length,'Unverified Codex storage override: '+unknown.join(', '));
    checkLocalStoreConfig(liveHome);
    stage=plannedPath(stageArg);
    check(!within(stage,liveHome) && !within(liveHome,stage) && entries.every(e=>!within(stage,e.root) && !within(e.root,stage)), 'Use a dedicated private staging folder outside Codex home and project roots.');
    fs.mkdirSync(stage,{recursive:true,mode:0o700});
    check(key(fs.realpathSync(stage))===key(stage),'Staging directory changed during preflight.');
    const sentinel=path.join(stage,'.claude-cloud-stage');
    if(!fs.existsSync(sentinel)) {
      check(fs.readdirSync(stage).length===0,'Private staging directory must be empty on first use.');
      fs.writeFileSync(sentinel,'claude-cloud-to-codex/v1\n',{flag:'wx',mode:0o600});
    }
    check(fs.readFileSync(sentinel,'utf8')==='claude-cloud-to-codex/v1\n','Invalid private stage.');
  }
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),'claude-codex-check-'));
  try {
    const converted=new Map();
    if(entries.some(e=>e.messages[0].role==='assistant')) {
      await withServer(path.join(temp,'converter'),path.join(temp,'converter-profile'),async server=>{
        for(const e of entries.filter(x=>x.messages[0].role==='assistant')) converted.set(e.identity,await convertAssistantFirst(server,e,temp));
      });
    }
    await withServer(path.join(temp,'codex'),path.join(temp,'profile'),async server=>{
      const first=await importSelected(server,entries,converted,true);
      const second=await importSelected(server,entries,converted,true);
      check(isDeepStrictEqual(first,second),'Repeated isolated import produced different IDs.');
      console.log('Isolated round-trip verified:',entries.length,'chats,',entries.reduce((n,c)=>n+c.messages.length,0),'source records.');
    });
    if(mode==='apply') {
      const out=await withServer(liveHome,path.join(stage,'profile'),s=>importSelected(s,entries,converted,false));
      // The desktop sidebar has its own project IDs. Bind and re-read there next.
      console.log(JSON.stringify(out));
    }
  } finally {
    check(key(path.dirname(temp))===key(os.tmpdir()) && path.basename(temp).startsWith('claude-codex-check-'),'Unexpected temporary root.');
    fs.rmSync(temp,{recursive:true,force:true,maxRetries:5,retryDelay:250});
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(e=>{console.error(e.message);process.exitCode=1;});
}
