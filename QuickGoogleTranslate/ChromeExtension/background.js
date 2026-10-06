chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== 'bridge') return;
  try {
    if (!sender.tab || new URL(sender.url).origin !== 'https://translate.google.com') return;
  } catch { return; }
  const allowed = {'/v1/job':'GET', '/v1/result':'POST'};
  if (allowed[message.path] !== message.method) { sendResponse({status:400}); return; }
  (async () => {
    const {pairingCode} = await chrome.storage.local.get(['pairingCode']);
    if (!pairingCode) return {status:401};
    const options = {method:message.method, headers:{Authorization:`Bearer ${pairingCode}`}, signal:AbortSignal.timeout(4000)};
    if (message.method === 'POST') {
      const body = JSON.stringify(message.body);
      if (body.length > 32000) return {status:413};
      options.headers['Content-Type'] = 'application/json';
      options.body = body;
    }
    const response = await fetch(`http://127.0.0.1:48137${message.path}`, options);
    return {status:response.status, data:await response.json()};
  })().then(sendResponse, () => sendResponse({status:503}));
  return true;
});
