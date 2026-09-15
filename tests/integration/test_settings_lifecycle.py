#!/usr/bin/env python3
"""F3 popup routing, restored page state and independent backend view owners."""
import argparse, hashlib, json, sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'scripts'))
from pearl_session import PrivateSession, wait_for
from test_surfaces import ctl, status, eventually_status, capture, clean
from settings_navigation import choose_page, report
from test_services import command, await_services
from test_connectivity import await_state, state, action, answer_wifi, focus, key, AP, BA, BD
FIX = ROOT/'tests/fixtures/services'


def settled(s, binary):
    return wait_for(lambda: (r if not (r := report(s, binary))['restoring'] else False))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('pearl', 'ctl', 'spike'): p.add_argument('--'+name, type=Path, required=True)
    p.add_argument('--output', type=Path, default=ROOT/'artifacts/settings-navigation/f3/lifecycle')
    args = p.parse_args()
    for name in ('pearl', 'ctl', 'spike', 'output'): setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    result = dict(status='running', checks=checks, pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(), ctl_sha256=hashlib.sha256(args.ctl.read_bytes()).hexdigest())
    try:
        with PrivateSession(args.output/'session') as s:
            s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path='+str(s.runtime/'system-bus')
            s.child('system-bus', ['dbus-daemon', '--session', '--nofork', '--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda: s.run(['busctl', '--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'], 'list'], check=False).returncode == 0)
            for env_key, filename in [('PEARL_TEST_CONNECTIVITY_LOG', 'connectivity.jsonl'), ('PEARL_TEST_POWER_LOG', 'power.jsonl')]:
                s.env[env_key] = str(s.output/filename); Path(s.env[env_key]).write_text('')
            s.env['PEARL_TEST_BACKLIGHT'] = str(s.base/'backlight')
            backlight = Path(s.env['PEARL_TEST_BACKLIGHT'])/'test_panel'; backlight.mkdir(parents=True)
            (backlight/'max_brightness').write_text('1000\n'); (backlight/'brightness').write_text('420\n')
            network = s.child('network', ['python3', FIX/'connectivity.py', 'network'], input_pipe=True)
            bluetooth = s.child('bluetooth', ['python3', FIX/'connectivity.py', 'bluetooth'], input_pipe=True)
            power = s.child('power', ['python3', FIX/'power.py'], input_pipe=True)
            for child in (network, bluetooth, power): child.expect('event=ready')
            app = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings')
            app.expect('event=control-ready')
            await_state(s, args.ctl, lambda v: v['network']['registered'] and v['bluetooth']['registered'] and not v['network']['settings_loading'])
            await_services(s, args.ctl, lambda v: v['brightness']['available'])
            outputs = status(s, args.ctl)['outputs']; output, other = outputs[:2]
            def open_page(page, verb='show', target=output):
                ctl(s, args.ctl, 'control-center', verb, '--page', page, '--output', target['id'])
                r = eventually_status(s, args.ctl, lambda v: v['popup'] and v['popup']['page'] == page)
                settled(s, args.ctl)
                return r['popup']
            def fixture(op, service, path=None, code=0):
                data = dict(test_owner=op, service=service)
                if path: data['path'] = path
                return ctl(s, args.ctl, 'aqueous', 'draft', '--text', json.dumps(data, separators=(',', ':')), code=code)
            def opens(): return sum('event=popup-opened' in line for line in app.lines)
            for edge in ('top', 'left'):
                ctl(s, args.ctl, 'popup', 'hide')
                ctl(s, args.ctl, 'bar', 'set', '--output', output['id'], '--edge', edge, '--size', '48')
                open_page('sound'); count = opens()
                capture(s, f'{edge}-sound', output['connector'])
                for page in ('network', 'bluetooth', 'power', 'overview'):
                    open_page(page, 'toggle')
                    assert opens() == count, 'Page switch recreated the popup'
                    assert report(s, args.ctl)['heading']
                    capture(s, f'{edge}-{page}', output['connector'])
                ctl(s, args.ctl, 'control-center', 'toggle', '--page', 'overview', '--output', output['id'])
                eventually_status(s, args.ctl, lambda v: v['popup'] is None)
            checks['cli-direct-pages-same-host-switch-and-same-page-toggle'] = True
            open_page('network')
            before = status(s, args.ctl)['popup']
            for page in ('invalid', 'appearance'):
                assert s.run([args.ctl, 'control-center', 'toggle', '--page', page], check=False).returncode == 2
                assert status(s, args.ctl)['popup'] == before
            ctl(s, args.ctl, 'control-center', 'toggle', '--page', 'network', '--output', 'removed', code=4)
            assert status(s, args.ctl)['popup'] == before
            open_page('sound', target=other)
            assert status(s, args.ctl)['popup']['output'] == other['id']
            s.run(['wlr-randr', '--output', other['connector'], '--off'])
            eventually_status(s, args.ctl, lambda v: v['popup'] is None)
            s.run(['wlr-randr', '--output', other['connector'], '--on'])
            checks['invalid-target-preserves-state-output-replacement-and-removal'] = True
            # Focus a stable row at the bottom, then use header navigation.
            open_page('network')
            for _ in range(50):
                if report(s, args.ctl)['button'] == 'Connect saved': break
                s.run(['wtype', '-s', '60', '-k', 'Tab', '-s', '60'])
            else: raise AssertionError('Saved connection control unreachable')
            time.sleep(.2)
            before = report(s, args.ctl)
            assert before['scroll'] > 0 and before['saved_focus'].startswith('settings-focus:connection:'), before
            choose_page(s, args.ctl, 'sound'); settled(s, args.ctl)
            choose_page(s, args.ctl, 'network'); restored = settled(s, args.ctl)
            assert restored['button'] == 'Connect saved', restored
            assert abs(restored['scroll']-before['scroll']) < 2, (before, restored)
            capture(s, 'network-restored', output['connector'])
            open_page('network'); reset = settled(s, args.ctl)
            assert reset['scroll'] == 0 and reset['focus'] == 'heading', reset
            capture(s, 'network-explicit-heading', output['connector'])
            checks['internal-scroll-and-identity-focus-restore-external-heading-reset'] = True
            # Owner replacement invalidates saved row focus; never target a new device.
            for _ in range(50):
                if report(s, args.ctl)['button'] == 'Connect saved': break
                s.run(['wtype', '-s', '60', '-k', 'Tab', '-s', '60'])
            choose_page(s, args.ctl, 'sound'); settled(s, args.ctl)
            command(network, owner=False); await_state(s, args.ctl, lambda v: not v['network']['available'])
            command(network, owner=True); await_state(s, args.ctl, lambda v: v['network']['registered'] and not v['network']['settings_loading'])
            choose_page(s, args.ctl, 'network'); stale = settled(s, args.ctl)
            assert stale['focus'] == 'heading', stale
            checks['stale-service-generation-focus-falls-back-to-heading'] = True
            # Second frontend owns a prompt; navigating/closing the flyout cannot cancel it.
            fixture('acquire', 'network'); fixture('connect', 'network', AP)
            await_state(s, args.ctl, lambda v: v['network']['prompt'])
            assert report(s, args.ctl)['button'] != 'Connect securely'
            ctl(s, args.ctl, 'connectivity', 'action', '--service', 'network', '--action', 'cancel', '--generation', str(state(s, args.ctl)['network']['generation']))
            assert state(s, args.ctl)['network']['prompt']
            open_page('power'); ctl(s, args.ctl, 'popup', 'hide')
            assert state(s, args.ctl)['network']['prompt']
            fixture('release', 'network'); await_state(s, args.ctl, lambda v: not v['network']['pending'] and not v['network']['prompt'])
            # Reverse direction: the fixture cannot answer/cancel the flyout's prompt.
            open_page('network'); fixture('acquire', 'network')
            action(s, args.ctl, 'network', 'connect', AP); await_state(s, args.ctl, lambda v: v['network']['prompt'])
            assert fixture('wrong_answer', 'network')['result']['denied']
            fixture('release', 'network'); assert state(s, args.ctl)['network']['prompt']
            choose_page(s, args.ctl, 'sound'); await_state(s, args.ctl, lambda v: not v['network']['pending'])
            checks['independent-network-prompt-ownership-and-wrong-owner-denial'] = True
            open_page('bluetooth'); fixture('acquire', 'bluetooth')
            fixture('discover', 'bluetooth', BA); await_state(s, args.ctl, lambda v: v['bluetooth']['discovering'])
            open_page('power'); ctl(s, args.ctl, 'popup', 'hide')
            assert state(s, args.ctl)['bluetooth']['discovering']
            fixture('release', 'bluetooth'); await_state(s, args.ctl, lambda v: not v['bluetooth']['discovering'] and not v['bluetooth']['discovery_pending'])
            open_page('bluetooth'); fixture('acquire', 'bluetooth'); fixture('pair', 'bluetooth', BD)
            await_state(s, args.ctl, lambda v: v['bluetooth']['prompt'] == 'confirm')
            open_page('overview'); assert state(s, args.ctl)['bluetooth']['prompt'] == 'confirm'
            fixture('release', 'bluetooth'); await_state(s, args.ctl, lambda v: not v['bluetooth']['pending'])
            open_page('bluetooth'); fixture('acquire', 'bluetooth')
            action(s, args.ctl, 'bluetooth', 'pair', BD)
            await_state(s, args.ctl, lambda v: v['bluetooth']['prompt'] == 'confirm')
            assert fixture('wrong_answer', 'bluetooth')['result']['denied']
            fixture('release', 'bluetooth'); assert state(s, args.ctl)['bluetooth']['prompt'] == 'confirm'
            open_page('sound'); await_state(s, args.ctl, lambda v: not v['bluetooth']['pending'])
            checks['independent-bluetooth-discovery-and-pairing-ownership'] = True
            # Finishing a connection releases operation ownership, not the connection.
            open_page('network'); action(s, args.ctl, 'network', 'connect', AP)
            await_state(s, args.ctl, lambda v: v['network']['prompt'])
            answer_wifi(s, app, 'fixture-wifi-password')
            connected = lambda v, kind: any(i['kind'] == kind and i['connected'] for i in v['items'])
            await_state(s, args.ctl, lambda v: not v['network']['pending'] and connected(v, 'network_device'))
            open_page('bluetooth'); assert connected(state(s, args.ctl), 'network_device')
            action(s, args.ctl, 'bluetooth', 'pair', BD)
            await_state(s, args.ctl, lambda v: v['bluetooth']['prompt'] == 'confirm')
            wait_for(lambda: focus(app) == 'bluetooth-confirm'); key(s, '-k', 'space')
            await_state(s, args.ctl, lambda v: not v['bluetooth']['pending'])
            action(s, args.ctl, 'bluetooth', 'connect', BD)
            await_state(s, args.ctl, lambda v: not v['bluetooth']['pending'] and connected(v, 'bluetooth_device'))
            open_page('sound'); ctl(s, args.ctl, 'popup', 'hide')
            assert connected(state(s, args.ctl), 'network_device') and connected(state(s, args.ctl), 'bluetooth_device')
            checks['established-network-and-device-connections-survive-departure-and-close'] = True
            fixture('acquire', 'power'); open_page('power'); choose_page(s, args.ctl, 'sound'); settled(s, args.ctl)
            assert report(s, args.ctl)['interest']['power']
            assert fixture('release', 'power')['result']['power'] == 0
            assert not report(s, args.ctl)['interest']['power']
            checks['power-polling-interest-survives-another-view-leaving'] = True
            # Lock revokes every host, not only the current flyout.
            fixture('acquire', 'network'); fixture('connect', 'network', AP)
            await_state(s, args.ctl, lambda v: v['network']['prompt'])
            fixture('acquire', 'bluetooth'); fixture('discover', 'bluetooth', BA)
            await_state(s, args.ctl, lambda v: v['bluetooth']['discovering'])
            locker = s.child('locker', [args.spike], input_pipe=True, PEARL_T00_ISOLATED='1', WLR_BACKENDS='headless', PEARL_T00_MODE='plain')
            locker.expect('T00 event=ready'); locker.proc.stdin.write('lock\n'); locker.proc.stdin.flush(); locker.expect('T00 event=locked')
            eventually_status(s, args.ctl, lambda v: v['popup'] is None)
            await_state(s, args.ctl, lambda v: not v['network']['prompt'] and not v['network']['pending'] and not v['bluetooth']['discovering'])
            reply = ctl(s, args.ctl, 'control-center', 'show', '--page', 'sound', code=4)
            assert reply['err']['code'] == 'Locked', reply
            locker.proc.stdin.write('unlock\n'); locker.proc.stdin.flush(); locker.expect('T00 event=unlocked')
            # Revoked owner tokens cannot replay work after unlocking.
            wait_for(lambda: not ctl(s, args.ctl, 'session', 'status')['result']['notifications']['locked'])
            assert not status(s, args.ctl)['popup']
            assert fixture('connect', 'network', AP, code=4)['err']['code'] == 'Unavailable'
            fixture('release', 'network'); fixture('release', 'bluetooth')
            locker.proc.stdin.write('quit\n'); locker.proc.stdin.flush(); clean(locker)
            open_page('power'); s.run(['wtype', '-s', '200', '-k', 'Escape', '-s', '100'])
            eventually_status(s, args.ctl, lambda v: v['popup'] is None)
            checks['lock-revokes-all-owners-rejects-replay-and-escape-dismisses'] = True
            open_page('network'); action(s, args.ctl, 'network', 'connect', AP)
            await_state(s, args.ctl, lambda v: v['network']['prompt'])
            s.run(['wlr-randr', '--output', output['connector'], '--off'])
            eventually_status(s, args.ctl, lambda v: v['popup'] is None)
            await_state(s, args.ctl, lambda v: not v['network']['pending'] and not v['network']['prompt'])
            assert fixture('acquire', 'network')['result']['network'] == 1
            fixture('release', 'network')
            checks['output-removal-cancels-prompt-and-releases-only-departing-view'] = True
            ctl(s, args.ctl, 'quit'); clean(app)
        result['status'] = 'passed'
    finally:
        (args.output/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
