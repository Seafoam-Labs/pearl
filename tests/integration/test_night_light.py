#!/usr/bin/env python3
"""Night Light configuration and truthful unavailable state on private Aqueous."""
import argparse
import copy
import hashlib
import json
import shlex
import shutil
import subprocess
import time
import uuid
from pathlib import Path
from types import SimpleNamespace
from test_surfaces import ROOT, PrivateSession, IPC, ctl, status, wait_for, clean, capture
from settings_editor import EditorPeer


def probe_contract(s):
    build = s.base / 'gamma-probe'
    build.mkdir()
    xml = ROOT / 'bindings/protocols/wlr-gamma-control-unstable-v1.xml'
    for mode, destination in [('client-header', 'night-gamma.h'), ('private-code', 'night-gamma.c')]:
        subprocess.run(['wayland-scanner', mode, xml, build / destination], check=True)
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True))
    executable = build / 'probe'
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(build), ROOT / 'tests/fixtures/night_light_probe.c', build / 'night-gamma.c', '-o', executable, *flags], check=True)
    return json.loads(s.run([executable]).stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('pearl', 'ctl', 'settings', 'spike'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/night-light/latest')
    args = parser.parse_args()
    for name in ('pearl', 'ctl', 'settings', 'spike', 'output'):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    report = dict(status='running', checks=checks, physical_color_validation='pending', output_writes='blocked: OutputColorEligibilityUnavailable')
    report['binaries'] = {name: hashlib.sha256(getattr(args, name).read_bytes()).hexdigest() for name in ('pearl', 'ctl', 'settings')}
    def passed(name):
        checks[name] = True
        print('PASS', name, flush=True)
    try:
        with PrivateSession(args.output / 'session', tool_prefix=ROOT / '.cache/aqueous-activity-production') as s:
            from t00 import Session as T00Session
            s.args = SimpleNamespace(aqueous_source=str(ROOT / '.cache/aqueous-activity-production/source'))
            T00Session.input_fixture(s)
            report['gamma_probe'] = probe_contract(s)
            assert report['gamma_probe']['protocol'], report
            # Pinned pixman/headless has no hardware LUT and no fallback size.
            assert report['gamma_probe']['failed'] and not report['gamma_probe']['identity_uploaded'], report
            passed('advertised-gamma-does-not-imply-output-support')
            s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path=' + str(s.runtime / 'system-bus')
            s.child('system-bus', ['dbus-daemon', '--session', '--nofork', '--address=' + s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda: s.run(['busctl', '--address=' + s.env['DBUS_SYSTEM_BUS_ADDRESS'], 'list'], check=False).returncode == 0)
            s.env['PEARL_TEST_BACKLIGHT'] = str(s.base / 'backlight')
            Path(s.env['PEARL_TEST_BACKLIGHT']).mkdir()
            s.env['PEARL_TEST_POWER_LOG'] = str(s.output / 'power.jsonl')
            power = s.child('power', ['python3', ROOT / 'tests/fixtures/services/power.py'], input_pipe=True)
            power.expect('event=ready')
            staged = s.base / 'bin'
            staged.mkdir()
            shutil.copy2(args.pearl, staged / 'pearl')
            shutil.copy2(args.settings, staged / 'pearl-settings')
            args.pearl, args.settings = staged / 'pearl', staged / 'pearl-settings'
            shell = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings', WAYLAND_DEBUG='client', log_limit=150000)
            shell.expect('event=control-ready')
            ipc = IPC(s)
            output = next(iter(ipc.outputs().values()))
            s.run(['wlr-randr', '--output', output['name'], '--custom-mode', '1600x1100@60Hz'])
            rules = Path(s.env['XDG_CONFIG_HOME']) / 'aqueous/rules.toml'
            rules.write_text('[[window]]\napp_id="org.aqueous.Pearl.Settings"\nfloating=true\nwidth=1040\nheight=850\n')
            ipc.call('command', action='session.reload', fields={})
            wait_for(lambda: ctl(s, args.ctl, 'services', 'status')['result']['power']['session_active'])
            def night():
                return ctl(s, args.ctl, 'night-light', 'status')['result']
            wait_for(lambda: night()['gamma_protocol'])
            initial = night()
            assert initial['state'] == 'off' and initial['requested'] is False and initial['available'] is False
            assert initial['outputs'] and all(not o['available'] for o in initial['outputs'])
            before = initial['generation']
            for action in ('on', 'toggle', 'retry'):
                reply = ctl(s, args.ctl, 'night-light', action, code=4)
                assert reply['err']['code'] == 'OutputColorEligibilityUnavailable', reply
                assert night()['generation'] == before and night()['override'] is None
            passed('unavailable-actions-fail-without-retaining-an-override')
            first, second = EditorPeer(s, ipc), EditorPeer(s, ipc)
            original = json.loads(first.document('committed'))
            candidate = copy.deepcopy(original)
            candidate['night_light'] = dict(enabled=True, temperature_kelvin=4000, schedule='manual', start_minute=1200, end_minute=420)
            first.keep(json.dumps(candidate))
            assert json.loads(second.document())['night_light'] == candidate['night_light']
            assert not night()['requested']
            assert first.action('apply')['state'] == 'succeeded'
            wait_for(lambda: night()['requested'] and night()['temperature_kelvin'] == 4000)
            assert night()['state'] == 'unavailable' and night()['available'] is False
            path = Path(s.env['XDG_CONFIG_HOME']) / 'pearl/preferences.json'
            saved = path.read_bytes()
            assert json.loads(saved)['night_light'] == candidate['night_light']
            passed('shared-draft-applies-only-on-save-with-truthful-output-state')
            off = ctl(s, args.ctl, 'night-light', 'off')['result']
            assert off['override'] == dict(enabled=False, expires=None)
            wait_for(lambda: second.state()['night_light']['override'] is not None)
            assert path.read_bytes() == saved
            generation = night()['generation']
            stale = first.call('night-light.action', view=first.view, operation=uuid.uuid4().hex, generation='0', action='resume')
            assert stale['ok'] and stale['result']['state'] == 'failed', stale
            assert night()['generation'] == generation
            nonce = uuid.uuid4().hex
            resumed = first.call('night-light.action', view=first.view, operation=nonce, generation=generation, action='resume')
            assert resumed['ok'] and resumed['result']['state'] == 'succeeded', resumed
            duplicate = first.call('night-light.action', view=first.view, operation=nonce, generation=generation, action='resume')
            assert duplicate['result'] == resumed['result'], duplicate
            wait_for(lambda: night()['override'] is None and night()['requested'])
            passed('frontend-generation-checks-operation-deduplication-and-runtime-only-overrides')
            ctl(s, args.ctl, 'night-light', 'off')
            candidate['font_size'] = 15
            first.keep(json.dumps(candidate))
            assert first.action('apply')['state'] == 'succeeded'
            assert night()['override'] is not None
            candidate['night_light']['temperature_kelvin'] = 4100
            first.keep(json.dumps(candidate))
            assert first.action('apply')['state'] == 'succeeded'
            wait_for(lambda: night()['override'] is None and night()['temperature_kelvin'] == 4100)
            passed('unrelated-saves-preserve-override-night-light-saves-clear-it')
            invalid = copy.deepcopy(candidate)
            invalid['night_light']['temperature_kelvin'] = 1000
            first.keep(json.dumps(invalid))
            assert not first.state()['valid']
            assert json.loads(path.read_bytes())['night_light']['temperature_kelvin'] == 4100
            first.action('discard')
            passed('invalid-temperature-retains-working-configuration')
            # Real GTK surfaces exercise the new widgets and native callback lifetimes.
            app = s.child('settings', [args.settings, '--page', 'appearance'], G_DEBUG='fatal-warnings')
            app.expect('event=settings-window-created')
            from test_settings_appearance import ready, click, type_text
            ready(s, ipc)
            click(s, ipc, 'night_temperature')
            type_text(s, '4300')
            s.run(['wtype', '-k', 'Tab'])
            wait_for(lambda: json.loads(first.document())['night_light']['temperature_kelvin'] == 4300)
            assert night()['temperature_kelvin'] == 4100
            capture(s, 'appearance-night-light-draft', initial['outputs'][0]['connector'])
            first.action('discard')
            passed('native-temperature-edit-retains-draft-without-changing-saved-policy')
            from test_settings_app import request, probe, keys
            request(s, ipc, page='power')
            wait_for(lambda: probe(s, ipc)['page'] == 'power')
            ctl(s, args.ctl, 'control-center', 'show')
            time.sleep(.4)
            capture(s, 'control-center-unavailable', initial['outputs'][0]['connector'])
            from settings_navigation import report as compact_report
            for _ in range(40):
                if compact_report(s, args.ctl)['button'] == 'Night Light settings':
                    break
                s.run(['wtype', '-s', '50', '-k', 'Tab', '-s', '50'])
            else:
                raise AssertionError('Night Light settings is not keyboard reachable')
            keys(s, 'Return')
            try:
                wait_for(lambda: probe(s, ipc)['page'] == 'appearance')
            except Exception:
                print('handoff failure', compact_report(s, args.ctl), flush=True)
                raise
            passed('keyboard-handoff-opens-appearance-from-night-light')
            passed('settings-and-compact-controls-create-with-fatal-gtk-warnings')
            locker = s.child('locker', [args.spike], input_pipe=True, PEARL_T00_ISOLATED='1', WLR_BACKENDS='headless', PEARL_T00_MODE='plain')
            locker.expect('T00 event=ready')
            locker.proc.stdin.write('lock\n'); locker.proc.stdin.flush(); locker.expect('T00 event=locked')
            reply = ctl(s, args.ctl, 'night-light', 'off', code=4)
            assert reply['err']['code'] == 'Locked', reply
            assert night()['requested']
            locked = first.call('night-light.action', view=first.view, operation=uuid.uuid4().hex, generation=night()['generation'], action='off')
            assert not locked['ok'], locked
            locker.proc.stdin.write('unlock\n'); locker.proc.stdin.flush(); locker.expect('T00 event=unlocked')
            locker.proc.stdin.write('quit\n'); locker.proc.stdin.flush(); clean(locker)
            passed('lock-rejects-interactive-mutations-and-preserves-saved-policy')
            app.stop()
            first.close(); second.close()
            ctl(s, args.ctl, 'night-light', 'off')
            ctl(s, args.ctl, 'quit'); clean(shell)
            shell = s.child('pearl-restarted', [args.pearl], G_DEBUG='fatal-warnings', WAYLAND_DEBUG='client', log_limit=100000)
            shell.expect('event=control-ready')
            wait_for(lambda: night()['requested'])
            assert night()['override'] is None and night()['temperature_kelvin'] == 4100
            passed('restart-restores-saved-policy-and-clears-temporary-overrides')
            report['final'] = night()
            ctl(s, args.ctl, 'quit'); clean(shell)
            for logfile in ('pearl.log', 'pearl-restarted.log'):
                assert 'get_gamma_control(' not in (s.output / logfile).read_text()
            passed('unverified-output-path-never-acquires-exclusive-gamma-control')
        report['status'] = 'passed'
    finally:
        (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
