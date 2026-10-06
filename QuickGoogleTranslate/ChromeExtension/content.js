(() => {
  if (new URL(location.href).searchParams.get('qgt') !== '1') return;
  let pairingCode = '';
  let processing = false;
  let lastJob = '';
  const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
  chrome.storage.local.get(['pairingCode']).then(value => { pairingCode = value.pairingCode || ''; });
  chrome.storage.onChanged.addListener(changes => { if (changes.pairingCode) pairingCode = changes.pairingCode.newValue || ''; });
  const visible = el => el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
  const advancedPattern = /高级|進階|進阶|advanced/i;
  const classicPattern = /经典|經典|classic|fast|快速/i;
  const modelControl = () => [...document.querySelectorAll('button,[role="button"]')].find(el => visible(el) && el.closest('[role="menu"]') === null && (advancedPattern.test(el.innerText.trim()) || classicPattern.test(el.innerText.trim())) && el.innerText.trim().length < 100);
  async function ensureAdvanced() {
    let button = modelControl();
    for (let i = 0; !button && i < 20; i++) { await delay(200); button = modelControl(); }
    if (!button) throw new Error('当前语言组合没有显示高级模型选项。请在 Chrome 选择明确的原文语言，并确认高级模式可用。');
    if (button.disabled || button.getAttribute('aria-disabled') === 'true') throw new Error('当前语言组合无法使用高级模式，请在 Google 翻译网页检查语言设置。');
    if (advancedPattern.test(button.innerText)) return false;
    button.click();
    await delay(200);
    const option = [...document.querySelectorAll('[role="menuitem"],[role="menuitemradio"],[role="option"]')].find(el => visible(el) && advancedPattern.test(el.innerText));
    if (!option) throw new Error('无法选择高级模式。请在 Google 翻译网页手动选择“高级”后重试。');
    option.click();
    for (let i = 0; i < 20; i++) {
      await delay(150);
      if (advancedPattern.test(modelControl()?.innerText || '')) return true;
    }
    throw new Error('网页未确认已切换到高级模型，请手动检查。');
  }
  function readResult() {
    const containers = [...document.querySelectorAll('[data-language-for-alternatives]')];
    for (const container of containers) {
      const parts = [...container.querySelectorAll('span.ryNqvb')].filter(visible);
      const text = parts.map(el => el.textContent).join('');
      if (text.trim()) return text;
    }
    const text = [...document.querySelectorAll('span.ryNqvb')].filter(visible).map(el => el.textContent).join('');
    return text.trim() ? text : '';
  }
  async function submit(job, result) {
    const response = await chrome.runtime.sendMessage({type:'bridge', path:'/v1/result', method:'POST', body:{id:job.id, ...result}});
    if (![200, 409].includes(response?.status)) throw new Error('Mac 连接已断开。');
  }
  async function execute(job) {
    const wanted = new URL(location.href);
    wanted.searchParams.set('sl', job.source);
    wanted.searchParams.set('tl', job.target);
    wanted.searchParams.set('text', job.text);
    wanted.searchParams.set('op', 'translate');
    if (location.search !== wanted.search) {
      // Re-load a clean request page so that an old translation is never returned.
      location.replace(wanted.href);
      return;
    }
    try {
      const switched = await ensureAdvanced();
      if (switched) {
        if (sessionStorage.getItem('qgt-advanced-reload') === job.id) throw new Error('高级模型选项未能保留，请在网页手动选择高级后重试。');
        sessionStorage.setItem('qgt-advanced-reload', job.id);
        location.reload();
        return;
      }
      let previous = '';
      let stable = 0;
      // Treat the Google page as the source of truth; require an explicit model control.
      for (let i = 0; i < 180; i++) {
        await delay(200);
        if (i % 5 === 0) {
          const heartbeat = await chrome.runtime.sendMessage({type:'bridge', path:'/v1/job', method:'GET'});
          if (heartbeat?.status !== 200 || heartbeat.data.job?.id !== job.id) return;
        }
        if (!advancedPattern.test(modelControl()?.innerText || '')) throw new Error('Google 网页没有保持高级模式，已停止本次翻译。');
        const text = readResult();
        if (text && text === previous) stable++; else stable = 0;
        previous = text;
        const busy = [...document.querySelectorAll('[aria-busy="true"],[role="progressbar"]')].some(visible);
        if (text && !busy && stable >= 5) {
          await submit(job, {text, model:'advanced'});
          lastJob = job.id;
          return;
        }
      }
      throw new Error('Google 高级翻译未返回可确认的结果，请在 Chrome 检查网络、登录状态及模型选项后重试。');
    } catch (error) {
      await submit(job, {error: error.message || '网页高级翻译失败。'});
      lastJob = job.id;
    }
  }
  async function poll() {
    if (!pairingCode || processing) return;
    // Web Locks prevents multiple Google Translate tabs from consuming the same request.
    await navigator.locks.request('quick-google-translate-worker', {ifAvailable:true}, async lock => {
      if (!lock || processing) return;
      processing = true;
      try {
        const response = await chrome.runtime.sendMessage({type:'bridge', path:'/v1/job', method:'GET'});
        if (response?.status === 401) { pairingCode = ''; return; }
        if (response?.status !== 200) return;
        const {job} = response.data;
        if (job && job.id !== lastJob) await execute(job);
      } catch { /* Mac app may be closed; the next poll will reconnect. */ }
      finally { processing = false; }
    });
  }
  setInterval(poll, 800);
  poll();
})();
