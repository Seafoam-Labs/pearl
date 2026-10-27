#!/usr/bin/env python3
"""Exercise native Pearl brightness through a private libddcutil ABI and logind."""
import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import time
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, fixture_prefix, fixture_source, wait_for
from t00 import Session as T00Session
from test_services import services, await_services, command, burst
from test_surfaces import ctl, status, capture, eventually_status, IPC
from wayland_test_input import press_keys, pointer_move
from settings_navigation import report
from test_preferences import state, apply


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('pearl', 'ctl', 'ddc-library'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/display-brightness')
    args = parser.parse_args()
    args.pearl = args.pearl.resolve()
    args.ctl = args.ctl.resolve()
    args.ddc_library = args.ddc_library.resolve()
    args.output = args.output.resolve()
    checks = []
    with PrivateSession(args.output / 'session', tool_prefix=fixture_prefix()) as s:
        s.args = SimpleNamespace(aqueous_source=str(fixture_source()))
        T00Session.input_fixture(s)
        root = s.base / 'backlight'
        (root / 'test_panel').mkdir(parents=True)
        (root / 'test_panel/max_brightness').write_text('1000\n')
        (root / 'test_panel/brightness').write_text('420\n')
        drm = s.base / 'drm'; drm.mkdir()
        ddc = s.base / 'ddc'; ddc.mkdir()
        lib = s.base / 'lib'; lib.mkdir()
        shutil.copyfile(args.ddc_library, lib / 'libddcutil.so.5')
        for index, value in ((1, 68), (2, 42)):
            connector = drm / f'card0-HEADLESS-{index}'
            connector.mkdir()
            (connector / 'status').write_text('connected\n')
            (connector / 'edid').write_bytes(bytes([index]) + bytes(127))
            (ddc / str(index)).write_text(str(value))
        s.env.update(PEARL_TEST_BACKLIGHT=str(root), PEARL_TEST_DRM=str(drm),
                     PEARL_TEST_DDC=str(ddc), PEARL_TEST_POWER_LOG=str(s.output / 'power.jsonl'),
                     DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(s.runtime / 'system-bus'))
        s.env['LD_LIBRARY_PATH'] = str(lib) + ':' + s.env.get('LD_LIBRARY_PATH', '')
        s.child('system-bus', ['dbus-daemon', '--session', '--nofork', '--address=' + s.env['DBUS_SYSTEM_BUS_ADDRESS']])
        wait_for(lambda: s.run(['busctl', '--address=' + s.env['DBUS_SYSTEM_BUS_ADDRESS'], 'list'], check=False).returncode == 0)
        power = s.child('power', ['python3', ROOT / 'tests/fixtures/services/power.py'], input_pipe=True)
        power.expect('event=ready')
        pearl = s.child('pearl', [args.pearl.resolve()], G_DEBUG='fatal-warnings')
        pearl.expect('event=control-ready')

        def display(snapshot, output):
            return next(d for d in snapshot['displays'] if d['output'] == output)

        await_services(s, args.ctl, lambda v: len(v['displays']) == 3 and all(d['available'] for d in v['displays']))
        checks.append('mixed-logind-and-ddc-discovery')
        ctl(s, args.ctl, 'brightness', 'set', '--output', 'HEADLESS-1', '--percent', '76')
        await_services(s, args.ctl, lambda v: display(v, 'HEADLESS-1')['percent'] == 76 and not display(v, 'HEADLESS-1')['pending'])
        assert (ddc / '1').read_text().strip() == '76'
        assert (ddc / '2').read_text().strip() == '42'
        checks.append('targeted-ddc-write-and-readback')
        burst(s, args.ctl, 'brightness_set', [{'percent': p} for p in (20, 31, 48, 83)], output='HEADLESS-1')
        ctl(s, args.ctl, 'brightness', 'set', '--output', 'HEADLESS-2', '--percent', '55')
        await_services(s, args.ctl, lambda v: display(v, 'HEADLESS-1')['percent'] == 83 and display(v, 'HEADLESS-2')['percent'] == 55 and not any(d['pending'] for d in v['displays']))
        checks.append('coalescing-preserves-final-intent-per-display')
        burst(s, args.ctl, 'brightness_set', [{'delta': 5} for _ in range(3)], output='HEADLESS-2')
        await_services(s, args.ctl, lambda v: display(v, 'HEADLESS-2')['percent'] == 70 and not display(v, 'HEADLESS-2')['pending'])
        checks.append('repeated-brightness-keys-accumulate-intent')
        ctl(s, args.ctl, 'brightness', 'set', '--output', 'test_panel', '--percent', '61')
        await_services(s, args.ctl, lambda v: any(d['id'] == 'test_panel' and d['percent'] == 61 for d in v['displays']))
        checks.append('existing-logind-backend')
        (ddc / '1.deny').write_text('1')
        ctl(s, args.ctl, 'brightness', 'set', '--output', 'HEADLESS-1', '--percent', '22')
        failed = await_services(s, args.ctl, lambda v: v['power']['err'] and 'denied' in v['power']['err'].lower())
        assert display(failed, 'HEADLESS-1')['percent'] == 83
        checks.append('denial-keeps-confirmed-value')
        (ddc / '1.deny').unlink()
        command(power, active=False)
        await_services(s, args.ctl, lambda v: not any(d['available'] for d in v['displays']))
        ctl(s, args.ctl, 'brightness', 'set', '--output', 'HEADLESS-2', '--percent', '10', code=4)
        command(power, active=True)
        await_services(s, args.ctl, lambda v: display(v, 'HEADLESS-2')['available'])
        checks.append('inactive-session-rejects-ddc-write')
        # Identical EDIDs are deliberately ambiguous. No arbitrary monitor wins.
        twin = drm / 'card1-DP-1'; twin.mkdir()
        (twin / 'status').write_text('connected\n'); (twin / 'edid').write_bytes(bytes([2]) + bytes(127))
        await_services(s, args.ctl, lambda v: not display(v, 'HEADLESS-2')['available'] and 'ambiguous' in display(v, 'HEADLESS-2')['reason'])
        ctl(s, args.ctl, 'brightness', 'set', '--output', 'HEADLESS-2', '--percent', '10', code=4)
        shutil.rmtree(twin)
        await_services(s, args.ctl, lambda v: display(v, 'HEADLESS-2')['available'])
        checks.append('duplicate-edid-rejected-and-recovered')
        # Different monitors can have the same connector name on separate GPUs.
        # Stable device IDs still work, but neither may claim the Wayland output.
        second_id = display(services(s, args.ctl), 'HEADLESS-2')['id']
        twin = drm / 'card1-HEADLESS-2'; twin.mkdir()
        (twin / 'status').write_text('connected\n'); (twin / 'edid').write_bytes(bytes([3]) + bytes(127))
        (ddc / '3').write_text('39')
        await_services(s, args.ctl, lambda v: len([d for d in v['displays'] if d['backend'] == 'ddc' and d['output'] == '']) == 2)
        ctl(s, args.ctl, 'brightness', 'set', '--output', 'HEADLESS-2', '--percent', '10', code=4)
        ctl(s, args.ctl, 'brightness', 'set', '--output', second_id, '--percent', '70')
        await_services(s, args.ctl, lambda v: not any(d['pending'] for d in v['displays']))
        assert (ddc / '2').read_text().strip() == '70' and (ddc / '3').read_text().strip() == '39'
        shutil.rmtree(twin)
        await_services(s, args.ctl, lambda v: display(v, 'HEADLESS-2')['available'])
        checks.append('duplicate-connectors-do-not-guess-output-associations')
        # Replacement at the same connector gets a new stable device id.
        old = display(services(s, args.ctl), 'HEADLESS-1')['id']
        (drm / 'card0-HEADLESS-1/edid').write_bytes(bytes([3]) + bytes(127))
        (ddc / '3').write_text('39')
        await_services(s, args.ctl, lambda v: display(v, 'HEADLESS-1')['id'] != old and display(v, 'HEADLESS-1')['percent'] == 39)
        ctl(s, args.ctl, 'brightness', 'set', '--output', old, '--percent', '10', code=4)
        checks.append('replacement-invalidates-old-target')
        output = status(s, args.ctl)['outputs'][0]
        ctl(s, args.ctl, 'control-center', 'show', '--output', output['id'])
        time.sleep(.5)
        capture(s, 'native-flyout', output['connector'])
        # Tab through the real native controls, then invoke the screen-power button.
        for _ in range(40):
            if report(s, args.ctl).get('button') == 'Turn off display':
                break
            press_keys(s, 'Tab')
        else:
            raise AssertionError('Display power button is not keyboard reachable')
        ipc = IPC(s)
        press_keys(s, 'Return')
        wait_for(lambda: any(not o['powered'] for o in ipc.state() if o['kind'] == 'output'))
        assert len([o for o in ipc.state() if o['kind'] == 'output' and o['enabled']]) == 2
        pointer_move(s, 10, 10)
        wait_for(lambda: all(o['powered'] for o in ipc.state() if o['kind'] == 'output'))
        checks.append('manual-screen-off-retains-layout-and-wakes-on-input')
        ctl(s, args.ctl, 'popup', 'hide')
        original = state(s, args.ctl)['preferences']
        prefs = json.loads(json.dumps(original))
        prefs['idle']['battery'].update(screen_off_seconds=4, dim=True)
        apply(s, args.ctl, prefs)
        pointer_move(s, 20, 20)
        await_services(s, args.ctl, lambda v: all(d['percent'] == 20 for d in v['displays'] if d['backend'] != 'unavailable'))
        wait_for(lambda: all(not o['powered'] for o in ipc.state() if o['kind'] == 'output'), 8)
        # Let the periodic scan run while asleep; dim restoration must survive it.
        time.sleep(5.5)
        press_keys(s, 'Shift_L')
        wait_for(lambda: all(o['powered'] for o in ipc.state() if o['kind'] == 'output'))
        apply(s, args.ctl, original)
        await_services(s, args.ctl, lambda v: display(v, 'HEADLESS-1')['percent'] == 39 and display(v, 'HEADLESS-2')['percent'] == 70 and any(d['id'] == 'test_panel' and d['percent'] == 61 for d in v['displays']))
        checks.append('idle-dims-all-displays-and-restores-after-sleep')
        ipc.close()
        ctl(s, args.ctl, 'popup', 'hide')
        ctl(s, args.ctl, 'quit')
        assert pearl.wait() == 0
        assert not any('CRITICAL' in line or 'panic:' in line for line in pearl.lines)
        checks.append('native-flyout-lifecycle-with-fatal-gtk-warnings')
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'results.json').write_text(json.dumps({'status': 'passed', 'checks': checks}, indent=2) + '\n')
    print(f'PASS {len(checks)} display brightness integration checks')


if __name__ == '__main__':
    main()
