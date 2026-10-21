const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

test('刚开始表达的第一个选区立即刷新状态，防抖不改变发生时刻', async () => {
  let capturing = false, now = 1000;
  const handlers = {}, timers = [], sent = [];
  const document = {
    visibilityState: 'visible', title: 'fixture', hasFocus: () => true,
    addEventListener: (event, fn) => { handlers[event] = fn; }, querySelectorAll: () => [],
    documentElement: {append: () => {}}, createElement: () => ({style: {}, remove: () => {}})
  };
  const context = vm.createContext({document, window: {addEventListener: () => {}},
    location: {href: 'https://example.com'}, crypto: {randomUUID: () => 'doc'},
    Date: {now: () => now}, innerWidth: 800, innerHeight: 600, scrollX: 0, scrollY: 0, devicePixelRatio: 2,
    getSelection: () => ({toString: () => '所选文字',getRangeAt: () => ({getBoundingClientRect: () => ({x:0,y:0,width:50,height:20})})}),
    setTimeout: fn => { timers.push(fn); return timers.length; }, clearTimeout: () => {}, setInterval: () => {},
    chrome: {runtime: {onMessage: {addListener: () => {}}, sendMessage: async event => {
      if (event.type === 'status') return {active: capturing, session: 'session'};
      sent.push(event); return {ok: true};
    }}}
  });
  vm.runInContext(fs.readFileSync('BrowserExtension/content.js','utf8'), context);
  await new Promise(resolve => setImmediate(resolve));
  capturing = true;
  handlers.selectionchange(); now = 1040;
  await timers.shift()();
  assert.equal(sent.length, 1);
  assert.equal(sent[0].selectedText, '所选文字');
  assert.equal(sent[0].wallTime, 1000);
});

for (const firstFailure of ['negative-ack','disconnected']) {
  test(`选区首次发送失败后自动重试，保留最初选择时间：${firstFailure}`, async () => {
    let now=1000, poll;
    const handlers={}, timers=[], sent=[];
    const document={visibilityState:'visible',title:'fixture',hasFocus:()=>true,
      addEventListener:(event,fn)=>handlers[event]=fn,querySelectorAll:()=>[],
      documentElement:{append:()=>{}},createElement:()=>({style:{},remove:()=>{}})};
    let active=false;
    const context=vm.createContext({document,window:{addEventListener:()=>{}},location:{href:'https://example.com'},
      crypto:{randomUUID:()=> 'doc'},Date:{now:()=>now},innerWidth:800,innerHeight:600,scrollX:0,scrollY:0,devicePixelRatio:2,
      getSelection:()=>({toString:()=> '公告浮窗原文',getRangeAt:()=>({getBoundingClientRect:()=>({x:0,y:0,width:80,height:20})})}),
      setTimeout:fn=>{timers.push(fn);return timers.length},clearTimeout:()=>{},setInterval:fn=>poll=fn,
      chrome:{runtime:{onMessage:{addListener:()=>{}},sendMessage:async event=>{
        if(event.type==='status')return {active,session:'session'};
        sent.push(event);
        if(sent.length===1){if(firstFailure==='disconnected')throw Error('Native connection lost');return {ok:false};}
        return {ok:true};
      }}}
    });
    vm.runInContext(fs.readFileSync('BrowserExtension/content.js','utf8'),context);
    await new Promise(resolve=>setImmediate(resolve)); active=true;
    handlers.selectionchange();now=1040;await timers.shift()().catch(()=>{});
    now=1600;await poll();await new Promise(resolve=>setImmediate(resolve));
    assert.equal(sent.length,2);
    assert.equal(sent[1].selectedText,'公告浮窗原文');
    assert.equal(sent[1].wallTime,1000);
  });
}

test('前一选区确认很慢时，中间和后续选区仍全部发送，不丢掉已口述的对象',async()=>{
  let now=1000, selected='A', active=false, resolveFirst;
  const handlers={}, timers=[], sent=[];
  const firstAck=new Promise(resolve=>resolveFirst=resolve);
  const document={visibilityState:'visible',title:'fixture',hasFocus:()=>true,
    addEventListener:(event,fn)=>handlers[event]=fn,querySelectorAll:()=>[],
    documentElement:{append:()=>{}},createElement:()=>({style:{},remove:()=>{}})};
  const context=vm.createContext({document,window:{addEventListener:()=>{}},location:{href:'https://example.com'},
    crypto:{randomUUID:()=> 'doc'},Date:{now:()=>now},innerWidth:800,innerHeight:600,scrollX:0,scrollY:0,devicePixelRatio:2,
    getSelection:()=>({toString:()=>selected,getRangeAt:()=>({getBoundingClientRect:()=>({x:0,y:0,width:80,height:20})})}),
    setTimeout:(fn,ms)=>{timers.push({fn,ms});return timers.length},clearTimeout:()=>{},setInterval:()=>{},
    chrome:{runtime:{onMessage:{addListener:()=>{}},sendMessage:async event=>{
      if(event.type==='status')return {active,session:'session'};
      sent.push(event); if(sent.length===1)return firstAck; return {ok:true};
    }}}
  });
  vm.runInContext(fs.readFileSync('BrowserExtension/content.js','utf8'),context);
  await new Promise(resolve=>setImmediate(resolve)); active=true;
  function select(text,time){selected=text;now=time;handlers.selectionchange();const index=timers.findIndex(x=>x.ms===40);return timers.splice(index,1)[0].fn();}
  const a=select('A',1000);await new Promise(resolve=>setImmediate(resolve));
  const b=select('B',1600);await new Promise(resolve=>setImmediate(resolve));
  const c=select('C',2200);await new Promise(resolve=>setImmediate(resolve));
  resolveFirst({ok:true});await Promise.all([a,b,c]);
  assert.deepEqual(sent.map(x=>x.selectedText),['A','B','C']);
  assert.deepEqual(sent.map(x=>x.wallTime),[1000,1600,2200]);
});

test('一次鼠标拖选共享编号，松开时提交最终文字，新拖选使用新编号',async()=>{
  let now=1000,selected='',active=false,uuid=0,poll;
  const handlers={},timers=[],sent=[];
  const document={visibilityState:'visible',title:'fixture',hasFocus:()=>true,
    addEventListener:(event,fn)=>handlers[event]=fn,querySelectorAll:()=>[],
    documentElement:{append:()=>{}},createElement:()=>({style:{},remove:()=>{}})};
  const context=vm.createContext({document,window:{addEventListener:()=>{}},location:{href:'https://example.com'},
    crypto:{randomUUID:()=> `uuid-${++uuid}`},Date:{now:()=>now},innerWidth:800,innerHeight:600,scrollX:0,scrollY:0,devicePixelRatio:2,
    getSelection:()=>({toString:()=>selected,getRangeAt:()=>({getBoundingClientRect:()=>({x:0,y:0,width:80,height:20})})}),
    setTimeout:(fn,ms)=>{timers.push({fn,ms});return timers.length},clearTimeout:()=>{},setInterval:fn=>poll=fn,
    chrome:{runtime:{onMessage:{addListener:()=>{}},sendMessage:async event=>{
      if(event.type==='status')return {active,session:'session'}; sent.push(event);return {ok:true};
    }}}
  });
  vm.runInContext(fs.readFileSync('BrowserExtension/content.js','utf8'),context);
  await new Promise(resolve=>setImmediate(resolve));active=true;
  assert.equal(typeof handlers.pointerdown,'function');assert.equal(typeof handlers.pointerup,'function');
  handlers.pointerdown({button:0});
  async function move(text,time){now=time;selected=text;handlers.selectionchange();const index=timers.findIndex(x=>x.ms===40);await timers.splice(index,1)[0].fn();}
  await move('C',1040);await move('Cla',1120);await move('Clash Verge',1200);
  now=1250;await handlers.pointerup({button:0});
  assert.equal(sent.length,4);
  assert.equal(new Set(sent.map(x=>x.selectionID)).size,1);
  assert.ok(sent[0].selectionID);
  assert.equal(sent[0].selectionStartedAt,1000);
  assert.equal(sent[0].selectionComplete,false);
  assert.equal(sent[3].selectionComplete,true);
  assert.equal(sent[3].selectedText,'Clash Verge');
  handlers.keydown?.({key:'c',metaKey:true});now=1400;await poll();await new Promise(resolve=>setImmediate(resolve));
  assert.equal(sent.length,4,'复制且选区不变时不能制造新的选择边界');
  await move('Other software',1500);
  assert.notEqual(sent[4].selectionID,sent[0].selectionID,'后续键盘或查找选区不能继承已结束的鼠标手势');
  now=2000;handlers.pointerdown({button:0});await move('Clash Verge',2050);now=2100;await handlers.pointerup({button:0});
  assert.notEqual(sent[5].selectionID,sent[0].selectionID);
});
