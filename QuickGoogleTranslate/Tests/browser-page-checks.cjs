const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const code = fs.readFileSync('QuickGoogleTranslate/BrowserTranslate.js', 'utf8');
async function fixture({mode='Advanced', hasControl=true, disabled=false, hostname='translate.google.com', loseModel=false, busy=false, menu=true, noInput=false, stale=false, chunks=false, cancel=false, switchFails=false, ready=true, sameResult=false}={}) {
  let clicked=false, reads=0, submitted=false, ticks=0, output='旧译文', modeAtSubmit;
  const pageWindow = {};
  const visible={getClientRects:()=>[{}], closest:()=>null, getAttribute:()=>null};
  class TextArea {
    constructor(){this._value='上一段文字';Object.assign(this,visible)}
    get value(){return this._value}
    set value(value){this._value=value}
    dispatchEvent(event){
      assert.equal(event.type,'input');
      if(this.value===''){if(!stale)output='';}
      else {submitted=true;modeAtSubmit=mode;ticks=0;}
    }
  }
  const input=new TextArea();
  const button={...visible, disabled, get innerText(){return mode}, click(){clicked=true}};
  const option={...visible, innerText:'Advanced Improved accuracy, built with Gemini', click(){if(!switchFails)mode='Advanced'}};
  const segment={...visible, get textContent(){reads++;return output}};
  const document={readyState:ready?'complete':'loading', querySelectorAll(selector) {
    if(selector.startsWith('button,'))return hasControl?[button]:[];
    if(selector.startsWith('[role="menuitem"'))return menu?[option]:[];
    if(selector==='textarea')return noInput?[]:[input];
    if(selector==='span.ryNqvb')return [segment];
    if(selector.startsWith('[aria-busy'))return busy?[visible]:[];
    return [];
  }};
  const context=vm.createContext({window:pageWindow,document,HTMLTextAreaElement:TextArea,InputEvent:class{constructor(type){this.type=type}},location:{hostname},getComputedStyle:()=>({visibility:'visible'}),setTimeout:fn=>setImmediate(()=>{
    if(cancel)pageWindow.__qgtRequest=null;
    if(submitted){ticks++;if(loseModel)mode='Classic';output=sameResult?'旧译文':chunks&&ticks<8?'译文正在变化'+ticks:'你好，世界';}
    fn();
  })});
  context.request={id:'fixture-request',text:'new text'};
  const result=await vm.runInContext('('+code+')(request)',context);
  return {result,clicked,reads,submitted,modeAtSubmit,ticks};
}
(async()=>{
  const success=await fixture();assert.equal(success.result.model,'advanced');assert.equal(success.result.text,'你好，世界');assert.ok(success.ticks>=4);
  console.log('PASS: clear old output and wait for stable new advanced output');
  const switched=await fixture({mode:'Classic'});assert.equal(switched.result.model,'advanced');assert.equal(switched.modeAtSubmit,'Advanced');assert.equal(switched.clicked,true);assert.equal(switched.result.reload,undefined);
  console.log('PASS: switch to Advanced before submitting, without reloading');
  const repeated=await fixture({sameResult:true});assert.equal(repeated.result.text,'旧译文');assert.ok(repeated.submitted);
  console.log('PASS: identical translation is accepted only after acknowledged clearing and new input');
  const streamed=await fixture({chunks:true});assert.equal(streamed.result.text,'你好，世界');assert.ok(streamed.ticks>=11);
  console.log('PASS: streaming result must stabilize before being returned');
  for(const settings of [{stale:true},{noInput:true}]){const {result,submitted}=await fixture(settings);assert.equal(result.recover,true);assert.equal(submitted,false);}
  console.log('PASS: never return stale output; recover when the page cannot acknowledge clearing');
  const retry=await fixture({mode:'Classic',switchFails:true});assert.equal(retry.result.reload,true);assert.equal(retry.submitted,false);
  for(const settings of [{hasControl:false},{disabled:true},{mode:'Classic',menu:false},{loseModel:true},{busy:true},{hostname:'accounts.google.com'},{ready:false},{cancel:true}]) {
    const {result}=await fixture(settings);assert.ok(result.error || result.recover);assert.equal(result.text,undefined);
  }
  console.log('PASS: reject unavailable/lost model, incomplete output, canceled requests and login prompts');
  console.log('All reusable page fixtures passed.');
})().catch(error=>{console.error(error);process.exitCode=1});
