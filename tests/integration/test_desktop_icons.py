#!/usr/bin/env python3
"""Desktop icons in private HOME/XDG roots, with actual pointer/keyboard input."""
import argparse
import copy
import json
import sys
import time
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for, fixture_source
from t00 import Session as T00Session
from test_surfaces import IPC, ctl, status, capture, clean, click
from test_preferences import settled, apply
from test_settings_displays import drag_pointer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, required=True)
    parser.add_argument('--ctl', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/desktop-icons')
    args = parser.parse_args()
    args.pearl = args.pearl.resolve(); args.ctl = args.ctl.resolve(); args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    report = {'status': 'running', 'checks': checks}
    def passed(name):
        checks[name] = True
        print('PASS', name, flush=True)
    try:
        with PrivateSession(args.output / 'session') as s:
            s.env['GSETTINGS_BACKEND'] = 'memory'
            s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path=' + str(s.runtime / 'system-bus')
            s.child('system-bus', ['dbus-daemon', '--session', '--nofork', '--address=' + s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda: s.run(['busctl', '--address=' + s.env['DBUS_SYSTEM_BUS_ADDRESS'], 'list'], check=False).returncode == 0)
            s.env['PEARL_SECURITY_LOG'] = str(s.output / 'security.jsonl')
            Path(s.env['PEARL_SECURITY_LOG']).write_text('')
            authority = s.child('authority', ['python3', ROOT / 'tests/fixtures/session_security.py'], input_pipe=True)
            authority.expect('event=ready')
            s.args = SimpleNamespace(aqueous_source=str(fixture_source()))
            T00Session.input_fixture(s)
            ipc = IPC(s)
            desktop = Path(s.env['HOME']) / 'Bureau'
            desktop.mkdir()
            config = Path(s.env['XDG_CONFIG_HOME']) / 'user-dirs.dirs'
            config.write_text('XDG_DESKTOP_DIR="$HOME/Bureau"\n')
            # Ordinary activation must use a private marker handler, even when
            # the host associates folders or text files with a real application.
            opened = s.base / 'document-opened'
            applications = Path(s.env['XDG_DATA_HOME']) / 'applications'
            applications.mkdir(parents=True, exist_ok=True)
            (applications / 'pearl-icon-handler.desktop').write_text(
                '[Desktop Entry]\nType=Application\nName=Pearl icon test handler\n'
                f'Exec=/usr/bin/touch {opened}\n'
                'MimeType=inode/directory;text/plain;application/octet-stream;\n')
            (Path(s.env['XDG_CONFIG_HOME']) / 'mimeapps.list').write_text(
                '[Default Applications]\n' + ''.join(
                    f'{mime}=pearl-icon-handler.desktop;\n'
                    for mime in ('inode/directory', 'text/plain', 'application/octet-stream')))
            (desktop / 'Projects').mkdir()
            (desktop / 'Ideas.txt').write_text('Desktop fixture\n')
            (desktop / '.hidden').write_text('Hidden\n')
            (desktop / 'Broken link').symlink_to(desktop / 'missing-target')
            marker = s.base / 'activated'
            launcher = desktop / 'Fixture.desktop'
            launcher.write_text('[Desktop Entry]\nType=Application\nName=Fixture\nExec=/usr/bin/touch ' + str(marker) + '\nIcon=utilities-terminal\n')
            app = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings')
            app.expect('event=control-ready')
            def probe():
                return ctl(s, args.ctl, 'aqueous', 'status', '--text', 'test-desktop-icons')['result']
            wait_for(lambda: probe().get('count') == 4, 30)
            base = copy.deepcopy(settled(s, args.ctl)['preferences'])
            preference_path = Path(settled(s, args.ctl)['path'])
            assert base['desktop_icons']['enabled'] is True
            assert probe()['keyboard_mode'] == 'on_demand'
            assert probe()['allowed']
            passed('fresh-install-enabled-localized-desktop')
            def row(name):
                return wait_for(lambda: next((r for r in probe()['rows'] if r['name'] == name), None))
            def select(name):
                p = probe(); r = row(name); output = next(o for o in status(s, args.ctl)['outputs'] if o['id'] == p['output'])
                click(s, r['x'] + output['bounds']['x'], r['y'] + output['bounds']['y'], ipc.outputs())
                return r
            def key(*names):
                argv = ['wtype', '-s', '80']
                for name in names: argv += ['-k', name, '-s', '80']
                s.run(argv)
            def menu_button(name):
                p = wait_for(lambda: (lambda v: v if any(b['name'] == name for b in v.get('buttons', [])) else False)(probe()))
                # A newly installed popover child exists before GTK allocates
                # its final bounds. Let the frame settle before pointer input.
                time.sleep(.2)
                p = probe()
                b = next(b for b in p['buttons'] if b['name'] == name)
                output = next(o for o in status(s, args.ctl)['outputs'] if o['id'] == p['output'])
                click(s, round(b['x']) + output['bounds']['x'], round(b['y']) + output['bounds']['y'], ipc.outputs())
            select('Projects')
            wait_for(lambda: row('Projects')['selected'])
            capture(s, 'desktop', next(o['connector'] for o in status(s, args.ctl)['outputs'] if o['id'] == probe()['output']))
            passed('pointer-select-background-focus')
            key('Right')
            wait_for(lambda: any(r['selected'] for r in probe()['rows'] if r['name'] != 'Projects'))
            passed('keyboard-navigation')
            select('Projects'); key('Return')
            wait_for(opened.exists)
            opened.unlink()
            select('Ideas.txt'); key('Return')
            wait_for(opened.exists)
            passed('folders-and-documents-use-default-handler')
            select('Fixture.desktop'); key('Return')
            wait_for(lambda: probe()['menu'])
            assert not marker.exists()
            key('Escape')
            passed('unapproved-launcher-does-not-execute')
            select('Fixture.desktop')
            s.run(['wlrctl', 'pointer', 'click', 'right'])
            wait_for(lambda: probe()['menu'])
            capture(s, 'desktop-context-menu', next(o['connector'] for o in status(s, args.ctl)['outputs'] if o['id'] == probe()['output']))
            menu_button('Open')
            capture(s, 'desktop-launcher-approval', next(o['connector'] for o in status(s, args.ctl)['outputs'] if o['id'] == probe()['output']))
            wait_for(lambda: any(b['name'] == 'Allow launching' for b in probe()['buttons']))
            assert not marker.exists()
            key('Escape')
            passed('context-menu-open-retains-approval-prompt')
            ctl(s, args.ctl, 'desktop', 'focus')
            wait_for(lambda: probe()['focus'])
            passed('explicit-desktop-keyboard-focus')
            select('Fixture.desktop'); key('Return')
            menu_button('Allow launching')
            approvals = Path(s.env['XDG_STATE_HOME']) / 'pearl/desktop-launchers.json'
            wait_for(lambda: approvals.exists() and len(json.loads(approvals.read_text())['approvals']) == 1)
            assert not marker.exists()
            select('Fixture.desktop'); key('Return')
            wait_for(marker.exists)
            marker.unlink()
            launcher.write_text(launcher.read_text() + '\nComment=changed\n')
            time.sleep(.5)
            select('Fixture.desktop'); key('Return')
            wait_for(lambda: probe()['menu'])
            assert not marker.exists()
            key('Escape')
            passed('explicit-approval-content-bound-and-launch')
            select('Ideas.txt'); key('F2')
            s.run(['wtype', '-M', 'ctrl', '-k', 'a', '-m', 'ctrl', 'Renamed ideas.txt'])
            menu_button('Rename')
            wait_for(lambda: (desktop / 'Renamed ideas.txt').exists())
            select('Renamed ideas.txt'); key('Delete')
            wait_for(lambda: not (desktop / 'Renamed ideas.txt').exists())
            assert any((Path(s.env['XDG_DATA_HOME']) / 'Trash/files').iterdir())
            (desktop / 'Ideas.txt').write_text('Restored fixture')
            wait_for(lambda: any(r['name'] == 'Ideas.txt' for r in probe()['rows']))
            passed('rename-and-trash-through-native-input')
            unusual = 'Café; $(literal).txt'
            (desktop / unusual).write_text('literal filename')
            select(unusual); key('F2')
            s.run(['wtype', '-M', 'ctrl', '-k', 'a', '-m', 'ctrl', 'Ideas.txt'])
            menu_button('Rename')
            wait_for(lambda: 'RenameFailed' in probe()['message'])
            assert (desktop / unusual).read_text() == 'literal filename'
            assert (desktop / 'Ideas.txt').read_text() == 'Restored fixture'
            select(unusual); key('Delete')
            wait_for(lambda: not (desktop / unusual).exists())
            wait_for(lambda: probe()['count'] == 4)
            passed('unicode-literal-filename-and-rename-collision')
            def background_menu():
                output = next(o for o in status(s, args.ctl)['outputs'] if o['id'] == probe()['output'])
                click(s, output['bounds']['x'] + 650, output['bounds']['y'] + 400, ipc.outputs())
                s.run(['wlrctl', 'pointer', 'click', 'right'])
                wait_for(lambda: probe()['menu'])
            background_menu(); menu_button('New folder…')
            s.run(['wtype', 'New folder'])
            menu_button('Create folder')
            wait_for(lambda: (desktop / 'New folder').is_dir())
            select('New folder'); key('Delete')
            wait_for(lambda: not (desktop / 'New folder').exists())
            background_menu(); menu_button('Add application shortcut…')
            menu_button('Add shortcut')
            shortcut = wait_for(lambda: next(iter(desktop.glob('Pearl-*.desktop')), None))
            assert shortcut.read_text().startswith('[Desktop Entry]') or '[Desktop Entry]' in shortcut.read_text()
            wait_for(lambda: len(json.loads(approvals.read_text())['approvals']) == 2)
            shortcut.unlink()
            wait_for(lambda: probe()['count'] == 4)
            passed('new-folder-and-approved-catalog-shortcut')
            manual = copy.deepcopy(base); manual['desktop_icons']['arrangement'] = 'manual'
            apply(s, args.ctl, manual)
            original = select('Projects')
            # Selection and the following held press are separate gestures,
            # not a double-click that activates the folder before dragging.
            time.sleep(.5)
            drag_pointer(s, 224, 212)
            wait_for(lambda: row('Projects')['slot'] != original['slot'])
            placement = row('Projects')['slot']
            state_file = Path(s.env['XDG_STATE_HOME']) / 'pearl/desktop-icons.json'
            wait_for(state_file.exists)
            ctl(s, args.ctl, 'quit'); clean(app)
            app = s.child('pearl-placement-restart', [args.pearl], G_DEBUG='fatal-warnings'); app.expect('event=control-ready')
            wait_for(lambda: probe().get('count') == 4)
            assert row('Projects')['slot'] == placement
            apply(s, args.ctl, base)
            passed('manual-drag-and-restart-persistence')
            # A popup-dismissal click must never select/activate the background item.
            select('Projects')
            ctl(s, args.ctl, 'launcher', 'show')
            wait_for(lambda: status(s, args.ctl)['popup'] is not None)
            select('Fixture.desktop')
            wait_for(lambda: status(s, args.ctl)['popup'] is None)
            assert not marker.exists()
            assert row('Projects')['selected']
            passed('popup-dismissal-consumes-click')
            (desktop / 'New.txt').write_text('new')
            wait_for(lambda: probe()['count'] == 5)
            (desktop / 'New.txt').rename(desktop / 'Renamed.txt')
            wait_for(lambda: any(r['name'] == 'Renamed.txt' for r in probe()['rows']))
            (desktop / 'Renamed.txt').unlink()
            wait_for(lambda: probe()['count'] == 4)
            passed('live-create-rename-delete')
            prefs = copy.deepcopy(base); prefs['desktop_icons']['show_hidden'] = True
            apply(s, args.ctl, prefs)
            wait_for(lambda: probe()['count'] == 5)
            passed('hidden-files-live-preference')
            outputs = status(s, args.ctl)['outputs']
            other = next(o for o in outputs if o['id'] != probe()['output'])
            prefs['desktop_icons']['output'] = other['connector']; apply(s, args.ctl, prefs)
            wait_for(lambda: probe()['output'] == other['id'])
            prefs['desktop_icons']['output'] = 'disconnected-output'; apply(s, args.ctl, prefs)
            wait_for(lambda: probe()['output'] == min(outputs, key=lambda o: o['connector'])['id'])
            passed('chosen-output-and-stable-fallback')
            for mode in ('light', 'gtk', 'dark'):
                themed = copy.deepcopy(prefs)
                themed['theme']['mode'] = 'gtk' if mode == 'gtk' else 'static'
                themed['theme']['variant'] = 'light' if mode == 'light' else 'dark'
                themed['font_size'] = 20 if mode == 'gtk' else 14
                apply(s, args.ctl, themed)
                capture(s, 'desktop-' + mode, next(o['connector'] for o in status(s, args.ctl)['outputs'] if o['id'] == probe()['output']))
            apply(s, args.ctl, prefs)
            passed('dark-light-native-and-large-text')
            authority.proc.stdin.write('{"active":false}\n'); authority.proc.stdin.flush()
            wait_for(lambda: not probe()['allowed'])
            assert probe()['keyboard_mode'] == 'none'
            authority.proc.stdin.write('{"active":true}\n'); authority.proc.stdin.flush()
            wait_for(lambda: probe()['allowed'])
            passed('inactive-session-revokes-input')
            config.write_text('XDG_DESKTOP_DIR="$HOME"\n')
            wait_for(lambda: probe()['count'] == 0)
            assert 'No Desktop folder' in probe()['message']
            passed('home-valued-desktop-never-lists-home')
            config.write_text('XDG_DESKTOP_DIR="$HOME/Bureau"\n')
            wait_for(lambda: probe()['count'] == 5)
            desktop.rename(desktop.with_name('Bureau-away'))
            wait_for(lambda: 'does not exist' in probe()['message'])
            desktop.with_name('Bureau-away').rename(desktop)
            wait_for(lambda: probe()['count'] == 5)
            passed('desktop-removal-and-recreation')
            start = time.monotonic()
            for i in range(10000): (desktop / f'file-{i:05d}.txt').touch()
            wait_for(lambda: probe()['count'] == 10005, 60)
            assert probe()['widgets'] < 200, probe()
            report['large_directory'] = {'files': probe()['count'], 'widgets': probe()['widgets'], 'create_and_scan_seconds': round(time.monotonic() - start, 3), 'rss': next(line for line in Path(f'/proc/{app.proc.pid}/status').read_text().splitlines() if line.startswith('VmRSS:'))}
            passed('ten-thousand-files-bounded-widgets')
            prefs['desktop_icons']['enabled'] = False; apply(s, args.ctl, prefs)
            wait_for(lambda: not probe()['enabled'])
            ctl(s, args.ctl, 'quit'); clean(app)
            app = s.child('pearl-restart', [args.pearl], G_DEBUG='fatal-warnings'); app.expect('event=control-ready')
            settled(s, args.ctl)
            assert not probe()['enabled']
            passed('explicit-disable-survives-restart')
            ctl(s, args.ctl, 'quit'); clean(app)
            preference_path.write_text('{}')
            app = s.child('pearl-legacy', [args.pearl], G_DEBUG='fatal-warnings'); app.expect('event=control-ready')
            settled(s, args.ctl)
            assert not probe()['enabled']
            ctl(s, args.ctl, 'quit'); clean(app)
            passed('existing-empty-document-retains-disabled-default')
            good_path = preference_path.with_name('last-good.json')
            good_text = json.dumps({'desktop_icons': {'enabled': True}, 'matugen': {'enabled': False}})
            good_path.write_text(good_text); preference_path.unlink()
            app = s.child('pearl-missing-main', [args.pearl], G_DEBUG='fatal-warnings'); app.expect('event=control-ready')
            settled(s, args.ctl); wait_for(lambda: probe()['enabled'])
            assert not preference_path.exists()
            assert good_path.read_text() == good_text
            ctl(s, args.ctl, 'quit'); clean(app)
            preference_path.write_text('{broken')
            app = s.child('pearl-corrupt-main', [args.pearl], G_DEBUG='fatal-warnings'); app.expect('event=control-ready')
            settled(s, args.ctl); wait_for(lambda: probe()['enabled'])
            assert preference_path.read_text() == '{broken'
            ctl(s, args.ctl, 'quit'); clean(app)
            passed('missing-and-corrupt-main-preserve-known-good-choice')
        report['status'] = 'passed'
    except Exception as exc:
        report.update(status='failed', error=str(exc))
        raise
    finally:
        (args.output / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')

if __name__ == '__main__':
    main()
