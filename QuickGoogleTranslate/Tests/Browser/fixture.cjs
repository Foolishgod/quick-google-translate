const fs=require('node:fs');
const path=require('node:path');
const {WebSocketServer:Server}=require('ws');
const args=process.argv.slice(2);
const directory=args.find(arg=>arg.startsWith('--user-data-dir='))?.slice('--user-data-dir='.length);
if (!directory) process.exit(2);
fs.mkdirSync(directory,{recursive:true});
fs.writeFileSync(path.join(directory,'fixture-arguments.json'),JSON.stringify(args));
if (!args.includes('--headless=new')) { setInterval(()=>{},1000); }
else {
  let loader=0, text='', reloads=0;
  const server=new Server({host:'127.0.0.1',port:0});
  server.on('listening',()=>fs.writeFileSync(path.join(directory,'DevToolsActivePort'),`${server.address().port}\n/devtools/browser/fixture\n`));
  server.on('connection',socket=>socket.on('message',raw=>{
    const req=JSON.parse(raw.toString());
    let result={};
    let delay=0;
    switch(req.method) {
      case 'Browser.getVersion': result={product:'Fixture'};break;
      case 'Target.createTarget': result={targetId:'target-fixture'};break;
      case 'Target.attachToTarget': result={sessionId:'session-fixture'};break;
      case 'Page.getFrameTree': result={frameTree:{frame:{loaderId:`loader-${loader}`}}};break;
      case 'Page.navigate': loader++;text=new URL(req.params.url).searchParams.get('text');reloads=0;break;
      case 'Page.reload':loader++;reloads++;break;
      case 'Runtime.evaluate':
        if(req.params.expression==='document.readyState') result={result:{value:'complete'}};
        else {
          let value={text:'你好',model:'advanced'};
          if(text==='classic') value={text:'经典结果',model:'classic'};
          if(text==='login') value={error:'Google 需要登录或确认，请在设置中打开登录窗口处理。'};
          if(text==='switch' && !reloads) value={reload:true};
          if(text==='cancel') delay=300;
          result={result:{value}};
        }
        break;
      case 'Target.closeTarget':result={success:true};break;
    }
    setTimeout(()=>{if(socket.readyState===1)socket.send(JSON.stringify({id:req.id,result}))},delay);
  }));
}
process.on('SIGTERM',()=>process.exit(0));
