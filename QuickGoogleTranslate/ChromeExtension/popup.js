const base = 'http://127.0.0.1:48137';
const field = document.querySelector('#code');
const status = document.querySelector('#status');
chrome.storage.local.get(['pairingCode']).then(({pairingCode}) => { field.value = pairingCode || ''; });
document.querySelector('#save').addEventListener('click', async () => {
  const code = field.value.trim();
  if (!/^[a-f0-9]{64}$/.test(code)) { status.textContent = '连接码格式不正确，请从 Mac 工具重新复制。'; return; }
  try {
    const response = await fetch(`${base}/v1/status`, {headers: {Authorization: `Bearer ${code}`}, signal: AbortSignal.timeout(4000)});
    if (!response.ok) throw new Error('code');
    await chrome.storage.local.set({pairingCode: code});
    status.textContent = '连接码已保存。请保持 Google 翻译页打开。';
  } catch { status.textContent = '未连接。请打开新版 Mac 工具并核对连接码。'; }
});
document.querySelector('#open').addEventListener('click', async () => {
  const tabs = await chrome.tabs.query({url:'https://translate.google.com/*'});
  const existing = tabs.find(tab => new URL(tab.url).searchParams.get('qgt') === '1');
  if (existing) await chrome.tabs.update(existing.id, {active:true});
  else await chrome.tabs.create({url:'https://translate.google.com/?sl=en&tl=zh-CN&op=translate&qgt=1'});
});
