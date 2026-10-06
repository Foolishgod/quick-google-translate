const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const code = fs.readFileSync('QuickGoogleTranslate/ChromeExtension/content.js', 'utf8');
async function fixture({mode='Advanced', hasControl=true, cancel=false, sameURL=true}={}) {
  const job = {id:'fixture-id', text:'Hello & 世界', source:'en', target:'zh-CN'};
  const url = new URL('https://translate.google.com/?qgt=1');
  if (sameURL) { url.searchParams.set('sl','en'); url.searchParams.set('tl','zh-CN'); url.searchParams.set('text',job.text); url.searchParams.set('op','translate'); }
  let poll, replaced, reloaded=false, polls=0;
  const replies=[];
  const state=new Map();
  const visible = {getClientRects:()=>[{}], closest:()=>null, getAttribute:()=>null};
  const button = {...visible, get innerText(){return mode}, click(){}};
  const option = {...visible, innerText:'Advanced Improved accuracy, built with Gemini', click(){mode='Advanced'}};
  const segment={...visible,textContent:'你好，世界'};
  const document = {querySelectorAll(selector) {
    if (selector.startsWith('button,')) return hasControl ? [button] : [];
    if (selector.startsWith('[role="menuitem"')) return [option];
    if (selector === 'span.ryNqvb') return [segment];
    return [];
  }};
  const context={URL, document, getComputedStyle:()=>({visibility:'visible'}),
    location:{href:url.href, search:url.search, replace(value){replaced=value}, reload(){reloaded=true}},
    sessionStorage:{getItem:key=>state.get(key),setItem:(key,value)=>state.set(key,value)},
    navigator:{locks:{request:async(_key,_options,fn)=>fn({})}},
    setInterval:fn=>{poll=fn}, setTimeout:fn=>setImmediate(fn),
    chrome:{storage:{local:{get:async()=>({pairingCode:'a'.repeat(64)})},onChanged:{addListener(){}}},
      runtime:{sendMessage:async message=>{
        if (message.path === '/v1/job') {polls++;return {status:200,data:{job:cancel && polls>1 ? null : job}}}
        replies.push(message.body);return {status:200,data:{ok:true}};
      }}
    }
  };
  vm.runInNewContext(code, context);
  await new Promise(resolve=>setImmediate(resolve));
  await poll();
  return {replies,replaced,reloaded};
}
(async()=>{
  const advanced=await fixture();
  assert.equal(advanced.replies[0].model,'advanced');
  assert.equal(advanced.replies[0].text,'你好，世界');
  console.log('PASS: return stable result only when advanced is confirmed');
  const unsupported=await fixture({hasControl:false});
  assert.ok(unsupported.replies[0].error.includes('没有显示高级'));
  assert.equal(unsupported.replies[0].text,undefined);
  console.log('PASS: fail clearly when advanced control is unavailable');
  const classic=await fixture({mode:'Classic'});
  assert.equal(classic.reloaded,true);
  assert.equal(classic.replies.length,0);
  console.log('PASS: after switching classic to advanced, reload before reading a result');
  const cancelled=await fixture({cancel:true});
  assert.equal(cancelled.replies.length,0);
  console.log('PASS: abandon an in-flight result after native cancellation');
  const navigate=await fixture({sameURL:false});
  assert.equal(new URL(navigate.replaced).searchParams.get('text'),'Hello & 世界');
  assert.equal(navigate.replies.length,0);
  console.log('PASS: reload the requested multilingual text before reading results');
  console.log('All Chrome page fixture checks passed.');
})().catch(error=>{console.error(error);process.exitCode=1});
