#!/usr/bin/env python3
"""F2: compact page composition with private services and actual GTK input."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time
from PIL import ImageChops

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from test_surfaces import ctl, status, capture, clean, eventually_status
from settings_navigation import PAGES, choose_page, report, show_page
from test_services import await_services, command
from test_connectivity import await_state, action, AP, BA

FIX = ROOT / 'tests/fixtures/services'
TITLES = dict(overview='Overview', network='Network', bluetooth='Bluetooth', sound='Sound', power='Power & battery')


def assert_page(s, binary, page):
    r = report(s, binary)
    assert r['heading'] == TITLES[page], r
    assert r['page'] == page and r['populated_pages'] == 1 and r['viewports'] == 5, r
    assert r['body_height'] > 0 and r['body_width'] > 0, r
    assert r['interest'] == {name: name == page for name in ('network', 'bluetooth', 'power')}, r
    body = '\n'.join(r['labels'])
    if page != 'overview':
        assert 'Workspace layout' not in body and 'Session & security' not in body and 'Media controls' not in body, body
    if page != 'sound':
        assert 'Output, input and applications' not in body, body
    if page != 'power':
        assert 'Power and brightness' not in body, body
    if page != 'network':
        assert 'Adapters, nearby and saved networks' not in body, body
    if page != 'bluetooth':
        assert 'Adapters and devices' not in body, body
    return r


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pearl', type=Path, required=True)
    p.add_argument('--ctl', type=Path, required=True)
    p.add_argument('--output', type=Path, default=ROOT/'artifacts/settings-navigation/f2/pages')
    args = p.parse_args()
    args.pearl, args.ctl, args.output = args.pearl.resolve(), args.ctl.resolve(), args.output.resolve()
    checks = {}
    result = dict(status='running', checks=checks, pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(), ctl_sha256=hashlib.sha256(args.ctl.read_bytes()).hexdigest())
    args.output.mkdir(parents=True, exist_ok=True)
    try:
        with PrivateSession(args.output/'populated') as s:
            s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path='+str(s.runtime/'system-bus')
            s.child('system-bus', ['dbus-daemon', '--session', '--nofork', '--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda: s.run(['busctl', '--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'], 'list'], check=False).returncode == 0)
            s.env['PEARL_TEST_CONNECTIVITY_LOG'] = str(s.output/'connectivity-actions.jsonl')
            s.env['PEARL_TEST_POWER_LOG'] = str(s.output/'power-actions.jsonl')
            for name in ('PEARL_TEST_CONNECTIVITY_LOG', 'PEARL_TEST_POWER_LOG'):
                Path(s.env[name]).write_text('')
            s.env['PEARL_TEST_BACKLIGHT'] = str(s.base/'backlight')
            backlight = Path(s.env['PEARL_TEST_BACKLIGHT'])/'test_panel'
            backlight.mkdir(parents=True)
            (backlight/'max_brightness').write_text('1000\n')
            (backlight/'brightness').write_text('420\n')
            power = s.child('power', ['python3', FIX/'power.py'], input_pipe=True)
            network = s.child('network', ['python3', FIX/'connectivity.py', 'network'], input_pipe=True)
            bluetooth = s.child('bluetooth', ['python3', FIX/'connectivity.py', 'bluetooth'], input_pipe=True)
            for child in (power, network, bluetooth): child.expect('event=ready')
            s.env['PIPEWIRE_REMOTE'] = 'pipewire-0'
            s.child('pipewire', ['pipewire', '-c', FIX/'pipewire.conf'])
            wait_for(lambda: (s.runtime/'pipewire-0').is_socket())
            s.child('pulse', ['pipewire-pulse', '-c', FIX/'pulse.conf'])
            wait_for(lambda: s.run(['pactl', 'info'], check=False).returncode == 0)
            s.run(['pactl', 'load-module', 'module-null-sink', 'sink_name=test_speakers', 'sink_properties=device.description=Test_Speakers'])
            s.run(['pactl', 'set-default-sink', 'test_speakers'])
            s.run(['pactl', 'set-default-source', 'test_speakers.monitor'])
            s.run(['pw-metadata', '-n', 'default', '0', 'default.audio.sink', '{"name":"test_speakers"}', 'Spa:String:JSON'])
            s.run(['pw-metadata', '-n', 'default', '0', 'default.audio.source', '{"name":"test_speakers"}', 'Spa:String:JSON'])
            s.child('playback', ['pacat', '--playback', '--raw', '--device=test_speakers', '/dev/zero'])
            s.child('recording', ['pacat', '--record', '--raw', '--device=test_speakers.monitor', '/dev/null'])
            app = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings')
            app.expect('event=control-ready')
            await_services(s, args.ctl, lambda v: v['audio']['count'] >= 4 and all(v['power']['profiles']))
            await_state(s, args.ctl, lambda v: v['network']['registered'] and v['bluetooth']['registered'] and not v['network']['settings_loading'])
            output = status(s, args.ctl)['outputs'][0]
            snapshots = {}
            for edge in ('top', 'left'):
                ctl(s, args.ctl, 'popup', 'hide')
                ctl(s, args.ctl, 'bar', 'set', '--output', output['id'], '--edge', edge, '--size', '48')
                ctl(s, args.ctl, 'control-center', 'show', '--output', output['id'])
                for page in ('overview', 'sound', 'network', 'bluetooth', 'power'):
                    choose_page(s, args.ctl, page)
                    time.sleep(.2)
                    snapshots[f'{edge}-{page}'] = assert_page(s, args.ctl, page)
                    capture(s, f'{edge}-{page}', output['connector'])
            records = [json.loads(line) for line in Path(s.env['PEARL_TEST_CONNECTIVITY_LOG']).read_text().splitlines()]
            assert not any(r['kind'] in ('scan', 'StartDiscovery') for r in records), records
            checks['five-separate-pages-horizontal-and-vertical'] = True
            checks['selected-service-interest-only-and-no-implicit-scans'] = True
            assert any('Playback' in text for text in snapshots['top-sound']['labels']), snapshots['top-sound']
            assert any('Recording' in text for text in snapshots['top-sound']['labels']), snapshots['top-sound']
            for text in ('Media controls', 'Window overview', 'Pearl settings', 'Aqueous settings', 'Session & security', 'Workspace layout', 'Power off…', 'Restart…'):
                assert text in snapshots['top-overview']['labels'], text
            checks['application-streams-and-overview-control-coverage'] = True
            # Overview power controls use real input against the private login service.
            def focus_button(label):
                for _ in range(60):
                    if report(s, args.ctl)['button'] == label:
                        return
                    s.run(['wtype', '-s', '50', '-k', 'Tab', '-s', '50'])
                raise AssertionError('Missing power action: '+label)

            def power_records():
                return [json.loads(line) for line in Path(s.env['PEARL_TEST_POWER_LOG']).read_text().splitlines()]

            show_page(s, args.ctl, 'overview', output['id'])
            focus_button('Power off…')
            s.run(['wtype', '-s', '100', '-k', 'space', '-s', '300'])
            assert 'Confirm power off' in report(s, args.ctl)['labels']
            assert not any(r['kind'] == 'PowerOff' for r in power_records())
            focus_button('Cancel')
            s.run(['wtype', '-s', '100', '-k', 'space', '-s', '300'])
            assert 'Confirm power off' not in report(s, args.ctl)['labels']
            focus_button('Power off…')
            s.run(['wtype', '-s', '100', '-k', 'space', '-s', '300'])
            choose_page(s, args.ctl, 'sound')
            choose_page(s, args.ctl, 'overview')
            assert 'Confirm power off' not in report(s, args.ctl)['labels']
            focus_button('Power off…')
            s.run(['wtype', '-s', '100', '-k', 'space', '-s', '300'])
            assert not any(r['kind'] == 'PowerOff' for r in power_records())
            s.run(['wtype', '-s', '100', '-k', 'space', '-s', '300'])
            wait_for(lambda: any(r['kind'] == 'PowerOff' and r.get('accepted') for r in power_records()))
            checks['overview-power-confirmation-cancel-and-page-departure'] = True
            # Scroll actual content to its end; the fixed header pixels stay put.
            choose_page(s, args.ctl, 'network')
            rect = status(s, args.ctl)['popup']['rect']
            # The first output starts at the origin in this private fixture.
            s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
            s.run(['wlrctl', 'pointer', 'move', str(rect['x']+rect['width']//2), str(rect['y']+200)])
            time.sleep(.2)
            before = capture(s, 'network-before-scroll', output['connector'])
            s.run(['wlrctl', 'pointer', 'scroll', '1000', '0'])
            wait_for(lambda: report(s, args.ctl)['scroll'] > 0)
            time.sleep(.3)
            after = capture(s, 'network-scrolled', output['connector'])
            header = (rect['x'], rect['y'], rect['x']+rect['width'], rect['y']+65)
            assert ImageChops.difference(before.crop(header), after.crop(header)).getbbox() is None
            assert_page(s, args.ctl, 'network')
            checks['scrolling-body-keeps-fixed-header-and-single-category'] = True
            # Overview links open all retained task controls with actual keyboard input.
            for label, pane in (('Media controls', 'media'), ('Pearl settings', 'settings'), ('Aqueous settings', 'aqueous_settings')):
                show_page(s, args.ctl, 'overview', output['id'])
                for _ in range(40):
                    if report(s, args.ctl)['button'] == label: break
                    s.run(['wtype', '-s', '50', '-k', 'Tab', '-s', '50'])
                else: raise AssertionError('Missing Overview action: '+label)
                s.run(['wtype', '-s', '100', '-k', 'space', '-s', '200'])
                eventually_status(s, args.ctl, lambda v: v['popup'] and v['popup']['pane'] == pane)
                if pane == 'media': assert status(s, args.ctl)['media_views'] == 1
            show_page(s, args.ctl, 'overview', output['id'])
            assert status(s, args.ctl)['media_views'] == 0
            checks['overview-links-open-existing-task-controls'] = True
            # Departure uses the existing backend cancellation and generation guards.
            choose_page(s, args.ctl, 'network')
            action(s, args.ctl, 'network', 'connect', AP)
            await_state(s, args.ctl, lambda v: v['network']['prompt'])
            s.run(['wtype', '-s', '200', 'fixture-partial-secret', '-s', '100'])
            choose_page(s, args.ctl, 'sound')
            await_state(s, args.ctl, lambda v: not v['network']['prompt'] and not v['network']['pending'])
            choose_page(s, args.ctl, 'bluetooth')
            action(s, args.ctl, 'bluetooth', 'discover', BA)
            await_state(s, args.ctl, lambda v: v['bluetooth']['discovering'])
            choose_page(s, args.ctl, 'overview')
            await_state(s, args.ctl, lambda v: not v['bluetooth']['discovering'] and not v['bluetooth']['discovery_pending'])
            checks['page-departure-clears-prompt-and-stops-owned-discovery'] = True
            (s.output/'pages.json').write_text(json.dumps(snapshots, indent=2)+'\n')
            ctl(s, args.ctl, 'quit'); clean(app)
        with PrivateSession(args.output/'unavailable') as s:
            app = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings')
            app.expect('event=control-ready')
            output = eventually_status(s, args.ctl, lambda v: len(v['outputs']) == 2)['outputs'][0]
            ctl(s, args.ctl, 'control-center', 'show', '--output', output['id'])
            snapshots = {}
            for page in ('sound', 'network', 'bluetooth', 'power'):
                choose_page(s, args.ctl, page)
                time.sleep(.2)
                snapshots[page] = assert_page(s, args.ctl, page)
                capture(s, page, output['connector'])
            assert any('unavailable' in label.lower() or 'disconnected' in label.lower() for label in snapshots['sound']['labels']), snapshots['sound']
            assert 'NetworkManager unavailable' in snapshots['network']['labels']
            assert 'BlueZ unavailable' in snapshots['bluetooth']['labels']
            assert 'No battery reported' in snapshots['power']['labels']
            checks['unavailable-service-pages-and-no-battery'] = True
            (s.output/'pages.json').write_text(json.dumps(snapshots, indent=2)+'\n')
            ctl(s, args.ctl, 'quit'); clean(app)
        result['status'] = 'passed'
    finally:
        (args.output/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
