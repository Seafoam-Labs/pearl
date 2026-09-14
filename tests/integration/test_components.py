#!/usr/bin/env python3
"""T03 keyboard, layout, virtualization and idle checks on a private display."""
import argparse
import os
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, required=True)
    parser.add_argument('--aqueous', type=Path, default=Path(os.environ.get('PEARL_TEST_AQUEOUS_PREFIX', ROOT / '.cache/aqueous')) / 'bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=Path(os.environ.get('PEARL_TEST_AQUEOUS_PREFIX', ROOT / '.cache/aqueous')) / 'bin/aqueousctl')
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/t03/latest')
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    result = dict(status='running', recorded_utc=datetime.now(timezone.utc).isoformat(),
                  executable_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(), checks={}, probes={})
    try:
        with PrivateSession(args.output, args.aqueous, inherited={'PATH': '/usr/bin', 'LANG': 'C.UTF-8'}) as session:
            app = session.child('gallery', [args.pearl.resolve(), '--demo'], G_DEBUG='fatal-warnings')
            app.expect('event=work-finished applied=true')
            time.sleep(.5)
            output = json.loads(session.run([args.ctl, 'outputs', '--json']).stdout)[0]['name']

            def keys(*values):
                argv = ['wtype', '-s', '100']
                for key in values:
                    argv += ['-k', key, '-s', '80']
                session.run([*argv, '-s', '100'])
                time.sleep(.06)

            def ctrl(key):
                session.run(['wtype', '-s', '100', '-M', 'ctrl', '-k', key, '-m', 'ctrl', '-s', '100'])
                time.sleep(.2)

            def text(value):
                session.run(['wtype', '-s', '100', '-d', '20', value, '-s', '100'])
                time.sleep(.1)

            def expect_new(fragment, action):
                offset = len(app.lines)
                action()
                wait_for(lambda: any(fragment in line for line in app.lines[offset:]))

            def probe(name):
                offset = len(app.lines)
                keys('F12')
                wait_for(lambda: any('event=gallery-probe' in line for line in app.lines[offset:]))
                line = next(line for line in app.lines[offset:] if 'event=gallery-probe' in line)
                data = dict(re.findall(r'(\w+)=([^ ]+)', line))
                result['probes'][name] = data
                assert int(data['clipped']) == 0, (name, data)
                assert int(data['rows']) < 260, (name, data)
                return data

            def capture(name):
                time.sleep(.25)
                session.run(['grim', '-o', output, args.output / (name + '.png')])
                return probe(name)

            capture('dark-default')
            ctrl('l')
            capture('light-default')
            ctrl('d')
            capture('light-compact')
            ctrl('l')
            capture('dark-compact')
            ctrl('d')
            ctrl('e')
            ctrl('g')
            capture('dark-large-german')
            ctrl('e')
            ctrl('g')
            result['checks']['dark_light_density_large_text_and_translation'] = 'pass'

            ctrl('f')
            expect_new('event=search results=1', lambda: text('terminal'))
            expect_new('event=sample-activated title=Terminal', lambda: keys('Return'))
            keys('Escape')
            expect_new('event=search results=1', lambda: text('CAFÉ'))
            expect_new('event=sample-activated title=Café notes', lambda: keys('Return'))
            keys('Escape')
            expect_new('event=search results=0', lambda: text('no-such-fixture'))
            capture('empty-search')
            keys('Escape', 'Down', 'End')
            p = probe('list-end')
            assert int(p['selected']) == 517, p
            expect_new('event=sample-activated title=Sample window 0512', lambda: keys('Return'))
            result['checks']['unicode_search_empty_state_and_keyboard_list_navigation'] = 'pass'
            result['checks']['virtualized_518_items'] = 'pass'

            # Traverse real GTK focus order, exercising controls with standard keys.
            ctrl('f')
            seen = set()
            for step in range(45):
                keys('Tab')
                p = probe(f'tab-{step}')
                name = p['focus']
                if name in seen:
                    continue
                seen.add(name)
                if name == 'volume':
                    before = float(p['volume'])
                    keys('Right')
                    assert float(probe('volume-after-right')['volume']) > before
                if name == 'quiet':
                    keys('space')
                    assert probe('quiet-after-space')['quiet'] == 'true'
                if name == 'theme-light':
                    expect_new('event=appearance light=true', lambda: keys('space'))
                if {'volume', 'quiet', 'theme-light'} <= seen:
                    break
            assert {'volume', 'quiet', 'theme-light'} <= seen, seen
            result['checks']['tab_space_toggle_and_arrow_slider'] = 'pass'

            # The appearance shortcut does not move focus into a text cursor.
            ctrl('r')
            offset = len(app.lines)
            expect_new('event=idle-audit', lambda: keys('F10'))
            idle = next(line for line in app.lines[offset:] if 'event=idle-audit' in line)
            idle_frames = int(re.search(r'frames=(\d+)', idle)[1])
            # One final toolkit settling frame is allowed; recurring animation is not.
            assert idle_frames <= 1, idle
            result['idle'] = dict(seconds=3, frames=idle_frames)
            result['checks']['reduced_motion_no_recurring_frames'] = 'pass'
            ctrl('End')
            capture('states-and-controls')
            # Change only this private headless output, never a host display.
            session.run(['wlr-randr', '--output', output, '--custom-mode', '640x720'])
            time.sleep(.3)
            ctrl('Home')
            ctrl('e')
            ctrl('g')
            narrow = capture('narrow-large-german')
            assert int(narrow['width']) == 640, narrow
            ctrl('End')
            capture('narrow-large-states')
            result['checks']['640px_large_german_reflow'] = 'pass'
            app.signal()
            assert app.wait() == 0, app.lines[-20:]
            assert any('event=cleanup pending=false watched_objects=0' in line for line in app.lines)
            assert not any(word in line for line in app.lines for word in ('WARNING', 'CRITICAL', 'event=css-error', 'panic:'))
            result['checks']['no_css_warnings_and_gobjects_finalize'] = 'pass'
        result['status'] = 'pass'
        print('PASS: T03 components, keyboard, translation, virtualization, idle and captures')
    except BaseException as error:
        result['status'] = 'failed'
        result['error'] = repr(error)
        raise
    finally:
        (args.output / 'results.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
