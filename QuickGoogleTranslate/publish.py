"""Publish only reviewed release assets and docs, never the workspace."""
from pathlib import Path
import base64
import hashlib
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent
gh = sys.argv[1] if len(sys.argv) > 1 else 'gh'
repo = 'Foolishgod/quick-google-translate'
def call(*args):
    return subprocess.check_output([gh,*args],text=True).strip()
assert call('api','user','--jq','.login') == 'Foolishgod'
metadata=json.loads(call('repo','view',repo,'--json','visibility,defaultBranchRef'))
assert metadata['visibility']=='PUBLIC' and metadata['defaultBranchRef']['name']=='main'
feed=root/'dist/updates/appcast.xml'
subprocess.run([str(root/'Vendor/Sparkle/bin/sign_update'),'--account','local.quickgoogletranslate.mac.updates','--verify',str(feed)],check=True)

def put_file(path,content,message):
    info=subprocess.run([gh,'api',f'repos/{repo}/contents/{path}'],capture_output=True,text=True)
    body={'message':message,'content':base64.b64encode(content).decode(),'branch':'main'}
    if info.returncode==0:
        previous=json.loads(info.stdout)
        if base64.b64decode(previous['content'])==content:
            return
        body['sha']=previous['sha']
    elif '404' not in info.stderr:
        raise RuntimeError('Cannot inspect repository file: '+path)
    with tempfile.TemporaryDirectory(prefix='qgt-publish-') as temporary:
        request=Path(temporary)/'request.json'
        request.write_text(json.dumps(body))
        call('api','--method','PUT',f'repos/{repo}/contents/{path}','--input',str(request))

# Keep web-edited learning documentation unless the maintainer explicitly syncs it.
if '--sync-readme' in sys.argv[2:]:
    put_file('README.md',(root/'Publication/README.md').read_bytes(),'Synchronize application and source documentation')
existing=subprocess.run([gh,'api',f'repos/{repo}/releases/tags/updates'],capture_output=True,text=True)
if existing.returncode != 0:
    if '404' not in existing.stderr:
        raise RuntimeError('Cannot inspect release')
    subprocess.run([gh,'release','create','updates','--repo',repo,'--title','划词谷歌翻译 · 应用内更新','--notes-file',str(root/'Publication/RELEASE.md'),'--latest'],check=True)
    existing=subprocess.run([gh,'api',f'repos/{repo}/releases/tags/updates'],capture_output=True,text=True,check=True)
assets={item['name']:item for item in json.loads(existing.stdout)['assets']}
for path in sorted((root/'dist/updates').iterdir()):
    if path.suffix not in {'.zip','.delta'} or not path.name.startswith('QuickGoogleTranslate-'):
        continue
    digest='sha256:'+hashlib.sha256(path.read_bytes()).hexdigest()
    if path.name in assets:
        asset=assets[path.name]
        if asset.get('digest'):
            if asset['digest']!=digest:
                raise RuntimeError('Released asset changed; increment version instead: '+path.name)
        else:
            with tempfile.TemporaryDirectory(prefix='qgt-asset-check-') as temporary:
                downloaded=Path(temporary)/path.name
                subprocess.run([gh,'release','download','updates','--repo',repo,'--pattern',path.name,'--output',str(downloaded)],check=True)
                if hashlib.sha256(downloaded.read_bytes()).hexdigest()!=digest.removeprefix('sha256:'):
                    raise RuntimeError('Released asset differs: '+path.name)
        continue
    subprocess.run([gh,'release','upload','updates',str(path),'--repo',repo],check=True)
put_file('appcast.xml',feed.read_bytes(),'Publish signed application update feed')
subprocess.run([gh,'release','edit','updates','--repo',repo,'--notes-file',str(root/'Publication/RELEASE.md'),'--latest'],check=True)
print('Published release assets and signed feed: https://github.com/'+repo)
