import sys,json,time
from pathlib import Path
sys.path.insert(0,str(Path.cwd()/'tests/integration'))
from test_settings_app import ROOT,PrivateSession,IPC,probe,wait_for,resize,keys
from test_settings_appearance import ready,click
from test_custom_themes import Peer
with PrivateSession(ROOT/'artifacts/matugen-settings-crash/session',tool_prefix=ROOT/'.cache/aqueous-activity-production') as s:
    s.env['GSETTINGS_BACKEND']='memory'
    ipc=IPC(s);output=next(iter(ipc.outputs().values()))
    s.run(['wlr-randr','--output',output['name'],'--custom-mode','1600x1100@60Hz'])
    resize(s,Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml',1040,850)
    shell=s.child('pearl',[ROOT/'zig-out/bin/pearl'],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
    peer=Peer(s,ipc)
    app=s.child('settings',['gdb','-batch','-ex','run','-ex','bt','--args',ROOT/'zig-out/test/pearl-settings-test','--page','appearance'],G_DEBUG='fatal-warnings')
    app.expect('event=settings-window-created');ready(s,ipc)
    wait_for(lambda:not probe(s,ipc)['theme_busy'],15)
    print('enable',flush=True)
    click(s,ipc,'applications.enabled');ready(s,ipc)
    print('select mode',flush=True)
    click(s,ipc,'applications.zed.mode');keys(s,'Home','Down','Return')
    time.sleep(.5)
    print('select profile',flush=True)
    click(s,ipc,'applications.zed.profile');keys(s,'Home','Down','Return')
    time.sleep(2)
    print(json.loads(peer.document())['matugen'],flush=True)
    ready(s,ipc)
    print('apply',flush=True)
    click(s,ipc,'apply');ready(s,ipc)
    print('passed',flush=True)
    peer.close()
