#!/usr/bin/env python3
"""Issue #3 reproduction using a real dock and private user/system desktop roots."""
import argparse
import hashlib
import json
import sys
import time
from pathlib import Path
from types import SimpleNamespace

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from t00 import Session as T00Session
from test_surfaces import IPC, ctl, status, eventually_status, capture
from test_desktop import keys, entries, FIXTURE
from test_preferences import settled, apply


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, default=ROOT/'zig-out/bin/pearl')
    parser.add_argument('--ctl', type=Path, default=ROOT/'zig-out/bin/pearlctl')
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/dock-desktop-overrides/reproduction')
    args = parser.parse_args()
    args.pearl = args.pearl.resolve()
    args.ctl = args.ctl.resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(status='running', cases=[], pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest())
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
            system2 = s.base/'system-data-second'
            user = Path(s.env['XDG_DATA_HOME'])
            for root in (system, system2, user):
                (root/'applications').mkdir(parents=True, exist_ok=True)
            s.env['XDG_DATA_DIRS'] = f'{system}:{system2}'
            s.env['PEARL_TEST_LAUNCH_LOG'] = str(s.output/'launches.jsonl')
            Path(s.env['PEARL_TEST_LAUNCH_LOG']).write_text('')
            colors = {'system': (250, 17, 5), 'user': (5, 245, 31), 'edited': (9, 31, 250)}
            icons = {}
            for name, color in colors.items():
                icons[name] = s.base/(name+'.png')
                Image.new('RGB', (64, 64), color).save(icons[name])
            app_id = 'org.pearl.Override'
            desktop_id = app_id+'.desktop'

            def write(root, mark, icon, identifier=desktop_id, wmclass=True, atomic=False):
                path = root/'applications'/identifier
                content = (f'[Desktop Entry]\nType=Application\nName=Override {mark}\n'
                           f'Exec=/usr/bin/python3 {FIXTURE} --id {app_id} --mark {mark} --title "Override {mark}" --custom-argument "{mark} two words"\n'
                           f'Icon={icons[icon]}\nDBusActivatable=false\n'
                           + (f'StartupWMClass={app_id}\n' if wmclass else '')
                           + f'Actions=Special;\n\n[Desktop Action Special]\nName=Special {mark}\n'
                           f'Exec=/usr/bin/python3 {FIXTURE} --id {app_id} --mark {mark}-action\n')
                target = path.with_suffix('.new') if atomic else path
                target.write_text(content)
                if atomic:
                    target.replace(path)
                (s.output/(mark+'.desktop.txt')).write_text(content)
                return path

            write(system, 'system', 'system')
            write(system2, 'system-second', 'edited')
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
            prefs = settled(s, args.ctl)['preferences']
            prefs['dock']['mode'] = 'always'
            apply(s, args.ctl, prefs)
            ctl(s, args.ctl, 'dock', 'pin', '--text', desktop_id)
            settled(s, args.ctl)

            def refreshed(change):
                generation = status(s, args.ctl)['apps']['generation']
                change()
                eventually_status(s, args.ctl, lambda v: v['apps']['generation'] > generation)
                time.sleep(.4)

            def close_windows():
                for win in ipc.state():
                    if win['kind'] == 'window' and win.get('app_id') == app_id:
                        ipc.call('command', action='window.close', fields=dict(id=win['id']))
                wait_for(lambda: not any(w['kind'] == 'window' and w.get('app_id') == app_id for w in ipc.state()))
                time.sleep(.2)

            def inspect(name, expected, icon_expected, identifier=desktop_id, menu=False):
                ctl(s, args.ctl, 'dock', 'show', '--output', oid)
                time.sleep(.3)
                live = status(s, args.ctl)
                output = next(o for o in live['outputs'] if o['id'] == oid)
                screenshot = capture(s, name, first['connector'])
                rect = output['dock']['rect']
                bounds = output['bounds']
                crop = screenshot.crop((rect['x']-bounds['x'], rect['y']-bounds['y'],
                                        rect['x']-bounds['x']+rect['width'], rect['y']-bounds['y']+rect['height']))
                crop.save(s.output/(name+'-dock.png'))
                pixels = list(crop.get_flattened_data())
                counts = {key: sum(max(abs(p[i]-rgb[i]) for i in range(3)) < 12 for p in pixels)
                          for key, rgb in colors.items()}
                probe = s.run(['python3', '-c',
                    'import json,sys; from gi.repository import Gio; a=Gio.DesktopAppInfo.new(sys.argv[1]); '
                    'print(json.dumps(dict(id=a.get_id(),file=a.get_filename(),icon=a.get_icon().to_string(),command=a.get_commandline())))', identifier])
                before = len(entries(s))
                if menu:
                    keys(s, 'Menu', 'space')
                else:
                    keys(s, 'space')
                wait_for(lambda: len(entries(s)) > before)
                record = entries(s)[-1]
                result = dict(case=name, expected_mark=expected, launch=record,
                              icon_pixels=counts, gio_resolution=json.loads(probe.stdout),
                              generation=live['apps']['generation'], dock_groups=output['dock']['groups'],
                              launch_matches=record['mark'] == expected,
                              icon_matches=counts[icon_expected] >= 1000)
                report['cases'].append(result)
                print(json.dumps(result), flush=True)
                keys(s, 'Escape', 'Escape')
                close_windows()

            inspect('system-baseline', 'system', 'system')
            refreshed(lambda: write(user, 'user', 'user'))
            inspect('user-added-live', 'user', 'user')
            refreshed(lambda: write(user, 'edited', 'edited', atomic=True))
            inspect('user-atomically-replaced', 'edited', 'edited')
            refreshed(lambda: write(user, 'in-place', 'user'))
            inspect('user-edited-in-place', 'in-place', 'user', menu=True)
            refreshed(lambda: (user/'applications'/desktop_id).unlink())
            inspect('user-removed-live', 'system', 'system')
            app.stop()
            write(user, 'user-startup', 'user')
            app = start('pearl-restarted')
            inspect('user-present-at-startup', 'user-startup', 'user')

            # A renamed custom launcher is a separate desktop ID. Its windows
            # still report the packaged app ID; launch it before pinning.
            refreshed(lambda: (user/'applications'/desktop_id).unlink())
            custom_id = 'CustomOverride.desktop'
            refreshed(lambda: write(user, 'renamed', 'user', identifier=custom_id, wmclass=False))
            ctl(s, args.ctl, 'dock', 'unpin', '--text', desktop_id)
            settled(s, args.ctl)
            custom_launch = s.child('custom-launch', ['python3', '-c', 'import sys; from gi.repository import Gio; '
                                   'assert Gio.DesktopAppInfo.new(sys.argv[1]).launch([], None)', custom_id])
            wait_for(lambda: any(e['mark'] == 'renamed' for e in entries(s)))
            window = wait_for(lambda: next((w for w in ipc.state() if w['kind'] == 'window' and w.get('app_id') == app_id), None))
            ipc.call('command', action='window.move', fields=dict(id=window['id'], output=oid))
            time.sleep(.4)
            ctl(s, args.ctl, 'dock', 'show', '--output', oid)
            keys(s, 'Menu')
            capture(s, 'renamed-running-context-menu', first['connector'])
            keys(s, 'Down', 'space')
            pins = settled(s, args.ctl)['preferences']['pinned_apps']
            report['renamed_running_pin'] = dict(custom_id=custom_id, window_app_id=app_id, saved_pins=pins)
            assert pins == [desktop_id], pins
            keys(s, 'Escape', 'Escape')
            close_windows()
            inspect('renamed-running-app-pinned-and-relaunched', 'system', 'system')
            ctl(s, args.ctl, 'dock', 'unpin', '--text', desktop_id)
            settled(s, args.ctl)
            ctl(s, args.ctl, 'dock', 'pin', '--text', custom_id)
            settled(s, args.ctl)
            inspect('renamed-explicit-pin', 'renamed', 'user', identifier=custom_id)
            report['issue_symptom_reproduced'] = 'Different desktop ID, unchanged window app ID, pinning from the running window'
            report['status'] = 'completed'
            ipc.close()
    except Exception as exc:
        report['status'] = 'error'
        report['error'] = repr(exc)
        raise
    finally:
        (args.output/'results.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
