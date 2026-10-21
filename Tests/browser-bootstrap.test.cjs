const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

function fixture({ready=false, denied=false}={}) {
  const hooks={}, injected=[];
  const chrome={
    runtime:{onMessage:{addListener:()=>{}},onInstalled:{addListener:fn=>hooks.installed=fn},onStartup:{addListener:fn=>hooks.startup=fn}},
    action:{onClicked:{addListener:()=>{}}},
    contextMenus:{create:()=>{},onClicked:{addListener:()=>{}}},
    tabs:{query:async()=>[{id:7,url:'https://example.com/old'}],get:async()=>({id:7,url:'https://example.com/old'}),
      onActivated:{addListener:fn=>hooks.activated=fn},onUpdated:{addListener:fn=>hooks.updated=fn},
      sendMessage:async()=>{ if(ready) return {documentID:'existing'}; throw Error('Receiving end does not exist'); }},
    scripting:{executeScript:async options=>{if(denied) throw Error('denied'); injected.push(options);ready=true;}}
  };
  vm.runInNewContext(fs.readFileSync('BrowserExtension/background.js','utf8'),{chrome,console,Date,Promise,Map});
  return {hooks,injected};
}

test('更新扩展后自动给旧标签页补采集脚本，不要求刷新网页',async()=>{
  const f=fixture(); await f.hooks.installed();
  assert.equal(f.injected.length,1);
  assert.equal(f.injected[0].target.tabId,7);
  assert.deepEqual(Array.from(f.injected[0].files),['content.js']);
});
test('已经有采集脚本的标签页不重复安装监听器',async()=>{
  const f=fixture({ready:true}); await f.hooks.installed();
  assert.equal(f.injected.length,0);
});
test('切回缺少脚本的旧标签页时自动恢复',async()=>{
  const f=fixture(); assert.equal(typeof f.hooks.activated,'function');
  await f.hooks.activated({tabId:7}); assert.equal(f.injected.length,1);
});
test('权限或特殊页面拒绝注入时不会产生未处理异常',async()=>{
  const f=fixture({denied:true}); await f.hooks.installed();
  assert.equal(f.injected.length,0);
});
