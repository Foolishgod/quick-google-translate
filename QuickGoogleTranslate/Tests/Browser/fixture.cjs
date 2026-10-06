const fs=require('node:fs');
const path=require('node:path');
const {WebSocketServer:Server}=require('ws');
const args=process.argv.slice(2);
const directory=args.find(arg=>arg.startsWith('--user-data-dir='))?.slice('--user-data-dir='.length);
if(!directory)process.exit(2);
fs.mkdirSync(directory,{recursive:true});
fs.writeFileSync(path.join(directory,'fixture-arguments.json'),JSON.stringify(args));
if(!args.includes('--headless=new')){setInterval(()=>{},1000);}
else {
  let loader=0, nextTarget=0, invalidOnce=false, disconnectedOnce=false;
  const trace={created:0,navigated:0,reloaded:0,closed:0,inputs:[]};
  const save=()=>fs.writeFileSync(path.join(directory,'fixture-trace.json'),JSON.stringify(trace));
  const server=new Server({host:'127.0.0.1',port:0});
  server.on('listening',()=>{save();fs.writeFileSync(path.join(directory,'DevToolsActivePort'),`${server.address().port}\n/devtools/browser/fixture\n`)});
  server.on('connection',socket=>socket.on('message',raw=>{
    const req=JSON.parse(raw.toString());let result={}, error, delay=0;
    switch(req.method){
      case 'Browser.getVersion':result={product:'Fixture'};break;
      case 'Target.createTarget':trace.created++;result={targetId:'target-'+(++nextTarget)};break;
      case 'Target.attachToTarget':result={sessionId:'session-'+nextTarget};break;
      case 'Page.getFrameTree':result={frameTree:{frame:{loaderId:`loader-${loader}`}}};break;
      case 'Page.navigate':loader++;trace.navigated++;if(new URL(req.params.url).searchParams.get('text'))throw Error('Cold navigation must have empty input');break;
      case 'Page.reload':loader++;trace.reloaded++;break;
      case 'Runtime.evaluate':
        if(req.params.expression==='document.readyState')result={result:{value:'complete'}};
        else if(req.params.expression==='window.__qgtRequest = null')result={result:{value:null}};
        else {
          const expression=req.params.expression;
          const input=JSON.parse(expression.slice(expression.lastIndexOf('\n)(')+3,-1));
          const text=input.text;trace.inputs.push(text);
          let value={text:'结果:'+text,model:'advanced'};
          if(text==='classic')value={text:'经典结果',model:'classic'};
          if(text==='login')value={error:'Google 需要登录或确认，请在设置中打开登录窗口处理。'};
          if(text==='recover'&&!invalidOnce){invalidOnce=true;value={recover:true};}
          if(text==='disconnect'&&!disconnectedOnce){disconnectedOnce=true;error={message:'Target closed'};}
          if(text==='cancel'||text==='old')delay=1200;
          result={result:{value}};
        }
        break;
      case 'Target.closeTarget':trace.closed++;result={success:true};break;
    }
    save();setTimeout(()=>{if(socket.readyState===1)socket.send(JSON.stringify({id:req.id,...(error?{error}:{result})}))},delay);
  }));
}
process.on('SIGTERM',()=>process.exit(0));
