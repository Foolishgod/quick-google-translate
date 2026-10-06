const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const code = fs.readFileSync('QuickGoogleTranslate/BrowserTranslate.js', 'utf8');
async function fixture({mode='Advanced', hasControl=true, disabled=false, hostname='translate.google.com', loseModel=false, busy=false, menu=true}={}) {
  let clicked=false, reads=0;
  const visible={getClientRects:()=>[{}], closest:()=>null, getAttribute:()=>null};
  const button={...visible, disabled, get innerText(){return mode}, click(){clicked=true}};
  const option={...visible, innerText:'Advanced Improved accuracy, built with Gemini', click(){mode='Advanced'}};
  const segment={...visible, get textContent(){reads++;if(loseModel)mode='Classic';return '你好，世界'}};
  const document={readyState:'complete', querySelectorAll(selector) {
    if(selector.startsWith('button,'))return hasControl?[button]:[];
    if(selector.startsWith('[role="menuitem"'))return menu?[option]:[];
    if(selector==='span.ryNqvb')return [segment];
    if(selector.startsWith('[aria-busy'))return busy?[visible]:[];
    return [];
  }};
  const result=await vm.runInNewContext(code,{document,location:{hostname},getComputedStyle:()=>({visibility:'visible'}),setTimeout:fn=>setImmediate(fn)});
  return {result,clicked,reads};
}
(async()=>{
  const success=await fixture();
  assert.equal(success.result.model,'advanced');assert.equal(success.result.text,'你好，世界');assert.ok(success.reads>=6);
  console.log('PASS: wait for stable advanced output');
  const switched=await fixture({mode:'Classic'});assert.equal(switched.result.reload,true);assert.equal(switched.reads,0);assert.equal(switched.clicked,true);
  console.log('PASS: reload after switching models and discard existing classic output');
  for(const settings of [{hasControl:false},{disabled:true},{mode:'Classic',menu:false},{loseModel:true},{busy:true},{hostname:'accounts.google.com'}]) {
    const {result}=await fixture(settings);assert.ok(result.error);assert.equal(result.text,undefined);
  }
  console.log('PASS: reject unavailable model, lost model, incomplete output and login prompts');
  console.log('All background browser page fixtures passed.');
})().catch(error=>{console.error(error);process.exitCode=1});
