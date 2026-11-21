#!/usr/bin/env python3
"""End-to-end verification of the issue #140 fix, pointer-only.

Covers what the integration suite adds (secondary desktop menu, arrange
delegation) plus store-mutating actions from the secondary monitor, lock
gating and disable gating. Avoids typing into popover entries: this
environment's GTK 4.24 aborts on that path even without the fix (see
artifacts/issue-140/before/ and debug_rename.py A/B runs).
"""
import copy
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT / 'tests' / 'integration'))
os.environ.setdefault('PEARL_TEST_AQUEOUS_PREFIX', str(ROOT / '.cache/aqueous-zig17-e32ab7f'))

from pearl_session import PrivateSession, wait_for
from test_surfaces import ctl, status, capture, click
from test_preferences import settled, apply
from test_settings_displays import drag_pointer

PEARL = ROOT / 'zig-out/bin/pearl-integration'
CTL = ROOT / 'zig-out/bin/pearlctl'
OUT = Path(__file__).resolve().parent / 'verify'
MENU = ['New folder…', 'Add application shortcut…', 'Arrange by name', 'Open Desktop folder', 'Retry', 'Desktop settings…']


def main():
    checks = {}
    with PrivateSession(OUT / 'session') as s:
        s.env['GSETTINGS_BACKEND'] = 'memory'
        s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path=' + str(s.runtime / 'system-bus')
        s.child('system-bus', ['dbus-daemon', '--session', '--nofork', '--address=' + s.env['DBUS_SYSTEM_BUS_ADDRESS']])
        wait_for(lambda: s.run(['busctl', '--address=' + s.env['DBUS_SYSTEM_BUS_ADDRESS'], 'list'], check=False).returncode == 0)
        s.env['PEARL_SECURITY_LOG'] = str(OUT / 'security.jsonl')
        Path(s.env['PEARL_SECURITY_LOG']).write_text('')
        authority = s.child('authority', ['python3', ROOT / 'tests/fixtures/session_security.py'], input_pipe=True)
        authority.expect('event=ready')
        desktop = Path(s.env['HOME']) / 'Desktop'
        desktop.mkdir()
        (Path(s.env['XDG_CONFIG_HOME']) / 'user-dirs.dirs').write_text('XDG_DESKTOP_DIR="$HOME/Desktop"\n')
        (desktop / 'Notes.txt').write_text('issue 140\n')
        (desktop / 'Projects').mkdir()
        app = s.child('pearl', [PEARL], G_DEBUG='fatal-warnings')
        app.expect('event=control-ready', timeout=30)

        def probe(output_id=None):
            text = 'test-desktop-icons' + (':' + output_id if output_id else '')
            return ctl(s, CTL, 'aqueous', 'status', '--text', text)['result']

        wait_for(lambda: probe().get('count') == 2, 30)
        base = copy.deepcopy(settled(s, CTL)['preferences'])
        outputs = status(s, CTL)['outputs']
        primary = next(o for o in outputs if o['id'] == probe()['output'])
        secondary = next(o for o in outputs if o['id'] != primary['id'])

        def menu_button(p, output, name):
            wait_for(lambda: any(b['name'] == name for b in p().get('buttons', [])))
            time.sleep(.2)
            b = next(b for b in p()['buttons'] if b['name'] == name)
            click(s, round(b['x']) + output['bounds']['x'], round(b['y']) + output['bounds']['y'], None)

        def background_menu(output, p):
            b = output['bounds']
            click(s, b['x'] + b['width'] // 2, b['y'] + b['height'] // 2, None)
            s.run(['wlrctl', 'pointer', 'click', 'right'])
            wait_for(lambda: p().get('menu'))

        def row(name):
            return wait_for(lambda: next((r for r in probe()['rows'] if r['name'] == name), None))

        # Menus on both outputs; icons only on the configured one.
        background_menu(primary, probe)
        checks['primary_menu'] = [b['name'] for b in probe()['buttons']] == MENU
        # Escape dismisses; an outside left-click races GTK's autohide popdown
        # against closeMenu in this environment's GTK 4.24 (pre-existing).
        s.run(['wtype', '-s', '80', '-k', 'Escape', '-s', '80'])
        wait_for(lambda: not probe()['menu'])
        sp = lambda: probe(secondary['id'])
        checks['secondary_no_icons'] = sp()['count'] == 0 and sp()['widgets'] == 0
        background_menu(secondary, sp)
        checks['secondary_menu'] = [b['name'] for b in sp()['buttons']] == MENU
        checks['primary_menu_untouched'] = not probe()['menu']
        capture(s, 'secondary-menu', secondary['connector'])

        # A store-mutating action started on the secondary monitor.
        menu_button(sp, secondary, 'Add application shortcut…')
        menu_button(sp, secondary, 'Add shortcut')
        shortcut = wait_for(lambda: next(iter(desktop.glob('Pearl-*.desktop')), None))
        wait_for(lambda: any(r['name'] == shortcut.name for r in probe()['rows']))
        approvals = Path(s.env['XDG_STATE_HOME']) / 'pearl/desktop-launchers.json'
        wait_for(lambda: approvals.exists() and len(json.loads(approvals.read_text())['approvals']) == 1)
        checks['secondary_shortcut_action'] = True
        shortcut.unlink()
        wait_for(lambda: probe()['count'] == 2)

        # Arrange from the secondary monitor uses the icon monitor's grid.
        manual = copy.deepcopy(base); manual['desktop_icons']['arrangement'] = 'manual'
        apply(s, CTL, manual)
        r = row('Projects')
        click(s, r['x'] + primary['bounds']['x'], r['y'] + primary['bounds']['y'], None)
        time.sleep(.5)
        drag_pointer(s, 224, 212)
        wait_for(lambda: row('Projects')['slot'] != r['slot'])
        background_menu(secondary, sp)
        menu_button(sp, secondary, 'Arrange by name')
        wait_for(lambda: row('Projects')['slot'] == 0 and sorted(x['slot'] for x in probe()['rows']) == list(range(len(probe()['rows']))))
        checks['arrange_from_secondary'] = True
        apply(s, CTL, base)

        # Locked session revokes the secondary desktop too.
        authority.proc.stdin.write('{"active":false}\n'); authority.proc.stdin.flush()
        wait_for(lambda: not sp()['allowed'])
        checks['locked_secondary'] = sp()['keyboard_mode'] == 'none'
        b = secondary['bounds']
        click(s, b['x'] + b['width'] // 2, b['y'] + b['height'] // 2, None)
        s.run(['wlrctl', 'pointer', 'click', 'right'])
        time.sleep(.4)
        checks['locked_no_menu'] = not sp().get('menu')
        authority.proc.stdin.write('{"active":true}\n'); authority.proc.stdin.flush()
        wait_for(lambda: sp()['allowed'])

        # Disabling desktop icons removes the menu everywhere.
        off = copy.deepcopy(base); off['desktop_icons']['enabled'] = False
        apply(s, CTL, off)
        wait_for(lambda: not probe().get('enabled'))
        checks['disabled_secondary'] = not sp().get('enabled')
        s.run(['wlrctl', 'pointer', 'click', 'right'])
        time.sleep(.4)
        checks['disabled_no_menu'] = not sp().get('menu') and not probe().get('menu')

        ctl(s, CTL, 'quit')
        assert app.wait() == 0, app.lines[-20:]
        assert not any(word in line for line in app.lines for word in ('CRITICAL', 'WARNING', 'panic:', 'event=css-error', 'protocol error')), app.lines[-30:]
    report = {'issue': 'Seafoam-Labs/pearl#140', 'checks': checks}
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2), flush=True)
    assert all(checks.values()), checks
    print('ALL CHECKS PASSED', flush=True)


if __name__ == '__main__':
    main()