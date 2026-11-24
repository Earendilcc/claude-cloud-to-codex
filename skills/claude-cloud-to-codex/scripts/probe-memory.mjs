// Local capability check with invented notes. Never opens a real Codex profile.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { withServer } from './native-chats.mjs';

function projectKey(cwd) {
  return cwd.replace(/[^a-zA-Z0-9]/g, '-');
}

function scopePath(cwd) {
  const absolute = path.resolve(cwd.replace(/^\\\\\?\\/, ''));
  return process.platform === 'win32' ? absolute.toLowerCase() : absolute;
}

async function probe(root) {
  const home = path.join(root, 'codex');
  const profile = path.join(root, 'claude-user');
  const projects = ['DemoA', 'DemoB'].map(name => {
    const cwd = path.join(root, name);
    const key = projectKey(cwd);
    const dir = path.join(profile, '.claude', 'projects', key);
    const notes = new Map([['MEMORY.md', '# '+name+'\n'], ['decision.md', '2024-04-02 '+name+' decision.\n']]);
    fs.mkdirSync(cwd);
    fs.mkdirSync(path.join(dir, 'memory'), {recursive:true});
    // An importer can recover a real cwd from session metadata. This fixture is
    // disposable and excluded from the selected migration items.
    const sessionId = randomUUID();
    fs.writeFileSync(path.join(dir, sessionId+'.jsonl'), JSON.stringify({
      type:'user', cwd, sessionId, uuid:randomUUID(), timestamp:new Date().toISOString(),
      message:{role:'user', content:'Synthetic scope fixture'}
    })+'\n');
    for (const [name, text] of notes) fs.writeFileSync(path.join(dir, 'memory', name), text);
    return {cwd, key, notes};
  });
  await withServer(home,profile,async ({rpc,imports})=>{
    const [a,b]=projects;
    const detected=await rpc('externalAgentConfig/detect',{migrationSource:'claude',includeHome:true,cwds:projects.map(p=>p.cwd)});
    const matches=detected.items.filter(i=>i.itemType==='MEMORY' && i.details?.memory?.includes(a.key));
    assert.equal(matches.length,1,'Expected a project-keyed MEMORY item.');
    const item={...matches[0],details:{...matches[0].details,memory:[a.key]}};
    async function importA() {
      const {importId}=await rpc('externalAgentConfig/import',{migrationItems:[item],migrationSource:'claude'});
      const until=Date.now()+30000;
      while(!imports.has(importId) && Date.now()<until) await new Promise(r=>setTimeout(r,50));
      const result=imports.get(importId);
      assert.ok(result,'Missing completion notification');
      const rows=result.itemTypeResults;
      assert.equal(rows.flatMap(r=>r.failures).length,0);
      const successes=rows.flatMap(r=>r.successes);
      assert.equal(successes.length,1);
      const record=successes[0];
      assert.equal(record.source,a.key);
      const target=path.resolve(record.target);
      const relative=path.relative(home,target);
      assert.ok(relative && !relative.startsWith('..') && !path.isAbsolute(relative),'Unexpected target');
      const resource=path.join(target,a.key);
      for (const [name,text] of a.notes) assert.deepEqual(fs.readFileSync(path.join(resource,name)),Buffer.from(text));
      assert.equal(scopePath(JSON.parse(fs.readFileSync(path.join(resource,'scope.json'))).cwd),scopePath(a.cwd));
      assert.equal(fs.existsSync(path.join(target,b.key)),false);
    }
    await importA();
    await importA();
    console.log('PASS: selected memory only; contents, cwd scope and repeat import verified in disposable storage.');
  },{memoryProbe:true});
}

const root=fs.mkdtempSync(path.join(os.tmpdir(),'claude-memory-probe-'));
try {await probe(root);}
catch (e) {console.error(e.message);process.exitCode=1;}
finally {fs.rmSync(root,{recursive:true,force:true,maxRetries:8,retryDelay:200});}
