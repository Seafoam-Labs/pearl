#!/usr/bin/env python3
"""Production plugins and full Settings controls in a private Aqueous session."""
import argparse, hashlib, json, os, shutil, sys, time, uuid
from pathlib import Path
from test_settings_app import ROOT, PrivateSession, IPC, ctl, wait_for, probe, capture, clean
from test_settings_services import Peer
from test_plugin_host import digest
from test_settings_appearance import click, ready
from t00 import Session as T00Session
from types import SimpleNamespace

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('pearl','settings','ctl','examples'): p.add_argument('--'+name,required=True,type=Path)
    p.add_argument('--prefix',type=Path,default=ROOT/'.cache/aqueous-activity-production')
    p.add_argument('--runtime-disabled',action='store_true')
    p.add_argument('--output',type=Path,default=ROOT/'.cache/plugin-session')
    args=p.parse_args()
    for key,value in vars(args).items():
        if isinstance(value,Path):setattr(args,key,value.resolve())
    checks=[]
    with PrivateSession(args.output,tool_prefix=args.prefix) as s:
        s.env['DBUS_SYSTEM_BUS_ADDRESS']='unix:path='+str(s.runtime/'system-bus')
        s.child('system-bus',['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
        wait_for(lambda:s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
        s.env['PEARL_SECURITY_LOG']=str(s.output/'security.jsonl')
        fixture=s.child('authority',['python3',ROOT/'tests/fixtures/session_security.py'],input_pipe=True);fixture.expect('event=ready')
        packages=Path(s.env['XDG_DATA_HOME'])/'pearl/plugins';packages.mkdir(parents=True)
        for name in ('timer-c','counter-zig','counter-rust','companion-c'):shutil.copytree(args.examples/name,packages/name)
        bad=packages/'broken-image';bad.mkdir()
        shutil.copy2(args.examples/'timer-c/plugin.wasm',bad/'plugin.wasm')
        (bad/'plugin.json').write_text(json.dumps(dict(id='pearl.broken-image',name='Invalid PNG',version='1',assets=[dict(id='bad',path='bad.png',license='CC0',width=1,height=1)])))
        (bad/'bad.png').write_bytes(b'\x89PNG\r\n\x1a\n'+b'\x00\x00\x00\rIHDR'+b'\x00\x00\x00\x01'*2+b'broken')
        entries=[]
        for name in ('timer-c','counter-zig','counter-rust','companion-c'):
            manifest=json.loads((packages/name/'plugin.json').read_text())
            cfg=dict(id=manifest['id'],enabled=True,digest=digest(packages/name))
            if name=='companion-c':cfg.update(grants=dict(overlay=True),placement=dict(mode='overlay',x=80,y=120,width=160,height=128))
            entries.append(cfg)
        config=Path(s.env['XDG_CONFIG_HOME'])/'pearl/preferences.json';config.parent.mkdir(exist_ok=True)
        config.write_text(json.dumps(dict(plugins=dict(entries=entries),bar=dict(groups=dict(left='launcher,workspaces',center='plugin:pearl.timer-c/main',right='plugin:pearl.counter-rust/main,plugin:pearl.counter-zig/main,control')))))
        if not args.runtime_disabled:
            s.args=SimpleNamespace(aqueous_source=str(ROOT/'.cache/aqueous-master/source'));T00Session.input_fixture(s)
        ipc=IPC(s)
        shell=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
        def listed():return ctl(s,args.ctl,'plugins','list')['result']
        if args.runtime_disabled:
            wait_for(lambda:len((v:=listed())['packages'])==4 and all(x['status']=='unavailable' and x['error_code']=='PluginRuntimeNotBuilt' and x['generation']==0 for x in v['packages']))
            ctl(s,args.ctl,'quit');clean(shell);ipc.close();print('PASS runtime-disabled preserves approvals without launching helpers');return
        try:wait_for(lambda:len((v:=listed())['packages'])==4 and all(x['status']=='active' for x in v['packages']),20)
        except Exception:print('PLUGIN STATUS',listed(),ctl(s,args.ctl,'lifecycle','status'),flush=True);raise
        checks.append('four-real-components-active-in-shell-invalid-png-isolated')
        app=s.child('settings',[args.settings,'--page','plugins'],G_DEBUG='fatal-warnings');app.expect('event=settings-window-created')
        wait_for(lambda:(v:=probe(s,ipc))['page']=='plugins' and v['editor']['ready'])
        wait_for(lambda:any(c['field']=='pearl.timer-c/enabled' for c in probe(s,ipc)['controls']))
        peer=Peer(s,ipc);peer.enter('plugins')
        page=peer.page();assert len(page['live']['plugins'])==4,page
        assert '1 rejected' in page['live']['summary'],page
        assert any(x['page']=='plugins' for x in probe(s,ipc)['links'])
        capture(s,'plugins-main-settings',next(x['name'] for x in ipc.state() if x['kind']=='output'))
        checks.append('main-settings-page-and-live-registry')
        generations={x['id']:x['generation'] for x in listed()['packages']}
        requested=listed()['requested'];ready(s,ipc);click(s,ipc,'plugins.refresh')
        wait_for(lambda:listed()['completed']>requested and not listed()['pending'])
        assert {x['id']:x['generation'] for x in listed()['packages']}==generations
        checks.append('actual-settings-refresh-button-preserves-all-instances')
        # Unrelated row focus and retained edits survive another package update.
        ready(s,ipc);click(s,ipc,'pearl.counter-rust/enabled')
        wait_for(lambda:peer.state()['dirty'])
        draft_before=peer.document()
        ready(s,ipc)
        # GtkSwitch pointer toggles do not necessarily move keyboard focus.
        for _ in range(80):
            if next(c for c in probe(s,ipc)['controls'] if c['field']=='pearl.counter-rust/enabled')['focused']: break
            s.run(['wtype','-k','Tab'])
        else: raise AssertionError('could not focus the retained plugin row')
        timer_manifest=packages/'timer-c/plugin.json';manifest_bytes=timer_manifest.read_bytes()
        timer_manifest.write_text(json.dumps(json.loads(manifest_bytes) | dict(version='focus-test')))
        wait_for(lambda:next(x for x in listed()['packages'] if x['id']=='pearl.timer-c').get('error_code')=='PluginApprovalRequired')
        time.sleep(.6)
        assert next(c for c in probe(s,ipc)['controls'] if c['field']=='pearl.counter-rust/enabled')['focused'], [c['field'] for c in probe(s,ipc)['controls'] if c['focused']]
        assert peer.document()==draft_before
        timer_manifest.write_bytes(manifest_bytes)
        wait_for(lambda:next(x for x in listed()['packages'] if x['id']=='pearl.timer-c')['status']=='active')
        assert peer.action('discard')['state']=='succeeded'
        ready(s,ipc)
        checks.append('unrelated-row-focus-and-unsaved-values-survive-update')
        response=ctl(s,args.ctl,'control-center','show','--page','plugins',code=2)
        checks.append('flyout-rejects-plugins-route')
        response=peer.call('plugin.action',view=peer.view,operation=uuid.uuid4().hex,id='pearl.companion',action='preview');assert response['ok'],response
        ready(s,ipc);click(s,ipc,'pearl.timer-c/enabled')
        wait_for(lambda:peer.state()['dirty'])
        assert next(x for x in listed()['packages'] if x['id']=='pearl.timer-c')['status']=='active'
        click(s,ipc,'apply')
        wait_for(lambda:next(x for x in listed()['packages'] if x['id']=='pearl.timer-c')['status']=='disabled')
        checks.append('disable-through-settings-draft-apply')
        # Retry failure stays isolated; a changed package cannot reuse approval.
        timer=packages/'timer-c/plugin.wasm';original=timer.read_bytes();timer.write_bytes(original+b'changed')
        candidate=json.loads(peer.document());next(x for x in candidate['plugins']['entries'] if x['id']=='pearl.timer-c')['enabled']=True
        peer.keep(json.dumps(candidate));assert peer.action('apply')['state']=='succeeded'
        wait_for(lambda:next(x for x in listed()['packages'] if x['id']=='pearl.timer-c')['status'] in ('failed','unavailable'))
        assert all(x['status']=='active' for x in listed()['packages'] if x['id']!='pearl.timer-c')
        timer.write_bytes(original)
        response=peer.call('plugin.action',view=peer.view,operation=uuid.uuid4().hex,id='pearl.timer-c',action='retry');assert response['ok'],response
        wait_for(lambda:all(x['status']=='active' for x in listed()['packages']))
        checks.append('changed-package-failure-isolated-explicit-retry')
        before={x['id']:x['generation'] for x in listed()['packages']}
        fixture.proc.stdin.write('{"active":false}\n');fixture.proc.stdin.flush()
        wait_for(lambda:all(x['status']=='suspended' and x['nodes']==0 for x in listed()['packages']))
        fixture.proc.stdin.write('{"active":true}\n');fixture.proc.stdin.flush()
        wait_for(lambda:all(x['status']=='active' and x['generation']>before[x['id']] for x in listed()['packages']))
        checks.append('inactive-session-clears-scenes-and-restarts-new-generations')
        peer.close();ctl(s,args.ctl,'quit');clean(shell)
        app.signal();app.wait(timeout=5);ipc.close()
    print(json.dumps(dict(status='passed',checks=checks),indent=2))
if __name__=='__main__':main()
