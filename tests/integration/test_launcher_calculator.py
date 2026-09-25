#!/usr/bin/env python3
"""Launcher calculator acceptance on private Wayland, D-Bus, clipboard and PAM."""
import argparse
import hashlib
import json
import statistics
import sys
import time
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from t00 import Session as T00Session
from test_surfaces import IPC, ctl, status, capture, clean, click
from test_desktop import desktop, keys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ('pearl', 'ctl', 'locker', 'pam-module', 'producer'):
        parser.add_argument('--' + arg, type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/launcher-calculator/latest')
    args = parser.parse_args()
    for key, value in vars(args).items():
        setattr(args, key, value.resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    report = {'status': 'running', 'checks': {}, 'binaries': {
        key: hashlib.sha256(getattr(args, key).read_bytes()).hexdigest()
        for key in ('pearl', 'ctl', 'locker', 'pam_module', 'producer')}}
    checks = report['checks']
    try:
        with PrivateSession(args.output / 'session') as s:
            s.env['GTK_A11Y'] = 'test'
            s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path=' + str(s.runtime / 'system-bus')
            s.child('system-bus', ['dbus-daemon', '--session', '--nofork', '--address=' + s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda: s.run(['busctl', '--address=' + s.env['DBUS_SYSTEM_BUS_ADDRESS'], 'list'], check=False).returncode == 0)
            s.env['PEARL_SECURITY_LOG'] = str(s.output / 'security.jsonl')
            Path(s.env['PEARL_SECURITY_LOG']).write_text('')
            s.env['PEARL_TEST_LOCKER'] = str(args.locker)
            pam = s.base / 'pam'
            pam.mkdir()
            (pam / 'pearl').write_text(f'auth required {args.pam_module}\naccount required {args.pam_module}\n')
            s.env['PEARL_TEST_PAM_DIR'] = str(pam)
            s.args = SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous')
            T00Session.input_fixture(s)
            authority = s.child('authority', ['python3', ROOT / 'tests/fixtures/session_security.py'], input_pipe=True)
            authority.expect('event=ready')
            system_data = s.base / 'system-data'
            system_data.mkdir()
            s.env['XDG_DATA_DIRS'] = str(system_data)
            for i in range(2000):
                desktop(s, f'Catalog{i:04d}', f'Catalog Application {i:04d}', command='/usr/bin/true')
            desktop(s, 'Numeric', '12*(3+4)', command='/usr/bin/true')
            app = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings')
            app.expect('event=control-ready')
            app.expect('event=app-index-ready')
            app.expect('event=preferences-applied')
            ipc = IPC(s)
            outputs = status(s, args.ctl)['outputs']
            first, second = outputs[:2]

            def clip():
                return ctl(s, args.ctl, 'clipboard', 'status')['result']

            def until(fn, pred, timeout=12):
                last = None
                def check():
                    nonlocal last
                    last = fn()
                    return last if pred(last) else False
                try:
                    return wait_for(check, timeout)
                except TimeoutError as exc:
                    raise AssertionError(('condition timed out', last)) from exc

            def probe(suffix=''):
                return ctl(s, args.ctl, 'aqueous', 'status', '--text', 'test-launcher-calculator' + suffix)['result']

            def show(output=first):
                ctl(s, args.ctl, 'launcher', 'show', '--output', output['id'])
                until(probe, lambda v: v['fresh'] and not v['pending'])

            def type_query(text, settle=True):
                s.run(['wtype', '-M', 'ctrl', '-k', 'a', '-m', 'ctrl', '-k', 'BackSpace', '--', text])
                if settle:
                    return until(probe, lambda v: v['query'] == text and v['fresh'] and not v['pending'])

            def value(text, expected):
                v = type_query(text)
                assert v['rows'] and v['rows'][0]['kind'] == 'calculator', v
                assert v['rows'][0]['name'] == expected, v
                assert 'Enter' in v['rows'][0]['detail'], v
                return v

            def pasted(expected):
                result = s.run(['wl-paste', '--no-newline'], check=False)
                assert result.returncode == 0 and result.stdout == expected, (result.stdout, result.stderr, clip())

            def copy(text, expected):
                show()
                value(text, expected)
                keys(s, 'Return')
                until(lambda: status(s, args.ctl), lambda v: v['popup'] is None)
                pasted(expected)

            until(clip, lambda v: v['available'] and not v['locked'])
            show()
            v = value('12*(3+4)', '84')
            assert any(row['kind'] == 'app' for row in v['rows'][1:]), v
            until(probe, lambda v: v['rows'] and v['rows'][0]['accessible'])
            checks['native-accessible-result-label-and-copy-description'] = True
            capture(s, 'calculator-dark', first['connector'])
            keys(s, 'Return')
            until(lambda: status(s, args.ctl), lambda v: v['popup'] is None)
            pasted('84')
            checks['arithmetic-first-result-and-real-paste-after-dismissal'] = True
            copy('1+2', '3')
            copy('12*(3+4)', '84')
            assert sum(e['preview'] == '84' for e in clip()['entries']) == 1
            checks['copy-deduplicated-history-entry-not-most-recent-entry'] = True
            show()
            value('=9*9', '81')
            probe(':copy-unavailable')
            keys(s, 'Return')
            assert status(s, args.ctl)['popup'] is not None
            assert 'Could not copy' in probe()['message'], probe()
            pasted('84')
            probe(':copy-available')
            keys(s, 'Return')
            until(lambda: status(s, args.ctl), lambda v: v['popup'] is None)
            pasted('81')
            copy('12*(3+4)', '84')
            checks['unavailable-copy-preserves-selection-and-popup-for-retry'] = True

            show()
            for text in ('42', 'Catalog', '1password', '/tmp/file', '1+hello'):
                v = type_query(text)
                assert all(row['kind'] != 'calculator' for row in v['rows']), v
            for text, answer in (('=sqrt(81)', '9'), ('=cos(pi)', '-1'), ('=mod(-7,3)', '-1'), ('2^3^2', '512'), ('0.1+0.2', '0.3')):
                value(text, answer)
            for text in ('=1/0', '=sqrt(-1)', '=1,234', '=unknown(2)', '=20%', '=2(3)'):
                v = type_query(text)
                assert not v['rows'], v
                keys(s, 'Return')
                assert status(s, args.ctl)['popup'] is not None
                pasted('84')
            capture(s, 'calculator-error', first['connector'])
            assert not type_query('=sqrt(')['rows']
            capture(s, 'calculator-incomplete', first['connector'])
            checks['advanced-math-search-classification-and-nonactionable-errors'] = True

            type_query('12*7=', settle=False)
            v = until(probe, lambda v: v['query'] == '84' and v['fresh'] and not v['pending'])
            assert v['caret'] == 2, v
            s.run(['wtype', '--', '+6'])
            v = until(probe, lambda v: v['fresh'] and not v['pending'])
            assert v['rows'][0]['name'] == '90', v
            type_query('=sqrt(81)=', settle=False)
            v = until(probe, lambda v: v['query'] == '=9' and v['fresh'] and not v['pending'])
            assert v['rows'][0]['name'] == '9', v
            pasted('84')
            checks['trailing-equals-continues-without-copying-and-retains-explicit-mode'] = True

            # Slow workers expose pending-action and stale-result races deterministically.
            probe(':delay:300')
            type_query('=100+1', settle=False)
            s.run(['wtype', '-k', 'Return', '-M', 'ctrl', '-k', 'a', '-m', 'ctrl', '--', '=100+'])
            v = until(probe, lambda v: v['fresh'] and not v['pending'])
            assert not v['rows'] and v['query'] == '=100+', v
            pasted('84')
            type_query('=7*8', settle=False)
            s.run(['wtype', '-k', 'Return'])
            until(lambda: status(s, args.ctl), lambda v: v['popup'] is None)
            pasted('56')
            checks['enter-waits-for-current-query-and-edits-cancel-pending-copy'] = True
            show()
            probe(':delay:300')
            type_query('=5+6=', settle=False)
            s.run(['wtype', '-k', 'Left', '-k', 'Right'])
            v = until(probe, lambda v: v['fresh'] and not v['pending'])
            assert v['query'] == '=5+6=', v
            type_query('=8+9=', settle=False)
            s.run(['wtype', '-M', 'ctrl', '-k', 'a', '-m', 'ctrl', '--', '=8+'])
            v = until(probe, lambda v: v['fresh'] and not v['pending'])
            assert v['query'] == '=8+', v
            checks['caret-movement-and-edits-cancel-pending-continuation'] = True
            type_query('=5+6=', settle=False)
            assert probe(':preedit:start')['composing']
            v = until(probe, lambda v: v['fresh'] and not v['pending'])
            assert v['query'] == '=5+6=', v
            keys(s, 'Return')
            pasted('56')
            assert not probe(':preedit:end')['composing']
            assert probe()['query'] == '=5+6='
            checks['gtk-preedit-suppresses-copy-and-continuation'] = True
            probe(':delay:0')

            # Pointer activation uses the actual virtualized row allocation.
            v = value('=6*7', '42')
            until(probe, lambda v: v['rows'][0]['height'] > 0)
            v = probe()
            rect = ipc.outputs()[first['id']]['usable_bounds']
            row = v['rows'][0]
            click(s, rect['x'] + row['x'] + row['width'] / 2, rect['y'] + row['y'] + row['height'] / 2, ipc.outputs())
            until(lambda: status(s, args.ctl), lambda v: v['popup'] is None)
            pasted('42')
            checks['pointer-activation-copies-result'] = True
            producer = s.child('pasted-expression', [args.producer, 'text', '=sqrt(144)='])
            producer.expect('event=ready')
            until(clip, lambda v: any(e['preview'] == '=sqrt(144)=' for e in v['entries']))
            show()
            s.run(['wtype', '-M', 'ctrl', '-k', 'a', '-k', 'v', '-m', 'ctrl'])
            v = until(probe, lambda v: v['query'] == '=12' and v['fresh'] and not v['pending'])
            assert v['rows'][0]['name'] == '12', v
            checks['pasted-trailing-equals-uses-same-continuation-path'] = True
            producer.stop()
            ctl(s, args.ctl, 'launcher', 'hide')

            # Repeated disposal on alternating outputs saturates admitted jobs.
            for n in range(6):
                ctl(s, args.ctl, 'launcher', 'show', '--output', outputs[n % 2]['id'])
                probe(':delay:300')
                type_query('=17*19', settle=False)
                ctl(s, args.ctl, 'launcher', 'hide')
            show(second)
            value('=2+2', '4')
            assert probe()['searches'] <= 2
            checks['pending-job-disposal-and-two-output-admission-bound'] = True
            ctl(s, args.ctl, 'launcher', 'hide')

            def authority_command(**data):
                authority.proc.stdin.write(json.dumps(data) + '\n')
                authority.proc.stdin.flush()
                authority.expect('command=' + json.dumps(data, sort_keys=True))

            show()
            probe(':delay:300')
            type_query('=77+1', settle=False)
            s.run(['wtype', '-k', 'Return'])
            authority_command(begin=True)
            until(clip, lambda v: v['locked'])
            authority_command(cancel=True)
            until(clip, lambda v: not v['locked'] and v['available'])
            time.sleep(.4)
            assert not clip()['entries'], clip()
            checks['authentication-inhibition-cancels-copy-without-unlock-replay'] = True
            show()
            probe(':delay:300')
            type_query('=88+1', settle=False)
            s.run(['wtype', '-k', 'Return'])
            ctl(s, args.ctl, 'lock')
            until(clip, lambda v: v['locked'])
            until(lambda: ctl(s, args.ctl, 'lifecycle', 'status')['result'], lambda v: v['lock']['ready'] and v['lock']['locked'])
            s.run(['wtype', '-s', '200', 'fixture-user', '-k', 'Return', '-s', '300', 'fixture-secret', '-k', 'Return', '-s', '200'])
            until(clip, lambda v: not v['locked'] and v['available'])
            assert not clip()['entries'], clip()
            checks['lock-clears-selection-and-cancels-pending-copy'] = True

            # Catalog replacement cannot invalidate the calculator's payload.
            show()
            value('=21*2', '42')
            generation = status(s, args.ctl)['apps']['generation']
            added = desktop(s, 'AddedCalculatorTest', 'New test application', command='/usr/bin/true')
            until(lambda: status(s, args.ctl), lambda v: v['apps']['generation'] > generation)
            v = until(probe, lambda v: v['fresh'] and not v['pending'])
            assert v['rows'][0]['name'] == '42', v
            added.unlink()
            checks['catalog-refresh-preserves-calculation'] = True
            # Use output-power protocol: this pinned compositor has an unrelated
            # assertion in the wlr-output-management disable path.
            power_dir = s.runtime / 'output-power'
            power_dir.mkdir()
            protocol = Path('/home/zoey/RiderProjects/Aqueous/compositor/protocol/upstream/wlr-output-power-management-unstable-v1.xml')
            normalized = power_dir / 'protocol.xml'
            normalized.write_text(protocol.read_text().replace('<?xml version="1.0" encoding="UTF-8"?>', ''))
            s.run(['wayland-scanner', 'client-header', normalized, power_dir / 'output-power.h'])
            s.run(['wayland-scanner', 'private-code', normalized, power_dir / 'output-power.c'])
            s.run(['cc', '-I' + str(power_dir), ROOT / 'tests/fixtures/desktop/output_power.c', power_dir / 'output-power.c', '-lwayland-client', '-o', power_dir / 'output-power'])
            probe(':delay:300')
            type_query('=99+1', settle=False)
            s.run(['wtype', '-k', 'Return'])
            s.run([power_dir / 'output-power', first['connector'], 'off'])
            until(lambda: status(s, args.ctl), lambda v: v['popup'] is None)
            time.sleep(.4)
            assert not clip()['entries'], clip()
            s.run([power_dir / 'output-power', first['connector'], 'on'])
            until(lambda: status(s, args.ctl), lambda v: len(v['outputs']) == 2)
            checks['output-removal-cancels-pending-copy'] = True

            # Save real GTK captures for the existing theme and text-size paths.
            for mode in ('light', 'gtk', 'large'):
                prefs = until(lambda: ctl(s, args.ctl, 'preferences', 'status')['result'], lambda v: not v['busy'])
                settings = prefs['preferences']
                settings['theme']['mode'] = 'gtk' if mode == 'gtk' else 'static'
                settings['theme']['variant'] = 'light' if mode == 'light' else 'dark'
                settings['theme']['gtk_name'] = 'Adwaita'
                if mode == 'large':
                    settings['font_size'] = 20
                ctl(s, args.ctl, 'preferences', 'apply', '--revision', str(prefs['revision']), '--text', json.dumps(settings))
                until(lambda: ctl(s, args.ctl, 'preferences', 'status')['result'], lambda v: not v['busy'])
                show()
                value('=sqrt(81)', '9')
                capture(s, 'calculator-' + mode, first['connector'])
                ctl(s, args.ctl, 'launcher', 'hide')
            checks['material-light-native-gtk-and-larger-text'] = True
            # Measure painted results without the deliberate worker delay.
            show()
            times = []
            for n in range(12):
                value(f'={n}+100', str(n + 100))
                v = until(probe, lambda v: v['latency_us'] > 0)
                times.append(v['latency_us'])
            report['calculator_latency_us'] = {'samples': len(times), 'median': statistics.median(times), 'p95': sorted(times)[int(len(times)*.95)], 'maximum': max(times)}
            assert report['calculator_latency_us']['p95'] < 50000, times
            checks['calculator-paint-latency-under-50ms-with-2000-apps'] = True
            ctl(s, args.ctl, 'quit')
            clean(app)
            translated = s.child('pearl-german', [args.pearl], G_DEBUG='fatal-warnings', LANGUAGE='de')
            translated.expect('event=control-ready')
            translated.expect('event=preferences-applied')
            show()
            v = type_query('=sqrt(81)')
            assert v['rows'][0]['name'] == '9' and 'Eingabe' in v['rows'][0]['detail'], v
            capture(s, 'calculator-german', first['connector'])
            ctl(s, args.ctl, 'quit')
            clean(translated)
            checks['german-calculator-labels'] = True
            empty_data = s.base / 'empty-data'
            (empty_data / 'applications').mkdir(parents=True)
            empty = s.child('pearl-empty-catalog', [args.pearl], G_DEBUG='fatal-warnings', XDG_DATA_HOME=str(empty_data))
            empty.expect('event=control-ready')
            empty.expect('event=app-index-ready entries=0')
            empty.expect('event=preferences-applied')
            show()
            value('12*(3+4)', '84')
            keys(s, 'Return')
            until(lambda: status(s, args.ctl), lambda v: v['popup'] is None)
            pasted('84')
            checks['calculator-with-empty-application-catalog'] = True
            show()
            probe(':delay:500')
            type_query('=100+1', settle=False)
            s.run(['wtype', '-k', 'Return'])
            ipc.close()
            s.compositor.stop()
            exit_code = empty.wait()
            assert exit_code in (0, 1), (exit_code, empty.lines[-20:])
            assert not any('panic:' in line or 'CRITICAL' in line for line in empty.lines), empty.lines[-20:]
            checks['compositor-loss-during-pending-copy-exits-without-crashing'] = True
        report['status'] = 'passed'
    finally:
        (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
