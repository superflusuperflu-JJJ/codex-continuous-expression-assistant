const HOST = 'local.contextcapture.bridge';
let status = {active: false};
let checkedAt = 0;
let syncing;
let queue = Promise.resolve();
let barrierSent = '';

async function sync(page) {
  if (syncing) return syncing;
  syncing = (async () => {
    const before = Date.now();
    try {
      const reply = await chrome.runtime.sendNativeMessage(HOST, {type: 'hello', ...(page ? {page} : {})});
      const after = Date.now();
      status = {...reply, localMid: (before + after) / 2, uncertainty: (after - before) / 2000 + 0.03};
      checkedAt = after;
      if (status.phase === 'finalizing' && barrierSent !== status.session) {
        barrierSent = status.session;
        queue.then(() => chrome.runtime.sendNativeMessage(HOST, {type:'barrier',session:status.session})).catch(()=>{});
      }
      await chrome.action.setBadgeText({text: status.active ? '录' : ''});
      await chrome.action.setBadgeBackgroundColor({color: '#187b66'});
    } catch (error) { status = {active: false, error: String(error)}; checkedAt = Date.now(); }
    return status;
  })();
  try { return await syncing; } finally { syncing = null; }
}

async function sendSelection(event, sender) {
  if (Date.now() - checkedAt > 1500) await sync();
  if (!sender.tab || (event.session && event.session !== status.session)) return {active: false};
  const occurredAt = status.monotonic + (event.wallTime - status.localMid) / 1000;
  if (!status.active && !(status.phase === 'finalizing' && occurredAt <= status.cutoff)) return {active:false};
  const message = {...event, type: 'selection', session: status.session,
    occurredAt, uncertainty: status.uncertainty, tabID: sender.tab.id,
    windowID: sender.tab.windowId, documentID: sender.documentId || event.documentID,
    source: event.source || sender.tab.url, title: event.title || sender.tab.title};
  if (Number.isFinite(event.selectionStartedAt) && event.selectionStartedAt <= event.wallTime) {
    message.selectionStart = status.monotonic + (event.selectionStartedAt - status.localMid) / 1000;
  }
  if (event.kind === 'image') {
    try {
      const before = await chrome.tabs.query({active:true,windowId:sender.tab.windowId});
      const identity = await chrome.tabs.sendMessage(sender.tab.id,{type:'identify'});
      if (before[0]?.id !== sender.tab.id || identity.documentID !== event.documentID) throw Error('source changed');
      const screenshot = await chrome.tabs.captureVisibleTab(sender.tab.windowId, {format:'jpeg',quality:65});
      const after = await chrome.tabs.query({active:true,windowId:sender.tab.windowId});
      const finalIdentity = await chrome.tabs.sendMessage(sender.tab.id,{type:'identify'});
      if (after[0]?.id !== sender.tab.id || finalIdentity.documentID !== event.documentID) throw Error('source changed');
      message.screenshot = screenshot;
    } catch (error) {
      const reason = error?.message === 'source changed' ? '截图来源无法确认（页面已切换）' : String(error?.message || error);
      message.imageNote = '未取得可靠截图，仅保留图片链接：' + reason;
    }
  }
  try {
    const reply = await chrome.runtime.sendNativeMessage(HOST, message);
    if (event.kind === 'image') return {...reply, imageCaptured: !!message.screenshot && reply.imageCaptured === true,
      warning: message.imageNote || (reply.imageCaptured === true ? '' : '图片内容未能保存')};
    return reply;
  }
  catch (error) { return {active: false, error: String(error)}; }
}

chrome.runtime.onMessage.addListener((event, sender, respond) => {
  const task = event.type === 'status' ? sync({source:event.source,documentID:sender.documentId || event.documentID,focused:event.focused,selectionLength:event.selectionLength}) : (queue = queue.catch(()=>{}).then(() => sendSelection(event,sender)));
  task.then(respond, error => respond({active: false, error: String(error)}));
  return true;
});
// Declarative content scripts do not backfill pages already open at install/update.
// Probe before injecting, and coalesce overlapping activation/update events.
const repairs = new Map();
function supportedPage(tab) { return /^(https?|file):/.test(tab?.url || ''); }
async function ensureCollector(tab) {
  if (!supportedPage(tab) || tab.id == null) return;
  if (repairs.has(tab.id)) return repairs.get(tab.id);
  const repair = (async () => {
    try {
      const identity = await chrome.tabs.sendMessage(tab.id, {type:'identify'});
      if (identity?.documentID) return;
    } catch (_) { /* A stale or absent receiver requires reinjection. */ }
    try { await chrome.scripting.executeScript({target:{tabId:tab.id},files:['content.js']}); }
    catch (error) { console.warn('采集脚本未连接：', tab.id, String(error)); }
  })();
  repairs.set(tab.id, repair);
  try { await repair; } finally { repairs.delete(tab.id); }
}
async function restoreOpenPages() {
  try {
    const tabs = await chrome.tabs.query({url:['http://*/*','https://*/*','file:///*']});
    await Promise.allSettled(tabs.map(ensureCollector));
  } catch (error) { console.warn('检查已打开页面失败：',String(error)); }
}
chrome.runtime.onInstalled.addListener(async () => {
  chrome.contextMenus.create({id: 'capture', title: '纳入本次表达', contexts: ['image', 'link', 'selection']});
  await restoreOpenPages();
});
chrome.runtime.onStartup.addListener(restoreOpenPages);
chrome.tabs.onActivated.addListener(async ({tabId}) => {
  try { await ensureCollector(await chrome.tabs.get(tabId)); } catch (_) {}
});
chrome.tabs.onUpdated.addListener(async (_, change, tab) => {
  if (change.status === 'complete') await ensureCollector(tab);
});
chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  await sync();
  if (!status.active) return;
  const identity = await chrome.tabs.sendMessage(tab.id,{type:'identify'}).catch(()=>({}));
  await (queue = queue.catch(()=>{}).then(() => sendSelection({kind: info.mediaType === 'image' ? 'image' : info.linkUrl ? 'link' : 'text',
    content: info.srcUrl || info.linkUrl || info.selectionText || '', label: info.selectionText || info.srcUrl || info.linkUrl,
    source:tab.url,documentID:identity.documentID,session:status.session,
    wallTime: Date.now(), explicit: true}, {tab, documentId: 'menu-' + tab.id})));
});
chrome.action.onClicked.addListener(async () => {
  await sync();
  await chrome.action.setTitle({title: status.active ? '采集中：选中文字；Option 点击图片或链接' : '请在本地原型点击“开始表达”'});
});
