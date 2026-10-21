const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

function fixture({switchDuringScreenshot=false, screenshotDenied=false, noGesture=false, phase='capturing'}={}) {
  const sent=[]; let listener; let tab=1;
  const chrome={
    runtime:{sendNativeMessage:async(_,event)=>{
      if(event.type==='hello') return {active:phase==='capturing',phase,cutoff:100,session:'fixture',monotonic:100};
      sent.push(event); return {ok:true,imageCaptured:!!event.screenshot};
    },onMessage:{addListener:fn=>{listener=fn;}},onInstalled:{addListener:()=>{}},onStartup:{addListener:()=>{}}},
    action:{setBadgeText:async()=>{},setBadgeBackgroundColor:async()=>{},onClicked:{addListener:()=>{}}},
    tabs:{onActivated:{addListener:()=>{}},onUpdated:{addListener:()=>{}},query:async()=>[{id:tab}],sendMessage:async()=>({documentID:'doc'}),captureVisibleTab:async()=>{
      if(noGesture && !JSON.parse(fs.readFileSync('BrowserExtension/manifest.json','utf8')).host_permissions.includes('<all_urls>')) throw Error('activeTab permission is required');
      if(screenshotDenied) throw Error("activeTab permission is required");
      await new Promise(resolve=>setTimeout(resolve,10));
      if(switchDuringScreenshot) tab=2; return 'data:image/jpeg;base64,ZmFrZQ==';
    }},
    contextMenus:{create:()=>{},onClicked:{addListener:()=>{}}}
  };
  const context=vm.createContext({chrome,Date,console,Promise,setTimeout});
  vm.runInContext(fs.readFileSync('BrowserExtension/background.js','utf8'),context);
  const sender={tab:{id:1,windowId:7,url:'https://example.com'},documentId:'chrome-doc'};
  const event=(kind,content)=>({kind,content,label:content,type:'selection',documentID:'doc',session:'fixture',source:'https://example.com',wallTime:Date.now()-500});
  const send=event=>new Promise(resolve=>listener(event,sender,resolve));
  return {sent,event,send};
}

test('图片截图来源变化时不把新标签图像当成旧素材',async()=>{
  const f=fixture({switchDuringScreenshot:true}); await f.send(f.event('image','old-image'));
  assert.equal(f.sent.length,1); assert.equal(f.sent[0].screenshot,undefined); assert.ok(f.sent[0].imageNote.includes('无法确认'));
});
test('慢截图之后的文字选区按发送次序处理',async()=>{
  const f=fixture(); await Promise.all([f.send(f.event('image','A')),f.send(f.event('text','B'))]);
  assert.deepEqual(f.sent.filter(x=>x.type==='selection').map(x=>x.content),['A','B']);
});
test('结束后仍接纳截止前已发出的消息',async()=>{
  const f=fixture({phase:'finalizing'}); await f.send(f.event('text','before-cutoff'));
  assert.ok(f.sent.some(x=>x.content==='before-cutoff'));
});
test('截止后新事件不能混入旧会话',async()=>{
  const f=fixture({phase:'finalizing'}); const event=f.event('text','after-cutoff'); event.wallTime=Date.now()+1000;
  await f.send(event); assert.equal(f.sent.filter(x=>x.type==='selection').length,0);
});

test('图片仅保存链接时向页面明确返回截图失败，不能显示完整成功',async()=>{
  const f=fixture({screenshotDenied:true}); const reply=await f.send(f.event('image','image-url'));
  assert.equal(reply.ok,true); assert.equal(reply.imageCaptured,false);
  assert.match(reply.warning,/activeTab/);
});

test('图片成功写入后页面可明确显示完整采集成功',async()=>{
  const f=fixture(); const reply=await f.send(f.event('image','image-url'));
  assert.equal(reply.ok,true); assert.equal(reply.imageCaptured,true); assert.equal(reply.warning,'');
});

test('新标签页未点击工具栏图标也能采集图片',async()=>{
  const f=fixture({noGesture:true}); const reply=await f.send(f.event('image','new-tab-image'));
  assert.equal(reply.imageCaptured,true); assert.equal(reply.warning,'');
});

test('拖选起点映射到和语音一致的时钟，不能使用确认返回时间',async()=>{
  const f=fixture();const event=f.event('text','Clash Verge');
  event.selectionID='drag-1';event.selectionStartedAt=event.wallTime-300;event.selectionComplete=true;
  await f.send(event);const captured=f.sent.find(x=>x.type==='selection');
  assert.equal(captured.selectionID,'drag-1');
  assert.equal(captured.selectionComplete,true);
  assert.ok(Math.abs(captured.occurredAt-captured.selectionStart-0.3)<0.00001);
});
