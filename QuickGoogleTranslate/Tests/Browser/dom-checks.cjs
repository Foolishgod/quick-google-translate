// Optional actual Chrome DOM check. Every page request is intercepted with local
// fixture HTML; the test has no Google login and uses a temporary browser profile.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {spawn}=require('node:child_process');
const {once}=require('node:events');
const assert=require('node:assert/strict');
const WebSocket=require('ws');
const chrome=process.env.QGT_TEST_CHROME||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const profile=fs.mkdtempSync(path.join(os.tmpdir(),'qgt-dom-test-'));
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const child=spawn(chrome,['--headless=new','--no-first-run','--no-default-browser-check','--disable-background-networking','--host-resolver-rules=MAP * ~NOTFOUND','--remote-debugging-port=0','--remote-debugging-address=127.0.0.1','--user-data-dir='+profile,'about:blank'],{stdio:'ignore'});
const html=`<!doctype html><meta charset="utf-8"><button id="model">Classic</button><div id="menu" role="menu" hidden><button role="menuitem" id="advanced">Advanced Gemini</button></div><textarea></textarea><span class="ryNqvb"></span><script>
window.fixtureInputs=[];let version=0;const input=document.querySelector('textarea'),output=document.querySelector('span');
document.querySelector('#model').onclick=()=>document.querySelector('#menu').hidden=false;
document.querySelector('#advanced').onclick=()=>{document.querySelector('#model').innerText='Advanced';document.querySelector('#menu').hidden=true;};
input.addEventListener('input',()=>{const id=++version,text=input.value;window.fixtureInputs.push(text);output.textContent='';if(text)setTimeout(()=>{if(id===version)output.textContent='译文:'+text;},150);});
</script>`;
let socket,counter=0,pending=new Map(),loads=0;
async function call(method,params={},sessionId){
 const id=++counter;return await new Promise((resolve,reject)=>{
 const timer=setTimeout(()=>{pending.delete(id);reject(Error('Timeout: '+method))},10000);
 pending.set(id,{resolve:result=>{clearTimeout(timer);resolve(result)},reject:error=>{clearTimeout(timer);reject(error)}});
 socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));
 });
}
(async()=>{
 try{
  let lines;
  for(let i=0;i<100;i++){try{lines=fs.readFileSync(path.join(profile,'DevToolsActivePort'),'utf8').trim().split('\n');break}catch{}await delay(100)}
  assert.ok(lines,'Chrome must start');
  socket=new WebSocket('ws://127.0.0.1:'+lines[0]+lines[1]);await once(socket,'open');
  socket.on('message',raw=>{
   const response=JSON.parse(raw.toString());
   if(response.id){const callback=pending.get(response.id);if(callback){pending.delete(response.id);response.error?callback.reject(Error(response.error.message)):callback.resolve(response.result)};}
   else if(response.method==='Fetch.requestPaused'){
    if(response.params.resourceType==='Document')loads++;
    call('Fetch.fulfillRequest',{requestId:response.params.requestId,responseCode:200,responseHeaders:[{name:'Content-Type',value:'text/html; charset=utf-8'}],body:Buffer.from(html).toString('base64')},response.sessionId).catch(error=>{console.error(error);process.exitCode=1});
   }
  });
  const {targetId}=await call('Target.createTarget',{url:'about:blank'});
  const {sessionId}=await call('Target.attachToTarget',{targetId,flatten:true});
  await call('Fetch.enable',{patterns:[{urlPattern:'*',requestStage:'Request'}]},sessionId);
  await call('Page.navigate',{url:'https://translate.google.com/?sl=en&tl=zh-CN&op=translate'},sessionId);
  for(let i=0;i<100;i++){const r=await call('Runtime.evaluate',{expression:"document.readyState === 'complete' && !!document.querySelector('textarea')",returnByValue:true},sessionId);if(r.result.value)break;await delay(50)}
  const code=fs.readFileSync('QuickGoogleTranslate/BrowserTranslate.js','utf8');
  async function translate(text,id){return (await call('Runtime.evaluate',{expression:'('+code+')('+JSON.stringify({id,text})+')',awaitPromise:true,returnByValue:true},sessionId)).result.value;}
  const baseline=loads;
  for(const [i,text] of ['one','two','two','中文\n多行 & < > 😀'].entries()){
    const result=await translate(text,'request-'+i);assert.equal(result.model,'advanced');assert.equal(result.text,'译文:'+text);
  }
  assert.equal(loads,baseline,'warm DOM translations must not navigate');
  console.log('PASS: real Chrome DOM input, model switch, repeated result and multiline text without navigation');
  const old=translate('old','old-request');await delay(50);
  await call('Runtime.evaluate',{expression:'window.__qgtRequest = null'},sessionId);
  const current=await translate('new','new-request');assert.equal(current.text,'译文:new');assert.ok((await old).error);
  console.log('PASS: real page cancellation stops stale scripts while latest input translates');
 }finally{
  if(socket)socket.close();child.kill('SIGTERM');
  await Promise.race([once(child,'exit'),delay(3000)]);
  if(child.exitCode===null){child.kill('SIGKILL');await once(child,'exit')}
  fs.rmSync(profile,{recursive:true,force:true});
 }
})().catch(error=>{console.error(error);process.exitCode=1});
