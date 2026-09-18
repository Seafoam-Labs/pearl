#!/usr/bin/env python3
"""Real compositor ingress -> Pearl broker -> Wasm -> GTK, on a private display.
The diagnostic compositor source is pinned; its owner override is test-only.
Never inject input into a user's compositor or import their service environment.
"""
import argparse, json, os, shlex, shutil, signal, socket, time, uuid
from pathlib import Path
from test_settings_app import ROOT, PrivateSession, IPC, ctl, wait_for, clean
from test_settings_services import Peer
from test_plugin_host import digest


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--samples',type=int,default=24)
    parser.add_argument('--pam-module',type=Path,help='Also exercise overlapping polkit/lock with a private PAM fixture')
    parser.add_argument('--locker',type=Path,default=ROOT/'zig-out/test/pearl-lock-test')
    parser.add_argument('--stall-ack',action='store_true')
    parser.add_argument('--prefix',type=Path,default=ROOT/'.cache/aqueous-activity')
    parser.add_argument('--pearl',type=Path,default=ROOT/'zig-out/test/pearl-integration')
    parser.add_argument('--ctl',type=Path,default=ROOT/'zig-out/bin/pearlctl')
    parser.add_argument('--examples',type=Path,default=ROOT/'.cache/plugin-examples')
    parser.add_argument('--output',type=Path,default=ROOT/'.cache/activity-session')
    args=parser.parse_args()
    for key,value in vars(args).items():
        if isinstance(value,Path): setattr(args,key,value.resolve())
    (args.output/'metadata.json').unlink(missing_ok=True)
    assert args.samples>=12
    policy=json.loads((args.prefix/'share/aqueous/build-policy.json').read_text())
    assert policy['input_activity_testing'], 'Requires the separate diagnostic Aqueous build'
    control, inherited=socket.socketpair();control.settimeout(5)
    checks=[];latencies=[]
    with PrivateSession(args.output,tool_prefix=args.prefix,
                        compositor_args=['-input-activity-test-fd',str(inherited.fileno())],compositor_fds=[inherited.fileno()]) as s:
        inherited.close()
        def inject(command):
            control.sendall((command+'\n').encode());assert control.recv(96)==b'ok\n',command
        def press(command='key 0 30'):
            inject(command+' 1');inject(command+' 0')
        s.env['DBUS_SYSTEM_BUS_ADDRESS']='unix:path='+str(s.runtime/'system-bus')
        s.child('system-bus',['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
        wait_for(lambda:s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
        if args.pam_module:
            pam=s.base/'pam';pam.mkdir()
            (pam/'pearl').write_text(f'auth required {args.pam_module}\naccount required {args.pam_module}\n')
            s.env.update(PEARL_TEST_PAM_DIR=str(pam),PEARL_TEST_LOCKER=str(args.locker))
        s.env['PEARL_SECURITY_LOG']=str(s.output/'security.jsonl')
        authority=s.child('authority',['python3',ROOT/'tests/fixtures/session_security.py'],input_pipe=True);authority.expect('event=ready')
        packages=Path(s.env['XDG_DATA_HOME'])/'pearl/plugins';packages.mkdir(parents=True)
        entries=[]
        for name in ('companion-c','timer-c','activity-fixture'):
            shutil.copytree(args.examples/name,packages/name)
            manifest=json.loads((packages/name/'plugin.json').read_text())
            cfg=dict(id=manifest['id'],enabled=True,digest=digest(packages/name))
            if name=='companion-c':cfg.update(grants=dict(input_activity=True,overlay=True),placement=dict(mode='overlay',x=80,y=120,width=160,height=128))
            if name=='activity-fixture': cfg['grants']=dict(input_activity=True)
            entries.append(cfg)
        config=Path(s.env['XDG_CONFIG_HOME'])/'pearl/preferences.json';config.parent.mkdir(exist_ok=True)
        config.write_text(json.dumps(dict(plugins=dict(entries=entries))))
        if args.stall_ack: s.env['PEARL_TEST_ACTIVITY_STALL_ACK']='1'
        ipc=IPC(s)
        # Stop before exec so the diagnostic compositor can pin this exact PID.
        # The real launcher still obtains/transfers/consumes the actual capability.
        command='kill -STOP $$; exec '+shlex.quote(str(args.prefix/'bin/aqueous-activity-launch'))+' '+shlex.quote(str(args.pearl))
        shell=s.child('pearl',['bash','-c',command],G_DEBUG='fatal-warnings')
        wait_for(lambda:'\nState:\tT' in Path(f'/proc/{shell.proc.pid}/status').read_text())
        inject(f'owner {shell.proc.pid}')
        os.kill(shell.proc.pid,signal.SIGCONT)
        shell.expect('event=control-ready')
        def listed(): return ctl(s,args.ctl,'plugins','list')['result']
        def fixture(): return next(p for p in listed()['packages'] if p['id']=='pearl.activity-fixture')
        def cat(): return next(p for p in listed()['packages'] if p['id']=='pearl.companion')
        def wait_cat(predicate):
            try: return wait_for(lambda:(lambda v:v if predicate(v) else None)(cat()),15)
            except Exception: print('ACTIVITY STATUS',listed(),ctl(s,args.ctl,'lifecycle','status'),flush=True);raise
        wait_cat(lambda v:v['status']=='active' and v['input_activity']=='available' and v['activity_requested'])
        checks.append('authorized-shared-display-ready')
        # A separate GTK application is focused; physical fixture events follow
        # the real ingress callbacks rather than invoking Pearl Preview.
        app=s.child('application',['zenity','--entry','--title=Activity acceptance','--text=Type here'])
        wait_for(lambda:any(w['kind']=='window' and w.get('title')=='Activity acceptance' for w in ipc.state()))
        assert b'AQUEOUS_INPUT_ACTIVITY_FD=' not in Path(f'/proc/{app.proc.pid}/environ').read_bytes()
        assert not any('memfd:aqueous-activity' in os.readlink(fd) for fd in Path(f'/proc/{shell.proc.pid}/fd').iterdir())
        checks.append('capability-consumed-and-not-inherited')
        time.sleep(.2)
        for _ in range(args.samples):
            before=cat()['test_activity']['events'];start=time.monotonic_ns()//1000
            press()
            value=wait_cat(lambda v:v['test_activity']['events']>before and v['test_activity']['painted_us']>=start)
            assert value['test_activity']['scene']['nodes'][0]['clip'] in ('tap-left','tap-right'),value
            latencies.append((value['test_activity']['painted_us']-start)/1000)
            time.sleep(.12)
        checks.append('other-application-keyboard-to-painted-cat')
        before=cat()['test_activity']['events'];press('button 0 272')
        wait_cat(lambda v:v['test_activity']['events']>before)
        checks.append('physical-pointer-button-ingress')
        def quiet(command):
            time.sleep(.2);before=cat()['test_activity']['events'];command();time.sleep(.35)
            assert cat()['test_activity']['events']==before,cat()
        quiet(lambda:press('key 1 30')) # virtual device excluded
        inject('key 0 31 1');time.sleep(.25)
        quiet(lambda:inject('key 0 31 1'));inject('key 0 31 0')
        checks.append('virtual-and-held-repeat-excluded')
        peer=Peer(s,ipc);peer.enter('plugins')
        def configure(change):
            value=json.loads(peer.document());change(value);peer.keep(json.dumps(value));assert peer.action('apply')['state']=='succeeded'
        def cat_config(value): return next(c for c in value['plugins']['entries'] if c['id']=='pearl.companion')
        before=fixture()['test_activity']['events'];press()
        wait_for(lambda:fixture()['test_activity']['events']>before)
        response=peer.call('plugin.action',view=peer.view,operation=uuid.uuid4().hex,id='pearl.activity-fixture',action='preview')
        assert response['ok'],response
        wait_for(lambda:not fixture()['activity_requested'])
        time.sleep(.2);before=fixture()['test_activity']['events'];cat_before=cat()['test_activity']['events'];press()
        wait_cat(lambda v:v['test_activity']['events']>cat_before)
        assert fixture()['test_activity']['events']==before
        response=peer.call('plugin.action',view=peer.view,operation=uuid.uuid4().hex,id='pearl.activity-fixture',action='preview')
        assert response['ok'],response
        wait_for(lambda:fixture()['activity_requested'])
        configure(lambda v:next(c for c in v['plugins']['entries'] if c['id']=='pearl.activity-fixture')['grants'].update(input_activity=False))
        wait_for(lambda:fixture()['status']=='active' and not fixture()['activity_requested'])
        before=cat()['test_activity']['events'];press()
        wait_cat(lambda v:v['test_activity']['events']>before)
        checks.append('shared-source-unsubscribe-and-independent-grant-revocation')
        configure(lambda v:cat_config(v)['grants'].update(input_activity=False))
        wait_cat(lambda v:v['status']=='active' and v['input_activity']=='permission-denied')
        quiet(press)
        assert 'no granted plugin has subscribed' in listed()['input_activity_reason'],listed()
        configure(lambda v:cat_config(v)['grants'].update(input_activity=True))
        wait_cat(lambda v:v['status']=='active' and v['input_activity']=='available')
        checks.append('saved-grant-revocation-and-fresh-resubscription')
        def authority_command(value): authority.proc.stdin.write(json.dumps(value)+'\n');authority.proc.stdin.flush()
        auth_start=time.monotonic()
        authority_command({'begin':True})
        wait_cat(lambda v:v['status']=='suspended' and v['nodes']==0)
        press();time.sleep(.2)
        assert cat()['nodes']==0
        shell.expect('event=activity-auth-presented')
        auth_delay=time.monotonic()-auth_start
        if args.stall_ack: assert .45 <= auth_delay < 2,auth_delay
        checks.append('bounded-inhibit-timeout' if args.stall_ack else 'acknowledged-inhibit-before-authentication')
        # Retire and restore a package while authentication owns the privacy gate.
        # This must preserve the session's authorized Aqueous manager and discard
        # input queued for either retired helper generation.
        cat_manifest=packages/'companion-c/plugin.json'
        original_manifest=cat_manifest.read_bytes()
        updated=json.loads(original_manifest);updated['version']='privacy-refresh'
        cat_manifest.write_text(json.dumps(updated))
        ticket=ctl(s,args.ctl,'plugins','refresh')['result']['requested']
        wait_for(lambda:listed()['completed']>=ticket)
        wait_cat(lambda v:v['version']=='privacy-refresh' and v['status']=='suspended' and v['nodes']==0)
        press()
        cat_manifest.write_bytes(original_manifest)
        ticket=ctl(s,args.ctl,'plugins','refresh')['result']['requested']
        wait_for(lambda:listed()['completed']>=ticket)
        wait_cat(lambda v:v['version']==json.loads(original_manifest)['version'] and v['status']=='suspended' and v['nodes']==0)
        checks.append('replacement-and-restore-during-auth-preserve-privacy-and-authorized-broker')
        authority_command({'cancel':True})
        wait_cat(lambda v:v['status']=='active' and v['input_activity']=='available')
        quiet(lambda:None)
        checks.append('polkit-inhibition-and-no-post-auth-replay')
        if args.pam_module:
            authority_command({'begin':True})
            wait_cat(lambda v:v['status']=='suspended' and v['nodes']==0)
            ctl(s,args.ctl,'lifecycle','action','--text','lock')
            wait_for(lambda:ctl(s,args.ctl,'lifecycle','status')['result']['lock']['ready'])
            press();time.sleep(.2);assert cat()['nodes']==0
            s.run(['wtype','-s','200','-M','ctrl','a','-m','ctrl','-k','BackSpace','fixture-user','-k','Return','-s','300','fixture-secret','-k','Return'])
            wait_cat(lambda v:v['status']=='active' and v['input_activity']=='available')
            quiet(lambda:None)
            checks.append('overlapping-polkit-lock-and-native-unlock-no-replay')
        inject('active 0')
        wait_cat(lambda v:v['input_activity']=='suspended')
        quiet(press)
        inject('active 1')
        wait_cat(lambda v:v['input_activity']=='available')
        quiet(lambda:None)
        checks.append('compositor-session-suspension-and-fresh-readiness')
        def move_to_bar(value):
            cat_config(value)['placement']['mode']='bar'
            value['bar']['groups']['center']='plugin:pearl.companion/main'
        configure(move_to_bar)
        wait_cat(lambda v:v['status']=='active' and v['input_activity']=='available')
        time.sleep(.2);before=cat()['test_activity']['events'];start=time.monotonic_ns()//1000;press()
        wait_cat(lambda v:v['test_activity']['events']>before and v['test_activity']['painted_us']>=start)
        checks.append('live-activity-in-native-bar')
        configure(lambda v:v.update(reduced_motion=True))
        wait_cat(lambda v:v['status']=='active' and v['input_activity']=='available')
        before=cat()['test_activity']['events'];press()
        value=wait_cat(lambda v:v['test_activity']['events']>before)
        assert value['test_activity']['scene']['nodes'][0]['clip']=='idle',value
        checks.append('reduced-motion-still-pose')
        inject('revoke')
        wait_cat(lambda v:v['input_activity']=='permission-denied')
        quiet(press)
        assert app.proc.poll() is None
        checks.append('owner-revocation-keeps-gtk-display-alive')
        peer.close();ctl(s,args.ctl,'quit');clean(shell);ipc.close()
    control.close()
    ordered=sorted(latencies)
    result=dict(status='passed',checks=checks,latency_ms=dict(samples=len(ordered),median=ordered[len(ordered)//2],p95=ordered[(len(ordered)*95+99)//100-1],p99=ordered[(len(ordered)*99+99)//100-1],max=ordered[-1]),scope='diagnostic physical ingress; GTK after-paint, not hardware presentation')
    (args.output/'metadata.json').write_text(json.dumps(result,indent=2)+'\n')
    assert ordered[-1]<=350,result
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()
