#!/usr/bin/env python3
"""Verify Seafoam-Labs/pearl#140 fix: desktop right-click menu on every output.

Private headless Aqueous session with two outputs. Icons render on the
configured/first output only; the desktop context menu must appear on every
output. Pre-fix evidence (menu missing on the secondary output) is kept in
artifacts/issue-140/before/.
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
from wayland_test_input import Wire, pointer_move, stamp, uints
from test_surfaces import ctl, status, capture
from test_preferences import settled, apply

PEARL = ROOT / 'zig-out/bin/pearl-integration'
CTL = ROOT / 'zig-out/bin/pearlctl'
OUT = Path(__file__).resolve().parent


def pointer_right_click(session):
    with Wire(session) as wire:
        pointer = wire.pointer()
        wire.send(pointer, 2, uints(stamp(), 0x111, 1))  # BTN_RIGHT
        wire.send(pointer, 4)
        wire.sync()
        time.sleep(.04)
        wire.send(pointer, 2, uints(stamp(), 0x111, 0))
        wire.send(pointer, 4)
        wire.sync()


def right_click(session, x, y):
    pointer_move(session, x, y)
    time.sleep(.15)
    pointer_right_click(session)
    time.sleep(.4)


def main():
    report = {'issue': 'Seafoam-Labs/pearl#140', 'checks': {}}
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
        assert base['desktop_icons']['enabled'] is True
        outputs = status(s, CTL)['outputs']
        assert len(outputs) == 2, outputs
        icons_output_id = probe()['output']
        icons = next(o for o in outputs if o['id'] == icons_output_id)
        other = next(o for o in outputs if o['id'] != icons_output_id)
        report['outputs'] = {o['connector']: o['bounds'] for o in outputs}
        report['icons_on'] = icons['connector']
        print(f"icons on {icons['connector']} ({icons['bounds']}), other {other['connector']} ({other['bounds']})", flush=True)

        def center(o):
            b = o['bounds']
            return b['x'] + b['width'] // 2, b['y'] + b['height'] // 2

        # Positive control: right-click the empty desktop of the icons output.
        x, y = center(icons)
        right_click(s, x, y)
        p = probe()
        report['checks']['primary_output_menu'] = p['menu']
        report['primary_menu_buttons'] = [b['name'] for b in p['buttons']]
        capture(s, 'primary-right-click', icons['connector'])
        print('primary right-click menu:', p['menu'], report['primary_menu_buttons'], flush=True)
        assert p['menu'], 'positive control failed: no menu on the icons output'

        # Dismiss the menu with a left click on empty desktop.
        pointer_move(s, x, y)
        time.sleep(.1)
        with Wire(s) as wire:
            pointer = wire.pointer()
            wire.send(pointer, 2, uints(stamp(), 0x110, 1))
            wire.send(pointer, 4)
            wire.sync()
            time.sleep(.04)
            wire.send(pointer, 2, uints(stamp(), 0x110, 0))
            wire.send(pointer, 4)
            wire.sync()
        wait_for(lambda: not probe()['menu'])

        # The fix: right-click the empty desktop of the other output.
        x2, y2 = center(other)
        right_click(s, x2, y2)
        p = probe(other['id'])
        report['checks']['secondary_output_menu'] = p['menu']
        report['secondary_menu_buttons'] = [b['name'] for b in p['buttons']]
        report['checks']['secondary_renders_no_icons'] = p['count'] == 0 and p['widgets'] == 0
        report['checks']['primary_menu_not_opened'] = not probe()['menu']
        capture(s, 'secondary-right-click', other['connector'])
        print('secondary right-click menu:', p['menu'], report['secondary_menu_buttons'], flush=True)

        # Cross-check: moving icons to the other output keeps the menu there.
        prefs = copy.deepcopy(base)
        prefs['desktop_icons']['output'] = other['connector']
        apply(s, CTL, prefs)
        wait_for(lambda: probe()['output'] == other['id'])
        right_click(s, x2, y2)
        p = probe(other['id'])
        report['checks']['menu_follows_configured_output'] = p['menu']
        capture(s, 'secondary-as-primary-right-click', other['connector'])
        print('menu after configuring icons to secondary:', p['menu'], flush=True)

        ctl(s, CTL, 'quit')
        assert app.wait() == 0, app.lines[-20:]
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2), flush=True)
    expected = (report['checks']['primary_output_menu'] is True
                and report['checks']['secondary_output_menu'] is True
                and report['checks']['secondary_renders_no_icons'] is True
                and report['checks']['primary_menu_not_opened'] is True
                and report['checks']['menu_follows_configured_output'] is True)
    print('FIX VERIFIED for issue #140' if expected else 'UNEXPECTED RESULT', flush=True)


if __name__ == '__main__':
    main()