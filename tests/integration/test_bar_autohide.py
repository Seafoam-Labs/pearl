#!/usr/bin/env python3
"""Real edge input, work areas and bar lifecycle in an isolated Aqueous session."""
import argparse
import copy
import hashlib
import json
import sys
import time
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from t00 import Session as T00Session
from test_surfaces import IPC, ctl, status, capture, clean, click
from test_preferences import settled, apply
from test_desktop import FIXTURE


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, required=True)
    parser.add_argument('--ctl', type=Path, required=True)
    parser.add_argument('--aqueous', type=Path, help='Private compositor executable (defaults to the surface-test baseline)')
    parser.add_argument('--skip-hotplug', action='store_true', help='For compositor builds with the known OutputManager.validateConfigCoordinates assertion')
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/bar-autohide')
    args = parser.parse_args()
    for name in ('pearl', 'ctl', 'output'):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(status='running', checks={}, binaries={name: hashlib.sha256(getattr(args, name).read_bytes()).hexdigest() for name in ('pearl', 'ctl')})
    def passed(name):
        report['checks'][name] = True
        print('PASS', name, flush=True)
    try:
        with PrivateSession(args.output / 'session', aqueous=args.aqueous) as s:
            s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path=' + str(s.runtime / 'system-bus')
            s.child('system-bus', ['dbus-daemon', '--session', '--nofork', '--address=' + s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda: s.run(['busctl', '--address=' + s.env['DBUS_SYSTEM_BUS_ADDRESS'], 'list'], check=False).returncode == 0)
            s.env['PEARL_SECURITY_LOG'] = str(s.output / 'security.jsonl')
            Path(s.env['PEARL_SECURITY_LOG']).write_text('')
            authority = s.child('authority', ['python3', ROOT / 'tests/fixtures/session_security.py'], input_pipe=True)
            authority.expect('event=ready')
            def active(value):
                authority.proc.stdin.write(json.dumps(dict(active=value)) + '\n')
                authority.proc.stdin.flush()
            s.args = SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous')
            T00Session.input_fixture(s)
            ipc = IPC(s)
            app = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings')
            app.expect('event=control-ready')
            base = copy.deepcopy(settled(s, args.ctl)['preferences'])
            first, second = status(s, args.ctl)['outputs']
            oid = first['id']
            def out(target=oid):
                return next(o for o in status(s, args.ctl)['outputs'] if o['id'] == target)
            def probe(target=oid):
                return ctl(s, args.ctl, 'aqueous', 'status', '--text', 'test-bar-autohide:' + target)['result']
            def expect(visible, target=oid):
                try:
                    return wait_for(lambda: (lambda o: o if o['bar_visible'] == visible else False)(out(target)))
                except TimeoutError:
                    (s.output / 'failed-status.json').write_text(json.dumps(status(s, args.ctl), indent=2))
                    (s.output / 'failed-compositor.json').write_text(json.dumps(ipc.state(), indent=2))
                    (s.output / 'failed-sensor.json').write_text(json.dumps(probe(target), indent=2))
                    capture(s, 'failed')
                    raise
            def move(x, y):
                outputs = ipc.outputs().values()
                left = min(o['bounds']['x'] for o in outputs)
                top = min(o['bounds']['y'] for o in ipc.outputs().values())
                s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
                s.run(['wlrctl', 'pointer', 'move', str(x-left), str(y-top)])
            def away():
                b = out()['bounds']
                move(b['x'] + b['width']//2, b['y'] + b['height']//2)
            def reveal():
                o = out(); b = o['bounds']; edge = o['bar_edge']
                vertical = edge in ('left', 'right')
                wait_for(lambda: (lambda v: v['sensor_mapped'] and v['sensor_width'] == (2 if vertical else b['width']) and v['sensor_height'] == (b['height'] if vertical else 2))(probe()))
                x = b['x'] + (1 if edge == 'left' else b['width']-1 if edge == 'right' else b['width']//2)
                y = b['y'] + (1 if edge == 'top' else b['height']-1 if edge == 'bottom' else b['height']//2)
                move(x, y)
                return expect(True)
            wait_for(lambda: out()['bar_exclusive_zone'] == out()['bar_size'])
            assert out()['bar_mode'] == 'always' and not out()['bar_sensor_visible']
            passed('legacy-visible-reservation')
            prefs = copy.deepcopy(base)
            prefs['outputs'] = []
            prefs['dock']['enabled'] = False
            prefs['bar'].update(mode='autohide', groups=dict(left='launcher,workspaces', center='clock', right='control'))
            away(); apply(s, args.ctl, prefs)
            expect(False)
            wait_for(lambda: out()['usable'] == out()['bounds'])
            for islands in (True, False):
                for edge in ('top', 'bottom', 'left', 'right'):
                    away()
                    prefs['bar'].update(edge=edge, islands=islands)
                    apply(s, args.ctl, prefs)
                    expect(False)
                    usable = out()['usable']
                    assert out()['bar_sensor_visible'] and out()['bar_exclusive_zone'] == -1
                    reveal()
                    time.sleep(.15)
                    assert out()['usable'] == usable
                    # Stay on the edge for longer than the hide delay.
                    time.sleep(.5)
                    assert out()['bar_visible']
                    away()
                    assert out()['bar_visible'], out()
                    reveal()  # Cancel the first pending hide.
                    time.sleep(.5)
                    assert out()['bar_visible']
                    capture(s, f'{edge}-{islands}-revealed', first['connector'])
                    away(); expect(False)
                    assert out()['usable'] == usable and out()['bar_exclusive_zone'] == -1
                    passed(f'{edge}-{islands}-edge-delay-reservation')
            prefs['bar'].update(edge='top', islands=True)
            apply(s, args.ctl, prefs); away(); expect(False)
            fixture = s.child('window', ['python3', FIXTURE, '--id', 'org.pearl.Autohide', '--title', 'Autohide test'])
            fixture.expect('event=fixture-ready')
            win = wait_for(lambda: next((e for e in ipc.state() if e['kind'] == 'window' and e.get('app_id') == 'org.pearl.Autohide'), None))
            ipc.call('command', action='window.move', fields=dict(id=win['id'], output=oid))
            def window():
                return next(e for e in ipc.state() if e['kind'] == 'window' and e['id'] == win['id'])
            ipc.call('command', action='window.maximized', fields=dict(id=win['id'], value=True))
            # Outer geometry includes compositor decoration extents. Require
            # the full desktop apart from that small border, not a bar-sized gap.
            wait_for(lambda: window()['maximized'] and window()['outer_geometry']['width'] >= out()['bounds']['width']-16 and window()['outer_geometry']['height'] >= out()['bounds']['height']-16)
            geometry = window()['outer_geometry']
            reveal(); away(); expect(False)
            assert window()['outer_geometry'] == geometry
            ipc.call('command', action='window.maximized', fields=dict(id=win['id'], value=False))
            passed('real-maximized-window-fills-output-without-reveal-resize')
            ipc.call('command', action='window.fullscreen', fields=dict(id=win['id'], value=True))
            away(); expect(False); reveal()
            capture(s, 'fullscreen-revealed', first['connector'])
            # A real bar button click must work above the fullscreen client.
            wait_for(lambda: out()['island_rects'][1] is not None)
            rect = out()['island_rects'][1]; b = out()['bounds']
            click(s, b['x']+rect['x']+rect['width']//2, b['y']+rect['y']+rect['height']//2, ipc.outputs())
            wait_for(lambda: status(s, args.ctl)['popup'] is not None)
            away(); time.sleep(.6)
            assert out()['bar_visible'] and out()['bar_visibility_reason'] == 'interaction'
            ctl(s, args.ctl, 'popup', 'hide'); away(); expect(False)
            ipc.call('command', action='window.fullscreen', fields=dict(id=win['id'], value=False))
            passed('fullscreen-real-click-popup-hold')
            for edge in ('top', 'bottom', 'left', 'right'):
                prefs['bar']['edge'] = edge
                apply(s, args.ctl, prefs); away(); expect(False)
                ctl(s, args.ctl, 'calendar', 'toggle', '--output', oid)
                expect(True); away(); time.sleep(.6)
                assert out()['bar_visibility_reason'] == 'interaction'
                r = status(s, args.ctl)['popup']['rect']; o = out(); b = o['bounds']; size = o['bar_size']
                if edge == 'top': assert r['y'] >= size
                if edge == 'bottom': assert r['y']+r['height'] <= b['height']-size
                if edge == 'left': assert r['x'] >= size
                if edge == 'right': assert r['x']+r['width'] <= b['width']-size
                assert probe()['keyboard_mode'] == 'none'
                ctl(s, args.ctl, 'launcher', 'show', '--output', second['id'])
                expect(False); expect(True, second['id'])
                s.run(['wtype', '-k', 'Escape'])
                wait_for(lambda: status(s, args.ctl)['popup'] is None)
                expect(False, second['id'])
            passed('anchored-popup-placement-holds-and-output-replacement')
            prefs['popup']['placement'] = 'centered'
            apply(s, args.ctl, prefs)
            ctl(s, args.ctl, 'calendar', 'toggle', '--output', oid)
            r = status(s, args.ctl)['popup']['rect']; b = out()['bounds']
            assert r['width'] == 440 and r['height'] == 480
            assert r['x'] == (b['width']-r['width'])//2 and r['y'] == (b['height']-r['height'])//2
            ctl(s, args.ctl, 'popup', 'hide')
            prefs['popup']['placement'] = 'anchored'
            apply(s, args.ctl, prefs); away(); expect(False)
            passed('centered-popup-preserves-size-and-position')
            reveal(); active(False)
            wait_for(lambda: out()['bar_visibility_reason'] == 'inhibited')
            assert not out()['bar_sensor_visible']
            # Inhibition is immediate; the existing 180 ms hide fade finishes asynchronously.
            wait_for(lambda: not out()['bar_visible'], 2)
            ctl(s, args.ctl, 'launcher', 'show', '--output', oid, code=4)
            active(True); away(); expect(False)
            wait_for(lambda: out()['bar_sensor_visible'])
            reveal(); away(); expect(False)
            passed('session-inhibition-and-recovery')
            # The strip follows logical geometry after live scale/origin/rotation changes.
            s.run(['wlr-randr', '--output', first['connector'], '--scale', '1.5', '--transform', '90', '--pos', '-480,0'])
            wait_for(lambda: out()['scale'] == 1.5 and out()['bounds']['x'] < 0 and out()['bounds']['height'] > out()['bounds']['width'])
            away(); expect(False); reveal(); away(); expect(False)
            s.run(['wlr-randr', '--output', first['connector'], '--scale', '1', '--transform', 'normal', '--pos', '0,0'])
            wait_for(lambda: out()['scale'] == 1 and out()['bounds']['width'] == 1280)
            passed('scaled-rotated-negative-origin-reveal')
            # A hidden bar still owns its edge; CLI sizing must not restore a zone.
            ctl(s, args.ctl, 'frame', 'set', '--output', oid, '--edge', 'right', '--size', '8', code=4)
            ctl(s, args.ctl, 'frame', 'set', '--output', oid, '--edge', 'top', '--size', '8')
            wait_for(lambda: out()['usable']['height'] == out()['bounds']['height'] - 8)
            ctl(s, args.ctl, 'bar', 'set', '--output', oid, '--edge', 'bottom', '--size', '64')
            away(); expect(False); reveal()
            assert out()['bar_exclusive_zone'] == -1 and out()['bar_size'] >= 64
            ctl(s, args.ctl, 'frame', 'set', '--output', oid, '--edge', 'top', '--size', '0')
            passed('frame-ownership-and-cli-sizing-without-reservation')
            fixture.stop()
            prefs['bar'].update(edge='top', islands=True)
            apply(s, args.ctl, prefs); away(); expect(False)
            underlay = s.child('underlay', ['python3', ROOT / 'tests/fixtures/desktop/island-underlay.py'], LD_PRELOAD='libgtk4-layer-shell.so', G_DEBUG='fatal-warnings')
            underlay.expect('event=underlay-ready')
            def clicks():
                return sum('event=underlay-click' in line for line in underlay.lines)
            capture(s, 'hidden-input-underlay', first['connector'])
            away(); expect(False)
            count = clicks(); b = out()['bounds']
            # Move within the output: saturating at (0,0) would reveal the bar.
            s.run(['wlrctl', 'pointer', 'move', str(20-b['width']//2), str(20-b['height']//2)])
            s.run(['wlrctl', 'pointer', 'click'])
            wait_for(lambda: clicks() > count)
            reveal()
            wait_for(lambda: (lambda r: all(v is not None for v in r) and r[0]['x']+r[0]['width'] < r[1]['x'])(out()['island_rects']))
            r = out()['island_rects']; gap = (r[0]['x']+r[0]['width']+r[1]['x'])//2
            count = clicks()
            click(s, b['x']+gap, b['y']+20, ipc.outputs())
            wait_for(lambda: clicks() > count)
            assert status(s, args.ctl)['popup'] is None
            underlay.stop(); away(); expect(False)
            passed('hidden-controls-and-island-gaps-pass-input-through')
            if args.skip_hotplug:
                report['limitations'] = ['Output removal skipped: this compositor build asserts in OutputManager.validateConfigCoordinates. Run against the surface-test baseline without --skip-hotplug.']
            else:
                # Remove an output with an active popup hold, then restore its saved mode.
                ctl(s, args.ctl, 'launcher', 'show', '--output', second['id'])
                expect(True, second['id'])
                s.run(['wlr-randr', '--output', second['connector'], '--off'])
                wait_for(lambda: len(status(s, args.ctl)['outputs']) == 1 and status(s, args.ctl)['popup'] is None)
                s.run(['wlr-randr', '--output', second['connector'], '--on'])
                wait_for(lambda: len(status(s, args.ctl)['outputs']) == 2)
                second = next(o for o in status(s, args.ctl)['outputs'] if o['connector'] == second['connector'])
                assert second['bar_mode'] == 'autohide'
                ctl(s, args.ctl, 'launcher', 'show', '--output', second['id'])
                expect(True, second['id']); ctl(s, args.ctl, 'popup', 'hide'); away(); expect(False, second['id'])
                passed('output-removal-releases-popup-and-restores-autohide')
            prefs['outputs'] = [dict(connector=second['connector'], bar=dict(edge='top'))]
            apply(s, args.ctl, prefs)
            assert out(second['id'])['bar_mode'] == 'always'
            assert out()['bar_mode'] == 'autohide'
            passed('complete-output-override-defaults')
            prefs['bar'].update(mode='always', size=64)
            apply(s, args.ctl, prefs)
            wait_for(lambda: out()['bar_exclusive_zone'] == out()['bar_size'] >= 64)
            assert not out()['bar_sensor_visible']
            passed('always-mode-restores-measured-reservation')
            prefs['bar']['mode'] = 'autohide'; apply(s, args.ctl, prefs)
            away(); expect(False)
            ctl(s, args.ctl, 'quit'); clean(app)
            app = s.child('pearl-restarted', [args.pearl], G_DEBUG='fatal-warnings')
            app.expect('event=control-ready'); expect(False)
            assert out()['bar_mode'] == 'autohide' and out()['bar_exclusive_zone'] == -1
            reveal(); away(); expect(False)
            ctl(s, args.ctl, 'quit'); clean(app)
            passed('restart-remap-and-clean-shutdown')
            ipc.close()
        report['status'] = 'passed'
    except Exception as exc:
        report.update(status='failed', error=repr(exc))
        raise
    finally:
        (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
