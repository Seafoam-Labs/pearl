#!/usr/bin/env python3
"""Native acceptance for custom launcher association, pins and unavailable entries."""
import argparse
import hashlib
import json
import sys
import time
from pathlib import Path
from types import SimpleNamespace
from PIL import Image
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'scripts'))
from pearl_session import PrivateSession, wait_for
from t00 import Session as T00Session
from test_surfaces import IPC, ctl, status, eventually_status, capture, click
from test_desktop import keys, entries, FIXTURE
from test_preferences import settled, apply


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, required=True)
    parser.add_argument('--ctl', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/dock-desktop-overrides/fix')
    args = parser.parse_args()
    for name in ('pearl', 'ctl', 'output'):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(status='running', checks={}, pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest())
    def passed(name):
        report['checks'][name] = True
        print('PASS', name, flush=True)
    try:
        with PrivateSession(args.output/'session') as s:
            s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path='+str(s.runtime/'system-bus')
            s.child('system-bus', ['dbus-daemon', '--session', '--nofork', '--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda: s.run(['busctl', '--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'], 'list'], check=False).returncode == 0)
            s.env['PEARL_SECURITY_LOG'] = str(s.output/'security.jsonl')
            Path(s.env['PEARL_SECURITY_LOG']).write_text('')
            authority = s.child('authority', ['python3', ROOT/'tests/fixtures/session_security.py'], input_pipe=True)
            authority.expect('event=ready')
            s.args = SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous')
            T00Session.input_fixture(s)
            system = s.base/'system-data'
            user = Path(s.env['XDG_DATA_HOME'])
            for root in (system, user):
                (root/'applications').mkdir(parents=True, exist_ok=True)
            s.env['XDG_DATA_DIRS'] = str(system)
            s.env['PEARL_TEST_LAUNCH_LOG'] = str(s.output/'launches.jsonl')
            Path(s.env['PEARL_TEST_LAUNCH_LOG']).write_text('')
            icons = {}
            for name, rgb in [('system', (250, 17, 5)), ('custom', (5, 245, 31))]:
                icons[name] = s.base/(name+'.png')
                Image.new('RGB', (64, 64), rgb).save(icons[name])
            app_id = 'org.pearl.Override'
            system_id = app_id+'.desktop'
            custom_id = 'Custom Override 私用.desktop'
            def write(root, identifier, mark):
                path = root/'applications'/identifier
                path.write_text(f'[Desktop Entry]\nType=Application\nName=Override {mark}\n'
                    f'Exec=/usr/bin/python3 {FIXTURE} --id {app_id} --mark {mark} --title "Override {mark}" --custom-argument "{mark} two words"\n'
                    f'Icon={icons[mark]}\nDBusActivatable=false\nActions=Special;\n\n'
                    f'[Desktop Action Special]\nName=Special {mark}\nExec=/usr/bin/python3 {FIXTURE} --id {app_id} --mark {mark}-action\n')
                return path
            write(system, system_id, 'system')
            custom = write(user, custom_id, 'custom')
            ipc = IPC(s)
            def start(name):
                app = s.child(name, [args.pearl], G_DEBUG='fatal-warnings')
                app.expect('event=control-ready')
                app.expect('event=app-index-ready')
                eventually_status(s, args.ctl, lambda v: len(v['outputs']) == 2 and v['apps']['ready'])
                return app
            app = start('pearl')
            first = status(s, args.ctl)['outputs'][0]
            oid = first['id']
            def prefs():return settled(s, args.ctl)['preferences']
            p = prefs()
            p['dock']['mode'] = 'always'
            p['bar']['groups']['left'] = 'launcher,workspaces,running_apps'
            apply(s, args.ctl, p)
            def windows():return [w for w in ipc.state() if w['kind'] == 'window' and w.get('app_id') == app_id]
            def close_windows():
                for win in windows():ipc.call('command', action='window.close', fields=dict(id=win['id']))
                wait_for(lambda: not windows())
                time.sleep(.2)
            def external_launch():
                child = s.child('external-'+str(len(entries(s))), ['python3', '-c',
                    'import sys; from gi.repository import Gio; assert Gio.DesktopAppInfo.new(sys.argv[1]).launch([],None)', custom_id])
                win = wait_for(lambda: next(iter(windows()), None))
                ipc.call('command', action='window.move', fields=dict(id=win['id'], output=oid))
                time.sleep(.3)
                return child
            def show_dock():
                ctl(s, args.ctl, 'dock', 'show', '--output', oid)
                time.sleep(.2)
            def open_picker(unavailable=False):
                show_dock()
                keys(s, 'Menu', *(['Down']*(1 if unavailable else 3)), 'space')
                eventually_status(s, args.ctl, lambda v: v['popup'] is not None and v['popup']['pane'] == 'launcher_picker')
                time.sleep(.2)
            def probe():return ctl(s, args.ctl, 'aqueous', 'status', '--text', 'test-launcher-picker')['result']
            def click_control(identifier):
                row = wait_for(lambda: next((r for r in probe()['rows'] if r['id'] == identifier and r['rect']['width'] > 0), None))
                assert row['enabled'], row
                rect = row['rect']; out = ipc.outputs()[oid]
                click(s, out['usable_bounds']['x']+rect['x']+rect['width']/2,
                      out['usable_bounds']['y']+rect['y']+rect['height']/2, ipc.outputs())
            def choose(identifier=custom_id, keyboard=False):
                s.run(['wtype', identifier])
                wait_for(lambda: any(r['id'] == identifier for r in probe()['rows']))
                if keyboard:
                    for _ in range(12):
                        keys(s, 'Tab')
                        if any(r['id']==identifier and r['focused'] for r in probe()['rows']):break
                    else:raise AssertionError('Launcher row not keyboard reachable')
                    keys(s, 'space')
                else:click_control(identifier)
                assert probe()['selected'] == identifier
                capture(s, 'launcher-picker', first['connector'])
                if keyboard:
                    for _ in range(12):
                        keys(s, 'Tab')
                        if any(r['id']=='apply' and r['focused'] for r in probe()['rows']):break
                    else:raise AssertionError('Apply not keyboard reachable')
                    keys(s, 'Return')
                else:click_control('apply')
                wait_for(lambda: status(s, args.ctl)['popup'] is None)
                return prefs()
            def icon(name, expected='custom'):
                show_dock()
                image = capture(s, name, first['connector'])
                out = next(o for o in status(s, args.ctl)['outputs'] if o['id'] == oid)
                r = out['dock']['rect']; b = out['bounds']
                crop = image.crop((r['x']-b['x'], r['y']-b['y'], r['x']-b['x']+r['width'], r['y']-b['y']+r['height']))
                crop.save(s.output/(name+'-dock.png'))
                rgb = (5,245,31) if expected == 'custom' else (250,17,5)
                count = sum(max(abs(p[i]-rgb[i]) for i in range(3)) < 12 for p in crop.get_flattened_data())
                assert count > 1000, (name, count)
                keys(s, 'Escape')
            def launch(menu=False, action=False):
                before = len(entries(s))
                show_dock()
                if menu or action:keys(s, 'Menu')
                if action:keys(s, 'Down', 'Down')
                keys(s, 'space')
                wait_for(lambda: len(entries(s)) > before)
                value = entries(s)[-1]
                assert value['mark'] == ('custom-action' if action else 'custom'), value
                assert value['desktop_file'].endswith('/'+custom_id), value
                if not action:assert value['argv'] == ['--custom-argument', 'custom two words'], value
                wait_for(lambda: bool(windows()))
                for win in windows():ipc.call('command', action='window.move', fields=dict(id=win['id'], output=oid))
                keys(s, 'Escape', 'Escape')
            external_launch()
            ctl(s, args.ctl, 'dock', 'pin', '--text', system_id)
            settled(s, args.ctl)
            open_picker()
            p = choose()
            assert p['pinned_apps'] == [custom_id], p['pinned_apps']
            assert p['application_launchers'] == [dict(backend='xdg', identity=app_id, desktop_id=custom_id)]
            icon('custom-running')
            task = ctl(s, args.ctl, 'aqueous', 'status', '--text', 'test-running-apps')['result']
            assert [g['key'] for g in task['groups']] == ['desktop:'+custom_id], task
            assert all(o['dock']['groups'] == 1 for o in status(s,args.ctl)['outputs'])
            passed('native-picker-corrects-packaged-pin-and-global-grouping')
            close_windows();launch();icon('custom-relaunched')
            launch(menu=True);launch(action=True)
            passed('custom-id-icon-arguments-new-window-and-desktop-action')
            close_windows();app.stop();app = start('pearl-restarted')
            assert prefs()['pinned_apps'] == [custom_id]
            launch();icon('custom-after-restart')
            passed('association-and-pin-survive-restart')
            open_picker();click_control('reset')
            wait_for(lambda: status(s,args.ctl)['popup'] is None)
            p = prefs();assert p['application_launchers'] == [] and p['pinned_apps'] == [custom_id]
            passed('reset-keeps-explicit-pin')
            # Keep the system pin first so the picker is opened on its running group.
            p['pinned_apps'] = [system_id, custom_id];apply(s,args.ctl,p)
            open_picker();p=choose(keyboard=True)
            assert p['pinned_apps'] == [custom_id]
            passed('keyboard-selection-and-existing-target-pin-deduplication')
            # A concurrent edit must not be overwritten by an old picker.
            open_picker()
            p=prefs();p['font_size']=15;apply(s,args.ctl,p)
            click_control('reset');time.sleep(.2)
            assert status(s,args.ctl)['popup'] is not None
            assert prefs()['application_launchers'][0]['desktop_id'] == custom_id
            keys(s,'Escape')
            passed('stale-picker-rejects-concurrent-preference-edit')
            # An open menu must not keep launching its old association.
            show_dock();keys(s,'Menu')
            before=len(entries(s))
            p=prefs();p['application_launchers'][0]['desktop_id']=system_id;apply(s,args.ctl,p)
            keys(s,'space');time.sleep(.3)
            assert len(entries(s))==before
            keys(s,'Escape','Escape')
            p=prefs();p['application_launchers'][0]['desktop_id']=custom_id;apply(s,args.ctl,p)
            passed('open-menu-rejects-stale-launcher-action')

            # Missing chosen entries remain selected; clicking cannot launch system.
            close_windows()
            generation=status(s,args.ctl)['apps']['generation'];custom.unlink()
            eventually_status(s,args.ctl,lambda v:v['apps']['generation']>generation)
            before=len(entries(s));show_dock();keys(s,'space');time.sleep(.3)
            assert len(entries(s))==before and prefs()['pinned_apps']==[custom_id]
            assert prefs()['application_launchers'][0]['desktop_id']==custom_id
            open_picker(unavailable=True)
            assert not next(r for r in probe()['rows'] if r['id']=='apply')['enabled']
            keys(s,'Escape')
            generation=status(s,args.ctl)['apps']['generation'];write(user,custom_id,'custom')
            eventually_status(s,args.ctl,lambda v:v['apps']['generation']>generation)
            launch();icon('custom-reinstalled')
            passed('missing-launcher-never-falls-back-and-reinstall-recovers')
            close_windows()
            generation=status(s,args.ctl)['apps']['generation']
            custom.write_text(custom.read_text().replace('DBusActivatable=false','DBusActivatable=false\nHidden=true'))
            eventually_status(s,args.ctl,lambda v:v['apps']['generation']>generation)
            before=len(entries(s));show_dock();keys(s,'space');time.sleep(.3)
            assert len(entries(s))==before and prefs()['application_launchers'][0]['desktop_id']==custom_id
            generation=status(s,args.ctl)['apps']['generation'];write(user,custom_id,'custom')
            eventually_status(s,args.ctl,lambda v:v['apps']['generation']>generation)
            launch()
            passed('hidden-selection-does-not-launch-packaged-entry')

            open_picker()
            authority.proc.stdin.write(json.dumps(dict(active=False))+'\n');authority.proc.stdin.flush()
            wait_for(lambda:status(s,args.ctl)['popup'] is None)
            authority.proc.stdin.write(json.dumps(dict(active=True))+'\n');authority.proc.stdin.flush()
            passed('inactive-session-dismisses-picker')
            eventually_status(s,args.ctl,lambda v: all(o['dock']['reason']!='locked' for o in v['outputs']))
            close_windows()
            p=prefs();p['application_launchers']=[];p['pinned_apps']=[];apply(s,args.ctl,p)
            external_launch();open_picker();p=choose()
            assert p['pinned_apps']==[]
            show_dock();keys(s,'Menu','Down','space')
            assert prefs()['pinned_apps']==[custom_id]
            close_windows();launch()
            passed('unpinned-choice-then-native-pin-keeps-custom-launcher')
            second_output=next(o['id'] for o in status(s,args.ctl)['outputs'] if o['id']!=oid)
            other=s.child('other-output',['python3',FIXTURE,'--id',app_id,'--title','Other output'])
            other.expect('event=fixture-ready')
            other_window=wait_for(lambda:next((w for w in windows() if w['title']=='Other output'),None))
            ipc.call('command',action='window.move',fields=dict(id=other_window['id'],output=second_output))
            time.sleep(.3)
            task=ctl(s,args.ctl,'aqueous','status','--text','test-running-apps')['result']
            assert len(task['groups'])==1 and task['groups'][0]['key']=='desktop:'+custom_id and task['groups'][0]['count']==2,task
            assert all(o['dock']['groups']==1 for o in status(s,args.ctl)['outputs'])
            passed('association-groups-windows-on-two-outputs')
            p=prefs();p['font_size']=20;apply(s,args.ctl,p)
            s.run(['wlr-randr','--output',first['connector'],'--custom-mode','640x480@60Hz'])
            eventually_status(s,args.ctl,lambda v:next(o for o in v['outputs'] if o['id']==oid)['bounds']['width']==640)
            open_picker();choose(keyboard=True)
            passed('small-output-large-text-keyboard-picker')
            close_windows();ipc.close()
            report['status']='passed'
    except Exception as exc:
        report['status']='failed';report['error']=repr(exc)
        raise
    finally:
        (args.output/'results.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__ == '__main__':main()
