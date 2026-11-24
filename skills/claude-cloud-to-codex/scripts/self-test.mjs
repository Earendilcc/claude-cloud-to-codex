import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {withServer} from './native-chats.mjs';

// Uses the installed executable with a throwaway Codex home, including the apply path.
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-codex-example-'));
const home = path.join(temp,'store'), profile = path.join(temp,'empty-profile');
const stage = path.join(temp,'private-stage'), manifest = path.join(temp,'example.json');
const script = fileURLToPath(new URL('native-chats.mjs', import.meta.url));
const roleText=(role,text)=>({role,text});
try {
  const projects = ['lake','hill'].map(sourceId=>({sourceId,root:path.join(temp,sourceId),chats:[]}));
  for(const p of projects) fs.mkdirSync(p.root);
  projects[0].chats.push(
    {sourceId:'discussion',title:'路线',messages:[{role:'user',text:'第一段\n\n第二段。  ',timestamp:'2026-03-01T09:40:00+08:00',meta:{precision:'minute'}},roleText('assistant','收到'),roleText('assistant','继续'),roleText('user','结束。')]},
    {sourceId:'assistant-only',title:'讨论',messages:[roleText('assistant','提案'),{role:'assistant',text:'【Claude 历史界面记录】\n暂停',meta:{kind:'interface'}}]});
  projects[1].chats.push(
    {sourceId:'discussion',title:'路线',messages:[roleText('assistant','开始'),roleText('user','请继续'),roleText('assistant','完成。')]},
    {sourceId:'one',title:'单条',messages:[roleText('user','文字。')]});
  fs.writeFileSync(manifest,JSON.stringify({version:1,projects}));
  const sentinel=path.join(temp,'unrelated-personal-store');
  fs.mkdirSync(sentinel);
  const sentinelFile=path.join(sentinel,'untouched.txt');
  fs.writeFileSync(sentinelFile,'unrelated\n');
  const privateEnv={...process.env,CODEX_HOME:home,HOME:profile,USERPROFILE:profile,
    CLAUDE_CONFIG_DIR:sentinel, XDG_STATE_HOME:sentinel, XDG_DATA_HOME:sentinel,
    XDG_CACHE_HOME:sentinel,XDG_CONFIG_HOME:sentinel,APPDATA:sentinel,LOCALAPPDATA:sentinel};
  function run(args,extraEnv={}) {
    const run=spawnSync(process.execPath,[script,...args],{
      env:{...privateEnv,CODEX_SQLITE_HOME:home,...extraEnv},encoding:'utf8',windowsHide:true});
    if(run.error)throw run.error;
    return run;
  }
  const rehearsal=run(['verify',manifest],{CODEX_SQLITE_HOME:sentinel});
  assert.equal(rehearsal.status,0,rehearsal.stderr);
  assert.deepEqual(fs.readdirSync(sentinel),['untouched.txt']);
  assert.equal(fs.existsSync(home),false);
  await withServer(home,profile,async s=>{
    for(const p of projects) await s.rpc('project/create',{name:p.sourceId,roots:[{path:p.root}],idempotencyKey:p.sourceId});
  });
  function apply(expectSuccess) {
    const result=run(['apply',manifest,stage,home]);
    if(!expectSuccess){assert.notEqual(result.status,0);return result.stderr;}
    assert.equal(result.status,0,result.stderr);
    return JSON.parse(result.stdout.trim().split('\n').at(-1));
  }
  const wrongDb=run(['apply',manifest,stage,home],{CODEX_SQLITE_HOME:sentinel});
  assert.notEqual(wrongDb.status,0);
  assert.match(wrongDb.stderr,/Custom CODEX_SQLITE_HOME/);
  const unknownStore=run(['apply',manifest,stage,home],{CODEX_STATE_DB_PATH:sentinel});
  assert.notEqual(unknownStore.status,0);
  assert.match(unknownStore.stderr,/Unverified Codex storage override/);
  assert.equal(fs.existsSync(stage),false);
  const secondRoot=projects[1].root;
  projects[1].root=projects[0].root;
  fs.writeFileSync(manifest,JSON.stringify({version:1,projects}));
  assert.match(apply(false),/same destination root/);
  projects[1].root=secondRoot;
  fs.writeFileSync(manifest,JSON.stringify({version:1,projects}));
  const first=apply(true), repeat=apply(true);
  assert.deepEqual(first,repeat);
  assert.equal(new Set(first.map(r=>r.nativeId)).size,4);
  assert.equal(new Set(first.filter(r=>r.sourceId==='discussion').map(r=>r.sourceProject)).size,2);
  projects[0].chats[0].messages[0].text='Edited source.';
  fs.writeFileSync(manifest,JSON.stringify({version:1,projects}));
  assert.match(apply(false),/differs at source index/);
  assert.deepEqual(fs.readdirSync(sentinel),['untouched.txt']);
  assert.equal(fs.readFileSync(sentinelFile,'utf8'),'unrelated\n');
  console.log('PASS: 4 fictional chats, 10 items, repeat import, cross-project IDs, destination conflicts and isolated storage overrides. All writes used disposable stores.');
} finally {
  assert.equal(path.dirname(temp),os.tmpdir());
  assert.ok(path.basename(temp).startsWith('claude-codex-example-'));
  fs.rmSync(temp,{recursive:true,force:true,maxRetries:5,retryDelay:250});
}
