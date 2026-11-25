#!/usr/bin/env python3
"""Step-through of the F2 rename flow to diagnose the suite regression."""
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
from wayland_test_input import pointer_move

PEARL = ROOT / 'zig-out/bin/pearl-integration'
CTL = ROOT / 'zig-out/bin/pearlctl'
OUT = Path(__file__).resolve().parent / 'debug'


def main():
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
        (desktop / 'Ideas.txt').write_text('fixture\n')
        (desktop / 'Projects').mkdir()
        app = s.child('pearl', [PEARL], G_DEBUG='fatal-warnings', **({'GSK_RENDERER': 'gl'} if 'ngl' in sys.argv else {}))
        app.expect('event=control-ready', timeout=30)

        def probe(output_id=None):
            text = 'test-desktop-icons' + (':' + output_id if output_id else '')
            return ctl(s, CTL, 'aqueous', 'status', '--text', text)['result']

        wait_for(lambda: probe().get('count') == 2, 30)
        outputs = status(s, CTL)['outputs']
        primary = next(o for o in outputs if o['id'] == probe()['output'])
        secondary = next(o for o in outputs if o['id'] != primary['id'])

        def dump(tag):
            try:
                p = probe()
            except AssertionError:
                print(tag, 'PEARL DEAD poll=', app.proc.poll(), flush=True)
                raise SystemExit(1)
            print(tag, json.dumps({'menu': p['menu'], 'focus': p['focus'], 'keyboard': p['keyboard_mode'],
                                  'selected': [r['name'] for r in p['rows'] if r['selected']],
                                  'buttons': [b['name'] for b in p['buttons']], 'message': p['message']}), flush=True)
            print(tag, 'secondary', json.dumps({k: probe(secondary['id']).get(k) for k in ('menu', 'focus', 'keyboard_mode')}), flush=True)

        r = wait_for(lambda: next((r for r in probe()['rows'] if r['name'] == 'Ideas.txt'), None))
        click(s, r['x'] + primary['bounds']['x'], r['y'] + primary['bounds']['y'], None)
        dump('after-select')
        s.run(['wtype', '-s', '80', '-k', 'F2', '-s', '80'])
        time.sleep(.3)
        dump('after-F2')
        capture(s, 'rename-form', primary['connector'])
        s.run(['wtype', '-M', 'ctrl', '-k', 'a', '-m', 'ctrl']) if 'noctrla' not in sys.argv else None
        time.sleep(.3)
        dump('after-ctrl-a')
        s.run(['wtype', '-s', '80', 'Renamed ideas.txt']) if 'slow' in sys.argv else s.run(['wtype', 'Renamed ideas.txt'])
        time.sleep(.3)
        dump('after-type')
        capture(s, 'rename-typed', primary['connector'])
        p = probe()
        b = next(b for b in p['buttons'] if b['name'] == 'Rename')
        click(s, round(b['x']) + primary['bounds']['x'], round(b['y']) + primary['bounds']['y'], None)
        time.sleep(1)
        dump('after-submit')
        print('desktop:', sorted(x.name for x in desktop.iterdir()), flush=True)
        capture(s, 'rename-result', primary['connector'])
        ctl(s, CTL, 'quit')
        app.wait()


if __name__ == '__main__':
    main()