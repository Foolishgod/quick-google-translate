(async () => {
  const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
  const visible = el => el.getClientRects().length && getComputedStyle(el).visibility !== 'hidden';
  const advanced = /高级|進階|advanced/i;
  const classic = /经典|經典|classic|fast|快速/i;
  const control = () => [...document.querySelectorAll('button,[role="button"]')].find(el => visible(el) && !el.closest('[role="menu"]') && el.innerText.trim().length < 100 && (advanced.test(el.innerText) || classic.test(el.innerText)));
  const result = () => [...document.querySelectorAll('span.ryNqvb')].filter(visible).map(el => el.textContent).join('');
  try {
    for (let i=0; i<100; i++) {
      if (location.hostname === 'translate.google.com' && document.readyState === 'complete') break;
      await delay(100);
    }
    if (location.hostname !== 'translate.google.com') throw new Error('Google 需要登录或确认，请在设置中打开登录窗口处理。');
    let button;
    for (let i=0; i<30 && !button; i++) { button = control(); if (!button) await delay(200); }
    if (!button || button.disabled || button.getAttribute('aria-disabled') === 'true') throw new Error('网页没有可用的高级模型选项。请打开登录窗口检查账号、语言组合或 Google 提示。');
    if (!advanced.test(button.innerText)) {
      button.click();
      await delay(200);
      const option = [...document.querySelectorAll('[role="menuitem"],[role="menuitemradio"],[role="option"]')].find(el => visible(el) && advanced.test(el.innerText));
      if (!option) throw new Error('无法切换高级模型，请在登录窗口手动选择高级后重试。');
      option.click();
      // Re-load after the model preference changes to avoid returning a classic result.
      return {reload:true};
    }
    let previous='', stable=0;
    for (let i=0; i<180; i++) {
      await delay(200);
      if (!advanced.test(control()?.innerText || '')) throw new Error('Google 未保持高级模式，本次不会采用经典模型。');
      const text = result();
      stable = text && text === previous ? stable+1 : 0;
      previous = text;
      const busy = [...document.querySelectorAll('[aria-busy="true"],[role="progressbar"]')].some(visible);
      if (text.trim() && !busy && stable>=5) return {text, model:'advanced'};
    }
    throw new Error('Google 高级翻译未及时返回。请检查网络，或打开登录窗口完成验证后重试。');
  } catch(error) { return {error:error.message || '后台翻译失败。'}; }
})()
