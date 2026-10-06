async request => {
  const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
  const visible = el => el.getClientRects().length && getComputedStyle(el).visibility !== 'hidden';
  const advanced = /高级|進階|advanced/i;
  const classic = /经典|經典|classic|fast|快速/i;
  const control = () => [...document.querySelectorAll('button,[role="button"]')].find(el => visible(el) && !el.closest('[role="menu"]') && el.innerText.trim().length < 100 && (advanced.test(el.innerText) || classic.test(el.innerText)));
  const result = () => {
    const segments = [...document.querySelectorAll('span.ryNqvb')].filter(visible);
    if (!segments.length) return '';
    let root = segments[0];
    while (root.parentElement && !segments.every(el => root.contains(el))) root = root.parentElement;
    const walk = (node, inside = false) => {
      if (node.nodeType === 3) return inside || /^\s*$/.test(node.textContent) ? node.textContent : '';
      if (node.nodeType !== 1) return '';
      if (node.tagName === 'BR') return '\n';
      const selected = inside || segments.includes(node);
      if (!selected && !segments.some(el => node.contains(el))) return '';
      const text = [...node.childNodes].map(child => walk(child, selected)).join('');
      return /^(DIV|P|LI|SECTION|TR)$/.test(node.tagName) && text ? text + '\n' : text;
    };
    return walk(root).replace(/\n[\t ]+\n/g, '\n\n').trim();
  };
  const busy = () => [...document.querySelectorAll('[aria-busy="true"],[role="progressbar"]')].some(visible);
  window.__qgtRequest = request.id;
  const current = () => {
    if (window.__qgtRequest !== request.id) throw new Error('请求已取消。');
  };
  const wait = async ms => { await delay(ms); current(); };
  try {
    current();
    if (location.hostname !== 'translate.google.com') throw new Error('Google 需要登录或确认，请在设置中打开登录窗口处理。');
    let button;
    for (let i = 0; i < 40 && !button; i++) {
      if (document.readyState === 'complete') button = control();
      if (!button) await wait(150);
    }
    if (!button || button.disabled || button.getAttribute('aria-disabled') === 'true') throw new Error('网页没有可用的高级模型选项。请打开登录窗口检查账号、语言组合或 Google 提示。');
    const input = [...document.querySelectorAll('textarea')].find(el => visible(el) && !el.disabled && !el.readOnly);
    if (!input) return {recover: true};
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set;
    if (!setter) return {recover: true};
    const setText = text => {
      current();
      setter.call(input, text);
      input.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: text ? 'insertText' : 'deleteContentBackward', data: text || null}));
    };
    // Wait for the page to acknowledge clearing. Even identical consecutive results
    // must be produced after this empty state, never accepted from the old request.
    setText('');
    let empty = 0;
    for (let i = 0; i < 32 && empty < 2; i++) {
      await wait(75);
      empty = input.value === '' && !result().trim() && !busy() ? empty + 1 : 0;
    }
    if (empty < 2) return {recover: true};
    if (!advanced.test(button.innerText)) {
      button.click();
      await wait(150);
      const option = [...document.querySelectorAll('[role="menuitem"],[role="menuitemradio"],[role="option"]')].find(el => visible(el) && advanced.test(el.innerText));
      if (!option) throw new Error('无法切换高级模型，请在登录窗口手动选择高级后重试。');
      option.click();
      for (let i = 0; i < 15 && !advanced.test(control()?.innerText || ''); i++) await wait(100);
      // Compatibility recovery only; normal model selection does not reload.
      if (!advanced.test(control()?.innerText || '')) return {reload: true};
    }
    current();
    if (result().trim()) return {recover: true};
    setText(request.text);
    let previous = '', stable = 0;
    for (let i = 0; i < 240; i++) {
      await wait(150);
      if (!advanced.test(control()?.innerText || '')) throw new Error('Google 未保持高级模式，本次不会采用经典模型。');
      if (input.value.replace(/\r\n/g, '\n') !== request.text.replace(/\r\n/g, '\n')) return {recover: true};
      const text = result();
      stable = text.trim() && text === previous && !busy() ? stable + 1 : 0;
      previous = text;
      if (text.trim() && !busy() && stable >= 3) return {text, model: 'advanced'};
    }
    throw new Error('Google 高级翻译未及时返回。请检查网络，或打开登录窗口完成验证后重试。');
  } catch (error) {
    return {error: error.message || '后台翻译失败。'};
  }
}
