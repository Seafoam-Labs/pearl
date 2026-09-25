#!/usr/bin/env python3
"""Coordinated Pearl/Aqueous window switcher in a disposable native session."""
import argparse, copy, json, re, sys, time
from pathlib import Path
from types import SimpleNamespace
from PIL import Image, ImageChops
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from t00 import Session as T00Session
from test_surfaces import IPC, ctl, status, capture, click, clean
from test_desktop import keys
from test_preferences import settled, apply

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pearl',type=Path,required=True);p.add_argument('--ctl',type=Path,required=True)
    p.add_argument('--prefix',type=Path,default=ROOT/'.cache/aqueous-switcher')
    p.add_argument('--output',type=Path,default=ROOT/'artifacts/window-switcher')
    args=p.parse_args()
    args.pearl=args.pearl.resolve();args.ctl=args.ctl.resolve();args.output.mkdir(parents=True,exist_ok=True)
    report={'status':'running','checks':[]}
    def passed(name): report['checks'].append(name); print('PASS',name,flush=True)
    try:
        with PrivateSession(args.output/'session',tool_prefix=args.prefix.resolve(),wm_extra='\n[keybinds]\nwindow_switcher_next = ["Super+Tab"]\nwindow_switcher_previous = ["Super+Shift+Tab"]\ncycle_focus = []\n') as s:
            s.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous');T00Session.input_fixture(s)
            ipc=IPC(s)
            shell=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
            prefs=copy.deepcopy(settled(s,args.ctl)['preferences'])
            prefs['bar']['groups']=dict(left='launcher,workspaces,window_switcher',center='clock',right='control')
            prefs['bar']['workspace_mode']='small';apply(s,args.ctl,prefs)
            outputs=status(s,args.ctl)['outputs'];first,second=outputs[:2];oid=first['id']
            def state():return ipc.state()
            def session():return next(e for e in state() if e['kind']=='session')
            def windows():return [e for e in state() if e['kind']=='window' and (e.get('app_id') or '').startswith('org.pearl.Tasks')]
            def focused():return next((w['id'] for w in windows() if w['focused']),None)
            def command(action,**fields):return ipc.call('command',action=action,fields=fields)
            def cycle(direction='next',output=oid):return ctl(s,args.ctl,'window-switcher',direction,'--output',output)
            def visible():return session().get('switcher_window')
            def hud():return status(s,args.ctl)['window_switcher']
            def bar():return ctl(s,args.ctl,'aqueous','status','--text','test-bar-layout:'+oid)['result']
            def widget():return next(x for x in bar()['items'] if x['name']=='window_switcher')
            spaces=[e for e in state() if e['kind']=='workspace']
            ws=next(e for e in spaces if e['output']==oid and e['active'])
            command('workspace.activate',id=ws['id'])
            cycle();assert visible() is None
            passed('empty-workspace-no-op')
            fixture=s.child('windows',['python3',ROOT/'tests/fixtures/desktop/task_windows.py','--groups','1','--windows','3','--animate']);fixture.expect('event=tasks-ready')
            wins=wait_for(lambda:(lambda v:v if len(v)==3 else None)(windows()))
            for w in wins:command('window.move',id=w['id'],workspace=ws['id'])
            command('window.activate',id=wins[0]['id']);wait_for(lambda:focused()==wins[0]['id'])
            time.sleep(.5)
            geometry={w['id']:(w['geometry'],w['layout'],w['fullscreen'],w['maximized']) for w in windows()}
            start=focused();visited=[]
            for _ in range(3):
                previous=focused();cycle();selected=wait_for(lambda:(lambda v:v if v and v!=previous else None)(focused()));visited.append(selected)
                wait_for(lambda:visible()==selected)
            assert len(set(visited))==3 and visited[-1]==start,visited
            value=wait_for(hud);assert value['keyboard_mode']=='none' and value['output']==oid,value
            passed('forward-visits-every-window-wraps-immediate-focus-and-nonkeyboard-hud')
            cycle('previous');wait_for(lambda:focused()==visited[-2])
            time.sleep(.35)
            scene=s.run(['aqueousctl','scene']).stdout
            (s.output/'native-stack-scene.txt').write_text(scene)
            (s.output/'native-stack-state.json').write_text(json.dumps(session(),indent=2))
            assert scene.count('overview card:')==3,scene
            capture(s,'native-stack',first['connector'])
            assert visible() is not None
            passed('reverse-wrap-and-native-capture')
            # Frame sequences verify compositor texture transforms, independently
            # from focus/state assertions. Capture each frame once, without retries.
            cycle()
            frames=[]
            for i,delay in enumerate([0,.08,.24]):
                time.sleep(delay)
                scene=s.run(['aqueousctl','scene']).stdout
                frames.append(re.findall(r'overview thumbnail buffer \[buffer\] (.*)',scene))
                s.run(['grim','-o',first['connector'],s.output/f'forward-{i}.png'])
            assert frames[0]!=frames[-1],frames
            cycle('previous')
            for i,delay in enumerate([0,.08,.24]):
                time.sleep(delay);s.run(['grim','-o',first['connector'],s.output/f'reverse-{i}.png'])
            before_live=Image.open(s.output/'reverse-2.png').convert('RGB')
            time.sleep(.2);s.run(['grim','-o',first['connector'],s.output/'live-update.png'])
            after_live=Image.open(s.output/'live-update.png').convert('RGB')
            center=(400,280,880,430)
            assert ImageChops.difference(before_live.crop(center),after_live.crop(center)).getbbox()
            passed('forward-reverse-animation-frame-sequences-and-live-client-textures')
            wait_for(lambda:visible() is None,timeout=3)
            previous=focused();cycle();wait_for(lambda:focused()==start)
            passed('idle-dismissal-preserves-ring-order')
            keys(s,'Escape');wait_for(lambda:visible() is None);assert focused()==start
            passed('escape-retains-selected-focus')
            # A physical button press must reach the bar without taking keyboard focus.
            rect=wait_for(lambda:(lambda v:v if v['width']>0 else None)(widget()['rect']))
            out=ipc.outputs()[oid]
            click(s,out['bounds']['x']+rect['x']+rect['width']/2,out['bounds']['y']+rect['y']+rect['height']/2,ipc.outputs())
            wait_for(lambda:focused()!=start);wait_for(hud)
            assert bar()['keyboard_mode']=='none'
            passed('native-bar-button-activates-without-keyboard-grab')
            before=focused();rect=wait_for(hud)['rect']
            click(s,rect['x']+rect['width']*.75,rect['y']+rect['height']-20,ipc.outputs())
            wait_for(lambda:focused()!=before)
            passed('native-hud-cycle-button-retains-input-through-release')
            cycle('dismiss');wait_for(lambda:visible() is None)
            before=focused()
            s.run(['wtype','-M','logo','-k','Tab','-m','logo'])
            wait_for(lambda:focused()!=before);wait_for(visible)
            s.run(['wtype','-M','logo','-M','shift','-k','Tab','-m','shift','-m','logo'])
            wait_for(lambda:focused()==before)
            passed('native-next-and-previous-keybindings-share-the-ring')
            cycle('dismiss');wait_for(lambda:visible() is None)
            before=focused()
            for _ in range(6):cycle()
            wait_for(lambda:focused()==before)
            assert len(windows())==3
            passed('rapid-six-press-burst-retains-logical-steps')
            keys(s,'a');wait_for(lambda:visible() is None)
            passed('typing-dismisses-presentation')
            assert {w['id']:(w['geometry'],w['layout'],w['fullscreen'],w['maximized']) for w in windows()}==geometry
            passed('client-geometry-and-layout-unchanged')
            # A fullscreen client remains fullscreen while its texture is scaled
            # into the deck; switching must not change the application's mode.
            full=windows()[0]['id']
            command('window.fullscreen',id=full,value=True)
            wait_for(lambda:next(w for w in windows() if w['id']==full)['fullscreen'])
            time.sleep(.4)
            modes={w['id']:(w['geometry'],w['fullscreen']) for w in windows()}
            selected=[]
            for _ in range(3):
                before=focused();cycle();selected.append(wait_for(lambda:(lambda v:v if v!=before else None)(focused())))
            assert len(set(selected))==3 and full in selected
            cycle('dismiss');wait_for(lambda:visible() is None)
            assert {w['id']:(w['geometry'],w['fullscreen']) for w in windows()}==modes
            command('window.fullscreen',id=full,value=False)
            wait_for(lambda:not next(w for w in windows() if w['id']==full)['fullscreen'])
            passed('fullscreen-membership-and-client-mode-preserved')
            cycle();wait_for(visible)
            external=next(w['id'] for w in windows() if w['id']!=focused())
            command('window.activate',id=external)
            wait_for(lambda:visible() is None and focused()==external)
            cycle();wait_for(visible)
            other_ws=next(e for e in spaces if e['output']==oid and e['id']!=ws['id'])
            command('workspace.activate',id=other_ws['id'])
            wait_for(lambda:visible() is None and hud() is None)
            command('workspace.activate',id=ws['id'])
            passed('external-focus-and-workspace-change-dismiss-presentation')
            previous_ids={w['id'] for w in windows()}
            extra=s.child('extra-window',['python3',ROOT/'tests/fixtures/desktop/task_windows.py','--groups','1','--windows','1'])
            extra.expect('event=tasks-ready');wait_for(lambda:len(windows())==4)
            added=next(w for w in windows() if w['id'] not in previous_ids)
            command('window.move',id=added['id'],workspace=ws['id'])
            reached=[]
            for _ in range(4):
                before=focused();cycle();reached.append(wait_for(lambda:(lambda v:v if v!=before else None)(focused())))
            assert len(set(reached))==4 and added['id'] in reached
            command('window.close',id=added['id']);wait_for(lambda:len(windows())==3);extra.stop()
            passed('new-windows-append-and-all-four-identities-remain-reachable')
            cycle('dismiss');wait_for(lambda:visible() is None)
            ctl(s,args.ctl,'layout','set','--output',oid,'--layout','tile')
            wait_for(lambda:(lambda v:v['value']=='tile' and not v['pending'])(status(s,args.ctl)['layout']))
            time.sleep(.4)
            tiled={w['id']:w['geometry'] for w in windows()}
            for _ in range(3):
                before=focused();cycle();wait_for(lambda:focused()!=before)
            cycle('dismiss');wait_for(lambda:visible() is None)
            assert {w['id']:w['geometry'] for w in windows()}==tiled
            passed('tiled-layout-keeps-client-geometry-through-full-cycle')
            ctl(s,args.ctl,'layout','set','--output',oid,'--layout','float')
            wait_for(lambda:(lambda v:v['value']=='float' and not v['pending'])(status(s,args.ctl)['layout']))
            prefs['reduced_motion']=True;apply(s,args.ctl,prefs);cycle();wait_for(visible);capture(s,'reduced-motion',first['connector'])
            prefs['bar']['edge']='left';apply(s,args.ctl,prefs);cycle();wait_for(visible);capture(s,'vertical-bar',first['connector'])
            passed('reduced-motion-and-vertical-bar')
            command('overview.show',output=oid)
            wait_for(lambda:session()['overview_output']==oid)
            time.sleep(.35)
            assert visible() is None
            assert s.run(['aqueousctl','scene']).stdout.count('overview card:')==3
            command('overview.hide')
            cycle();wait_for(visible)
            passed('overview-coexists-with-switcher-after-reduced-motion')
            cycle('dismiss');wait_for(lambda:visible() is None)
            other_ipc=IPC(s)
            other_ipc.call('command',action='switcher.next',fields={'output':oid,'workspace':ws['id']})
            wait_for(visible);other_ipc.close();wait_for(lambda:visible() is None)
            passed('request-connection-loss-releases-compositor-presentation')
            cycle();wait_for(visible)
            active=focused();command('window.close',id=active);wait_for(lambda:len(windows())==2);wait_for(lambda:visible() is None)
            cycle();wait_for(visible)
            passed('selected-window-close-cleans-up-and-resumes')
            remote=next(e for e in spaces if e['output']==second['id'] and e['active'])
            move=windows()[0]['id'];command('window.move',id=move,workspace=remote['id']);wait_for(lambda:visible() is None)
            before=focused();cycle();time.sleep(.15);assert visible() is None and focused()==before
            assert next(w for w in windows() if w['id']==move)['workspace']==remote['id']
            passed('one-window-no-op-and-other-display-exclusion')
            remaining=next(w for w in windows() if w['id']!=move)
            command('window.minimized',id=remaining['id'],value=True)
            cycle();assert visible() is None
            passed('minimized-windows-excluded')
            command('window.minimized',id=remaining['id'],value=False)
            command('window.move',id=move,workspace=ws['id'])
            command('window.activate',id=remaining['id']);cycle();wait_for(visible)
            locker=s.child('lock-fixture',[s.runtime/'input-fixture/input','lock'],input_pipe=True)
            locker.expect('locked');wait_for(lambda:session()['locked'])
            assert visible() is None
            wait_for(lambda:hud() is None)
            locker.proc.stdin.write('unlock\n');locker.proc.stdin.flush();locker.wait()
            wait_for(lambda:not session()['locked'])
            passed('session-lock-clears-scene-hud-and-input')
            cycle();wait_for(visible)
            protocol=Path('/home/zoey/RiderProjects/Aqueous/compositor/protocol/upstream/wlr-output-power-management-unstable-v1.xml')
            power_dir=s.runtime/'output-power';power_dir.mkdir()
            normalized=power_dir/'protocol.xml';normalized.write_text(protocol.read_text().replace('<?xml version="1.0" encoding="UTF-8"?>',''))
            s.run(['wayland-scanner','client-header',normalized,power_dir/'output-power.h'])
            s.run(['wayland-scanner','private-code',normalized,power_dir/'output-power.c'])
            s.run(['cc','-I'+str(power_dir),ROOT/'tests/fixtures/desktop/output_power.c',power_dir/'output-power.c','-lwayland-client','-o',power_dir/'output-power'])
            s.run([power_dir/'output-power',first['connector'],'off'])
            wait_for(lambda:visible() is None and hud() is None)
            assert len(status(s,args.ctl)['outputs'])==1
            passed('powered-off-output-releases-native-stack-and-hud')
            ipc.close();shell.stop();clean(shell)
        report['status']='passed'
    finally:
        (args.output/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
