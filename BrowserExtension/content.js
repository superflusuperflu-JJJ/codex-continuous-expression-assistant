(() => {
  // A declarative load and a repair can race; install only one listener set.
  if (globalThis.__continuousCaptureInstalled) return;
  globalThis.__continuousCaptureInstalled = true;
  let active = false, session = '', last = '', timer, selectionChangedAt = 0;
  let pendingSelections = [];
  let selectionGesture = null, completedSelection = null;
  const documentID = crypto.randomUUID();
  function toast(text) {
    const tag = document.createElement('div');
    tag.textContent = text;
    Object.assign(tag.style, {position:'fixed',right:'24px',top:'24px',padding:'12px 18px',borderRadius:'10px',background:'#163e35',color:'white',font:'14px system-ui',zIndex:'2147483647',pointerEvents:'none'});
    document.documentElement.append(tag); setTimeout(() => tag.remove(), 1800);
  }
  async function status(captureSelection = true) {
    if (document.visibilityState !== 'visible') return;
    try {
      const response = await chrome.runtime.sendMessage({type:'status',source:location.href,documentID,focused:document.hasFocus(),selectionLength:getSelection()?.toString().trim().length || 0});
      if (response.session !== session) { last = ''; pendingSelections = []; session = response.session; }
      active = !!response.active;
      if (active && captureSelection !== false && !timer) selection();
    } catch (_) { active = false; }
  }
  function send(event) {
    return chrome.runtime.sendMessage({...event, type:'selection', documentID, session,
      source:location.href, title:document.title, wallTime:event.wallTime ?? Date.now(),
      viewport:{width:innerWidth,height:innerHeight,scrollX,scrollY,scale:devicePixelRatio}});
  }
  async function dispatchSelection(attempt) {
    if (attempt.inFlight || attempt.session !== session) return;
    attempt.inFlight = true;
    function failed() {
      if (session === attempt.session && !attempt.reportedFailure) {
        attempt.reportedFailure = true;
        toast('选区尚未保存，正在自动重试；请检查本地原型是否仍在采集');
      }
    }
    try {
      const result = await send({...attempt.event,wallTime:attempt.occurredAt});
      if (session !== attempt.session) return;
      if (result?.ok) {
        pendingSelections = pendingSelections.filter(item => item !== attempt);
        if (attempt.event.kind !== 'clear') toast('已记录选区，可继续说');
      } else failed();
    } catch (_) { failed(); }
    finally { attempt.inFlight = false; }
  }
  async function retrySelections() {
    await Promise.all(pendingSelections.map(dispatchSelection));
  }
  async function deliver(event, key, occurredAt) {
    // Observed-key dedup is separate from acknowledgment. Every distinct event
    // enters the background FIFO immediately; retries retain the original time.
    last = key;
    const attempt = {event,key,occurredAt,session,inFlight:false};
    pendingSelections.push(attempt);
    await dispatchSelection(attempt);
  }
  async function selection(occurredAt = Date.now()) {
    if (document.visibilityState !== 'visible' || !document.hasFocus()) return;
    if (!active) await status(false);
    if (!active || occurredAt < selectionChangedAt) return;
    const selected = getSelection();
    const text = selected?.toString().trim() || '';
    if (text.length > 20000) { toast('选区太长，请缩小范围'); return; }
    if (!text) {
      if (last) await deliver({kind:'clear',content:''},'',occurredAt);
      else await retrySelections();
      return;
    }
    const range = selected.getRangeAt(0);
    const links = [...document.querySelectorAll('a[href]')].filter(a => {
      try { return range.intersectsNode(a); } catch (_) { return false; }
    }).slice(0, 20).map(a => ({label:a.textContent.trim(),url:a.href}));
    const cached = completedSelection;
    const sameRange = cached && cached.text === text && cached.anchorNode === selected.anchorNode &&
      cached.anchorOffset === selected.anchorOffset && cached.focusNode === selected.focusNode && cached.focusOffset === selected.focusOffset;
    const gesture = selectionGesture || (sameRange ? cached.gesture : null);
    if (!sameRange) completedSelection = null;
    const key = JSON.stringify([text, links, gesture?.id, gesture?.complete]);
    if (key === last) { await retrySelections(); return; }
    const rect = range.getBoundingClientRect();
    await deliver({kind:links.length === 1 ? 'link' : 'text',content:links.length === 1 ? links[0].url : text,
      label:text,selectedText:text,links,explicit:true,selectionID:gesture?.id,
      selectionComplete:gesture?.complete,selectionStartedAt:gesture?.startedAt,rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height}},key,occurredAt);
  }
  document.addEventListener('pointerdown', event => {
    if (event.button !== 0 || event.isPrimary === false) return;
    completedSelection = null;
    selectionGesture = {id:crypto.randomUUID(),startedAt:Date.now(),complete:false};
  }, true);
  document.addEventListener('pointerup', event => {
    if (event.button !== 0 || !selectionGesture || selectionGesture.complete) return;
    const gesture = {...selectionGesture,complete:true};
    const selected = getSelection();
    completedSelection = {gesture,text:selected?.toString().trim() || '',anchorNode:selected?.anchorNode,
      anchorOffset:selected?.anchorOffset,focusNode:selected?.focusNode,focusOffset:selected?.focusOffset};
    selectionGesture = null;
    clearTimeout(timer); timer = undefined;
    return selection(Date.now());
  }, true);
  document.addEventListener('selectionchange', () => { const at = Date.now(); selectionChangedAt = at; clearTimeout(timer); timer = setTimeout(() => { timer = undefined; return selection(at); }, 40); });
  document.addEventListener('click', async event => {
    if (!active || !event.altKey || !event.isTrusted) return;
    const element = event.target.closest('img, a[href]');
    if (!element) return;
    event.preventDefault(); event.stopImmediatePropagation();
    const image = element.tagName === 'IMG';
    const rect = element.getBoundingClientRect();
    const result = await send({kind:image?'image':'link',content:image?(element.currentSrc||element.src):element.href,
      label:image?(element.alt||'所选网页图片'):(element.textContent.trim()||element.href),explicit:true,
      rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height}});
    toast(!result?.ok ? '采集未成功，请检查本地应用' : image && !result.imageCaptured ?
      (/activeTab|<all_urls>|permission/i.test(result.warning || '') ? '仅记录图片链接；网页截图权限尚未生效，请检查扩展授权' : '仅记录图片链接；截图未保存，请重试') : '已记录，可继续说');
  }, true);
  window.addEventListener('focus', status);
  window.addEventListener('blur', () => { if (active && last) deliver({kind:'clear',content:''},'',Date.now()); selectionGesture = null; completedSelection = null; });
  document.addEventListener('visibilitychange', status);
  chrome.runtime.onMessage.addListener((event, _, respond) => {
    if (event.type === 'identify') respond({documentID, source:location.href});
  });
  setInterval(status, 500); status();
})();
