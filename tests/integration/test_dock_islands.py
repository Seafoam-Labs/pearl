#!/usr/bin/env python3
"""T15: real GTK dock actions, Aqueous state, island input and private visual coverage."""
import argparse, copy, hashlib, json, sys, time
from pathlib import Path
from types import SimpleNamespace
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'scripts'))
from pearl_session import PrivateSession, wait_for
from t00 import Session as T00Session
from test_surfaces import IPC, ctl, status, eventually_status, capture, click, clean
from test_desktop import desktop, keys, entries, FIXTURE
from test_preferences import settled, apply


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, required=True)
    parser.add_argument('--ctl', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/t15/latest')
    args = parser.parse_args()
    args.pearl=args.pearl.resolve();args.ctl=args.ctl.resolve();args.output=args.output.resolve()
    args.output.mkdir(parents=True,exist_ok=True)
    checks={}; report=dict(status='running', checks=checks, pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(),ctl_sha256=hashlib.sha256(args.ctl.read_bytes()).hexdigest())
    try:
        with PrivateSession(args.output/'session') as s:
            s.env['DBUS_SYSTEM_BUS_ADDRESS']='unix:path='+str(s.runtime/'system-bus')
            s.child('system-bus',['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda:s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
            s.env['PEARL_SECURITY_LOG']=str(s.output/'security.jsonl');Path(s.env['PEARL_SECURITY_LOG']).write_text('')
            authority=s.child('authority',['python3',ROOT/'tests/fixtures/session_security.py'],input_pipe=True);authority.expect('event=ready')
            def authority_command(**data):
                authority.proc.stdin.write(json.dumps(data)+'\n');authority.proc.stdin.flush();time.sleep(.15)
            s.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous')
            keyboard=T00Session.input_fixture(s)
            s.env['XDG_DATA_DIRS']=str(s.base/'empty-system-data');Path(s.env['XDG_DATA_DIRS']).mkdir()
            s.env['PEARL_TEST_LAUNCH_LOG']=str(s.output/'launches.jsonl')
            Path(s.env['PEARL_TEST_LAUNCH_LOG']).write_text('')
            desktop(s,'Alpha','Alpha Editor','StartupWMClass=org.pearl.Alpha\n')
            desktop(s,'Beta','Beta Browser','StartupWMClass=org.pearl.Beta\n')
            ipc=IPC(s); original=ipc.outputs()
            app=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready');app.expect('event=app-index-ready')
            live=eventually_status(s,args.ctl,lambda v:len(v['outputs'])==2 and v['apps']['ready'])
            first,second=live['outputs']; oid=first['id']; other=second['id']
            def out():return next(o for o in status(s,args.ctl)['outputs'] if o['id']==oid)
            def dock_reason(reason):
                try:return eventually_status(s,args.ctl,lambda v:next(o for o in v['outputs'] if o['id']==oid)['dock']['reason']==reason)
                except Exception:
                    (s.output/'failed-status.json').write_text(json.dumps(status(s,args.ctl),indent=2));capture(s,'failed');raise
            assert first['islands'] and first['dock']['reason']=='empty'
            p=settled(s,args.ctl)['preferences'];p['bar']['groups']={'left':'launcher,workspaces','center':'clock','right':'control'}
            apply(s,args.ctl,p)
            ctl(s,args.ctl,'dock','pin','--output',oid,'--text','Alpha.desktop');settled(s,args.ctl)
            dock_reason('visible')
            assert all(o['dock']['groups']==1 for o in status(s,args.ctl)['outputs'])
            checks['default-islands-empty-dock-and-persistent-global-pin']=True
            ctl(s,args.ctl,'dock','show','--output',oid);keys(s,'space')
            wait_for(lambda:any(e['mark']=='Alpha' for e in entries(s)))
            windows=wait_for(lambda:[e for e in ipc.state() if e['kind']=='window' and e.get('app_id')=='org.pearl.Alpha'])
            win=windows[0];ipc.call('command',action='window.move',fields=dict(id=win['id'],output=oid))
            wait_for(lambda:out()['dock']['groups']==1)
            checks['keyboard-gio-launch-and-pinned-running-group']=True
            # A second real process of the same app stays in one taskbar group.
            second_app=s.child('alpha-two',['python3',FIXTURE,'--id','org.pearl.Alpha','--title','Second Alpha'])
            second_app.expect('event=fixture-ready')
            wins=wait_for(lambda:(lambda values:values if len(values)==2 else False)([e for e in ipc.state() if e['kind']=='window' and e.get('app_id')=='org.pearl.Alpha']))
            for win in wins:ipc.call('command',action='window.move',fields=dict(id=win['id'],output=oid))
            time.sleep(.3);assert out()['dock']['groups']==1
            beta=s.child('beta',['python3',FIXTURE,'--id','org.pearl.Beta','--title','Beta Browser']);beta.expect('event=fixture-ready')
            beta_window=wait_for(lambda:next((e for e in ipc.state() if e['kind']=='window' and e.get('app_id')=='org.pearl.Beta'),None))
            ipc.call('command',action='window.move',fields=dict(id=beta_window['id'],output=oid))
            wait_for(lambda:out()['dock']['groups']==2)
            rules=Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
            rules.write_text('[[window]]\napp_id = "org.pearl.Beta"\nskip_switcher = true\n')
            wait_for(lambda:any(e['kind']=='window' and e['id']==beta_window['id'] and e['skip_switcher'] for e in ipc.state()))
            assert out()['dock']['groups']==2
            rules.write_text('[[window]]\napp_id = "org.pearl.Beta"\nskip_taskbar = true\n')
            wait_for(lambda:out()['dock']['groups']==1)
            beta.stop();rules.write_text('')
            checks['taskbar-flags-are-independent-from-switcher-flags']=True
            # Actual visible fullscreen geometry hides just this output's dock.
            win=wins[0];ipc.call('command',action='window.fullscreen',fields=dict(id=win['id'],value=True))
            dock_reason('fullscreen')
            assert next(o for o in status(s,args.ctl)['outputs'] if o['id']==other)['dock']['reason']=='visible'
            # Pointer reveal is a real two-pixel layer surface at the output edge.
            bounds=out()['bounds'];click(s,bounds['x']+bounds['width']//2,bounds['y']+bounds['height']-1,ipc.outputs())
            dock_reason('interaction');capture(s,'fullscreen-reveal',first['connector'])
            click(s,bounds['x']+30,bounds['y']+bounds['height']//2,ipc.outputs());dock_reason('fullscreen')
            ipc.call('command',action='window.fullscreen',fields=dict(id=win['id'],value=False))
            checks['output-local-fullscreen-hiding-pointer-reveal-and-delay']=True
            # Minimized and inactive windows remain grouped, but do not obstruct.
            for win in wins:ipc.call('command',action='window.minimized',fields=dict(id=win['id'],value=True))
            dock_reason('visible');assert out()['dock']['groups']==1
            checks['minimized-windows-remain-on-dock']=True
            ctl(s,args.ctl,'dock','show','--output',oid);keys(s,'space')
            wait_for(lambda:any(e['kind']=='window' and e.get('app_id')=='org.pearl.Alpha' and not e['minimized'] for e in ipc.state()))
            checks['keyboard-window-activation-restores-minimized']=True
            active=next(e for e in ipc.state() if e['kind']=='window' and e.get('app_id')=='org.pearl.Alpha' and not e['minimized'])
            ipc.call('command',action='window.maximized',fields=dict(id=active['id'],value=True));dock_reason('overlap')
            ipc.call('command',action='window.maximized',fields=dict(id=active['id'],value=False));dock_reason('visible')
            checks['intelligent-hiding-follows-visible-outer-geometry']=True
            authority_command(active=False);dock_reason('locked')
            ctl(s,args.ctl,'dock','show','--output',oid,code=4)
            authority_command(active=True);dock_reason('visible')
            checks['inactive-session-hides-dock-and-rejects-reveal']=True
            ctl(s,args.ctl,'launcher','show','--output',oid)
            ctl(s,args.ctl,'dock','show','--output',oid);assert status(s,args.ctl)['popup'] is None
            ctl(s,args.ctl,'calendar','toggle','--output',oid);assert out()['dock']['reason']!='interaction'
            ctl(s,args.ctl,'popup','hide')
            checks['popup-dock-keyboard-arbitration']=True
            # Context menu has native GTK keyboard traversal and releases exclusive input.
            ctl(s,args.ctl,'dock','show','--output',oid);keys(s,'Tab','space');capture(s,'dock-actions',first['connector']);keys(s,'Escape','Escape')
            ctl(s,args.ctl,'dock','pin','--output',oid,'--text','Beta.desktop');settled(s,args.ctl)
            p=settled(s,args.ctl)['preferences'];p['dock']['mode']='always';apply(s,args.ctl,p)
            for variant in ('dark','light'):
                p['theme'].update(mode='static',variant=variant);apply(s,args.ctl,p);time.sleep(.4)
                capture(s,'islands-dock-'+variant)
            s.run(['wlr-randr','--output',second['connector'],'--scale','1.5'])
            time.sleep(.5);capture(s,'mixed-scale')
            p['font_size']=20
            # Schema uses font_size as a logical point size; all widgets remeasure.
            apply(s,args.ctl,p);time.sleep(.4);capture(s,'enlarged-text')
            for pane,args_ in [('launcher',['launcher','show']),('control',['control-center','show']),('calendar',['calendar','toggle']),('notifications',['notifications','toggle']),('media',['media','toggle']),('tray',['tray','toggle']),('settings',['settings','show']),('aqueous-settings',['aqueous','show']),('clipboard-capture',['clipboard','show'])]:
                ctl(s,args.ctl,*args_,'--output',oid);time.sleep(.25);capture(s,'large-'+pane,first['connector']);ctl(s,args.ctl,'popup','hide')
            checks['dark-light-mixed-scale-and-enlarged-surface-captures']=True
            custom=Path(s.env['XDG_DATA_HOME'])/'themes'/'Pearl-Islands'/'gtk-4.0';custom.mkdir(parents=True)
            (custom/'gtk.css').write_text('.background {background:#184a40;color:#ffffdd;} button {background:#664477;color:white;}')
            p['theme'].update(mode='gtk',gtk_name='Pearl-Islands');apply(s,args.ctl,p);time.sleep(.4);capture(s,'islands-dock-gtk',first['connector'])
            p['theme'].update(mode='static',variant='dark');apply(s,args.ctl,p)
            checks['arbitrary-gtk-theme-colors-with-island-geometry']=True
            # Split bar union leaves real gaps, instead of a full rectangular input area.
            probe=s.child('underlay',['python3',ROOT/'tests/fixtures/desktop/island-underlay.py'],LD_PRELOAD='libgtk4-layer-shell.so',G_DEBUG='fatal-warnings');probe.expect('event=underlay-ready')
            live=out();rects=[r for r in live['island_rects'] if r]
            assert len(rects)==3 and rects[0]['x']+rects[0]['width']<rects[1]['x']
            gap=(rects[0]['x']+rects[0]['width']+rects[1]['x'])//2
            before=sum('event=underlay-click' in line for line in probe.lines)
            click(s,live['bounds']['x']+gap,live['bounds']['y']+20,ipc.outputs())
            assert status(s,args.ctl)['popup'] is None
            wait_for(lambda:sum('event=underlay-click' in line for line in probe.lines)>before)
            probe.stop()
            checks['island-gaps-deliver-click-to-independent-underlay']=True
            # Output override changes orientation and resolves a shared bar edge.
            p['font_size']=14;p['outputs']=[dict(connector=first['connector'],bar=dict(edge='left',size=64,groups=p['bar']['groups']),dock=dict(edge='left',mode='autohide'))]
            apply(s,args.ctl,p);dock_reason('autohide');assert out()['dock']['edge']=='right'
            ctl(s,args.ctl,'dock','show','--output',oid);capture(s,'vertical-islands-dock',first['connector']);keys(s,'Escape');dock_reason('autohide')
            checks['per-output-vertical-layout-edge-conflict-and-escape']=True
            for i in range(14):desktop(s,f'Pinned{i}',f'Pinned application {i}')
            wait_for(lambda:status(s,args.ctl)['apps']['count']==16)
            p['pinned_apps']=['Alpha.desktop','Beta.desktop']+[f'Pinned{i}.desktop' for i in range(14)]
            p['outputs']=[];p['dock'].update(enabled=True,mode='always',icon_size=64);p['font_size']=24
            apply(s,args.ctl,p);time.sleep(.4);capture(s,'many-pins-large-text',first['connector'])
            assert out()['dock']['groups']==16 and out()['dock']['rect']['width']<=out()['bounds']['width']-32
            ctl(s,args.ctl,'dock','show','--output',oid);keys(s,*(['Tab']*30));capture(s,'many-pins-keyboard-scroll',first['connector']);keys(s,'Escape')
            checks['bounded-many-apps-scroll-and-keyboard-reveal']=True
            p['pinned_apps']=['Alpha.desktop','Beta.desktop'];p['dock']['icon_size']=40;p['font_size']=14
            p['outputs']=[];p['bar']['islands']=False;p['dock']['enabled']=False;apply(s,args.ctl,p)
            dock_reason('disabled');assert not out()['islands'];capture(s,'continuous-bar',first['connector'])
            checks['continuous-bar-and-disabled-dock-options']=True
            ctl(s,args.ctl,'dock','unpin','--output',oid,'--text','Alpha.desktop');settled(s,args.ctl)
            ctl(s,args.ctl,'dock','unpin','--output',oid,'--text','Beta.desktop');settled(s,args.ctl)
            assert settled(s,args.ctl)['preferences']['pinned_apps']==[]
            ctl(s,args.ctl,'quit');clean(app)
            wait_for(lambda:all(o['usable_bounds']==original[o['id']]['usable_bounds'] for o in ipc.outputs().values() if o['id'] in original and o['name']==first['connector']))
            checks['unpin-persistence-clean-exit-and-reservation-release']=True
            ipc.close()
        report['status']='passed'
    except Exception as exc:
        report.update(status='failed',error=repr(exc));raise
    finally:
        (args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
