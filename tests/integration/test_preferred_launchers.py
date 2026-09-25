#!/usr/bin/env python3
"""Native acceptance for Pearl's preferred launcher matching and desktop IDs."""
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
from test_desktop import FIXTURE, entries, keys
from test_preferences import settled, apply


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, required=True, help='Integration build with test hooks')
    parser.add_argument('--ctl', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/dock-desktop-overrides/preferred')
    args = parser.parse_args()
    for name in ('pearl', 'ctl', 'output'):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(status='running', pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(), cases=[])
    try:
        with PrivateSession(args.output / 'session') as s:
            s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path=' + str(s.runtime / 'system-bus')
            s.child('system-bus', ['dbus-daemon', '--session', '--nofork', '--address=' + s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda: s.run(['busctl', '--address=' + s.env['DBUS_SYSTEM_BUS_ADDRESS'], 'list'], check=False).returncode == 0)
            s.env['PEARL_SECURITY_LOG'] = str(s.output / 'security.jsonl')
            Path(s.env['PEARL_SECURITY_LOG']).write_text('')
            s.child('authority', ['python3', ROOT / 'tests/fixtures/session_security.py'], input_pipe=True).expect('event=ready')
            s.args = SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous')
            T00Session.input_fixture(s)
            system = s.base / 'system-data/applications'
            user = Path(s.env['XDG_DATA_HOME']) / 'applications'
            system.mkdir(parents=True)
            user.mkdir(parents=True, exist_ok=True)
            s.env['XDG_DATA_DIRS'] = str(system.parent)
            s.env['PEARL_TEST_LAUNCH_LOG'] = str(s.output / 'launches.jsonl')
            Path(s.env['PEARL_TEST_LAUNCH_LOG']).write_text('')
            colors = {'system': (250, 17, 5), 'custom': (5, 245, 31)}
            icons = {}
            for mark, rgb in colors.items():
                icons[mark] = s.base / (mark + ' icon (spaces).svg')
                icons[mark].write_text('<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">'
                                      f'<rect width="64" height="64" fill="rgb{rgb}"/></svg>')
            theme = user.parent / 'icons/hicolor'
            (theme / '64x64/apps').mkdir(parents=True)
            # Expose installed icon themes, without exposing installed applications.
            # A minimal hicolor index lacks GTK's missing-image fallback.
            (system.parent / 'icons').symlink_to('/usr/share/icons', target_is_directory=True)
            Image.new('RGB', (64, 64), colors['custom']).save(theme / '64x64/apps/pearl-preferred-fixture.png')
            app_id = 'org.pearl.Override'
            packaged = app_id + '.desktop'
            custom = 'CustomOverride.desktop'

            def write(root, identifier, mark, wmclass=True):
                path = root / identifier
                path.write_text('[Desktop Entry]\nType=Application\n'
                    f'Name=Override {mark}\nIcon={icons[mark]}\n'
                    f'Exec=/usr/bin/python3 {FIXTURE} --id {app_id} --mark {mark} --custom-argument "{mark} two words"\n'
                    + (f'StartupWMClass={app_id}\n' if wmclass else '')
                    + 'Actions=Special;\n\n[Desktop Action Special]\nName=Special launch\n'
                    + f'Exec=/usr/bin/python3 {FIXTURE} --id {app_id} --mark {mark}-action\n')
                return path

            write(system, packaged, 'system')
            ipc = IPC(s)
            app = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings')
            app.expect('event=app-index-ready')
            eventually_status(s, args.ctl, lambda v: len(v['outputs']) == 2 and v['apps']['ready'])
            first = status(s, args.ctl)['outputs'][0]
            oid = first['id']
            prefs = settled(s, args.ctl)['preferences']
            prefs['dock']['mode'] = 'always'
            apply(s, args.ctl, prefs)

            def refresh(change):
                generation = status(s, args.ctl)['apps']['generation']
                change()
                eventually_status(s, args.ctl, lambda v: v['apps']['generation'] > generation)

            def pins(values):
                p = settled(s, args.ctl)['preferences']
                p['pinned_apps'] = values
                apply(s, args.ctl, p)

            def windows():
                return [w for w in ipc.state() if w['kind'] == 'window' and w.get('app_id') == app_id]

            def close_windows():
                for w in windows():
                    ipc.call('command', action='window.close', fields=dict(id=w['id']))
                wait_for(lambda: not windows())
                time.sleep(.2)

            def group_key():
                return ctl(s, args.ctl, 'aqueous', 'status', '--text', 'test-running-apps')['result']['groups'][0]['key']

            def observe(name, identifier, mark, expected_group, expected_groups, icon=None, dock_launch=False, pin_running=False, during=None):
                before = len(entries(s))
                if dock_launch:
                    ctl(s, args.ctl, 'dock', 'show', '--output', oid)
                    keys(s, 'space', 'Escape')
                else:
                    s.child(name + '-launch', ['python3', '-c', 'import sys; from gi.repository import Gio; '
                        'assert Gio.DesktopAppInfo.new(sys.argv[1]).launch([],None)', identifier])
                wait_for(lambda: len(entries(s)) > before)
                win = wait_for(lambda: next(iter(windows()), None))
                ipc.call('command', action='window.move', fields=dict(id=win['id'], output=oid))
                eventually_status(s, args.ctl, lambda v: next(o for o in v['outputs'] if o['id'] == oid)['dock']['groups'] == expected_groups)
                time.sleep(.3)
                groups = ctl(s, args.ctl, 'aqueous', 'status', '--text', 'test-running-apps')['result']['groups']
                assert [g['key'] for g in groups] == [expected_group], groups
                launch = entries(s)[-1]
                assert launch['mark'] == mark and launch['desktop_file'].endswith('/' + identifier), launch
                assert launch['argv'] == ['--custom-argument', mark + ' two words'], launch
                if pin_running:
                    ctl(s, args.ctl, 'dock', 'show', '--output', oid)
                    keys(s, 'Menu', 'Down', 'space', 'Escape')
                    assert settled(s, args.ctl)['preferences']['pinned_apps'] == [identifier]
                ctl(s, args.ctl, 'dock', 'show', '--output', oid)
                time.sleep(.2)
                image = capture(s, name, first['connector'])
                out = next(o for o in status(s, args.ctl)['outputs'] if o['id'] == oid)
                r, b = out['dock']['rect'], out['bounds']
                crop = image.crop((r['x']-b['x'], r['y']-b['y'], r['x']-b['x']+r['width'], r['y']-b['y']+r['height']))
                counts = {key: sum(max(abs(p[i]-rgb[i]) for i in range(3)) < 12 for p in crop.get_flattened_data())
                          for key, rgb in colors.items()}
                if icon:
                    assert counts[icon] >= 1000, counts
                report['cases'].append(dict(case=name, launch_id=identifier, launch_mark=mark,
                    window_app_id=win['app_id'], group=groups[0]['key'], dock_groups=out['dock']['groups'],
                    pins=settled(s, args.ctl)['preferences']['pinned_apps'], icon_pixels=counts))
                print(name, groups[0]['key'], 'dock_groups=' + str(out['dock']['groups']), flush=True)
                keys(s, 'Escape')
                if during:
                    during()
                close_windows()

            refresh(lambda: write(user, packaged, 'custom'))
            pins([packaged])
            observe('same-id-svg-override', packaged, 'custom', 'desktop:' + packaged, 1, 'custom', True)
            refresh(lambda: (user / packaged).unlink())
            refresh(lambda: write(user, custom, 'custom', wmclass=False))
            pins([custom])
            observe('custom-pin-no-wmclass', custom, 'custom', 'desktop:' + packaged, 2, dock_launch=True)
            refresh(lambda: write(user, custom, 'custom', wmclass=True))
            pins([])
            observe('custom-wmclass-unpinned-native-pin', custom, 'custom', 'desktop:' + custom, 1, 'custom', pin_running=True)

            def stale_pin_menu():
                ctl(s, args.ctl, 'dock', 'show', '--output', oid)
                keys(s, 'Menu')
                before = len(entries(s))
                pins([packaged])
                wait_for(lambda: group_key() == 'desktop:' + packaged)
                keys(s, 'space')
                time.sleep(.3)
                assert len(entries(s)) == before, 'Stale custom launch ran after pin preference changed'
                keys(s, 'Escape', 'Escape')

            observe('custom-wmclass-pinned-stale-menu', custom, 'custom', 'desktop:' + custom, 1, 'custom', dock_launch=True, during=stale_pin_menu)
            observe('packaged-pin-wins', custom, 'custom', 'desktop:' + packaged, 1, 'system')
            pins([packaged, custom])
            observe('multiple-matching-pins-remain-ambiguous', custom, 'custom', 'app:' + app_id, 3)
            pins([])
            second = 'SecondCustom.desktop'
            refresh(lambda: write(user, second, 'custom'))
            observe('multiple-user-launchers-remain-ambiguous', custom, 'custom', 'app:' + app_id, 1)
            pins([custom])
            observe('unique-pin-breaks-user-tie', custom, 'custom', 'desktop:' + custom, 1, 'custom', dock_launch=True)
            refresh(lambda: (user / second).unlink())

            def custom_actions_and_catalog_change():
                for downs, mark in [(0, 'custom'), (2, 'custom-action')]:
                    before = len(entries(s))
                    ctl(s, args.ctl, 'dock', 'show', '--output', oid)
                    keys(s, 'Menu', *(['Down'] * downs), 'space', 'Escape')
                    wait_for(lambda: len(entries(s)) > before)
                    record = entries(s)[-1]
                    assert record['mark'] == mark and record['desktop_file'].endswith('/' + custom), record
                ctl(s, args.ctl, 'dock', 'show', '--output', oid)
                keys(s, 'Menu')
                before = len(entries(s))
                refresh(lambda: (user / custom).write_text((user / custom).read_text().replace(str(icons['custom']), 'pearl-preferred-fixture')))
                keys(s, 'space')
                time.sleep(.3)
                assert len(entries(s)) == before, 'Stale launch ran after catalog changed'
                keys(s, 'Escape', 'Escape')

            observe('custom-new-window-action-stale-catalog', custom, 'custom', 'desktop:' + custom, 1, 'custom', during=custom_actions_and_catalog_change)
            observe('custom-themed-png-icon', custom, 'custom', 'desktop:' + custom, 1, 'custom', dock_launch=True)
            for i, spaced in enumerate(['Custom Override.desktop', 'Éditeur 私用.desktop']):
                refresh(lambda: write(user, spaced, 'custom'))
                pins([])
                ctl(s, args.ctl, 'dock', 'pin', '--text', spaced)
                assert settled(s, args.ctl)['preferences']['pinned_apps'] == [spaced]
                app.stop()
                app = s.child('pearl-restart-' + str(i), [args.pearl], G_DEBUG='fatal-warnings')
                app.expect('event=app-index-ready')
                eventually_status(s, args.ctl, lambda v: v['apps']['ready'] and len(v['outputs']) == 2)
                assert settled(s, args.ctl)['preferences']['pinned_apps'] == [spaced]
                observe('desktop-id-restart-' + str(i), spaced, 'custom', 'desktop:' + spaced, 1, 'custom', dock_launch=True)
            report['status'] = 'passed'
            ipc.close()
    except Exception as exc:
        report['status'] = 'failed'
        report['error'] = repr(exc)
        raise
    finally:
        (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
