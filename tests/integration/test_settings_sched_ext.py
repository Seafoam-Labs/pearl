#!/usr/bin/env python3
"""Real Settings and backend, exclusively using a private fake scxctl."""
import argparse
import json
import shutil
import time
import uuid
from pathlib import Path
from test_settings_app import *
from test_settings_appearance import click, ready
from test_settings_services import Peer, navigate

FIX = ROOT / 'tests/fixtures/scxctl'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('settings', 'pearl', 'ctl', 'spike'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/sched-ext')
    args = parser.parse_args()
    for name in ('settings', 'pearl', 'ctl', 'spike', 'output'):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    report = dict(status='running', checks=checks)
    try:
      with PrivateSession(args.output / 'session', tool_prefix=ROOT / '.cache/aqueous-activity-production') as s:
        s.env['GSETTINGS_BACKEND'] = 'memory'
        root = s.output / 'scx-fixture'
        (root / 'bin').mkdir(parents=True, exist_ok=True)
        (root / 'fixture-marker').touch()
        shutil.copyfile(FIX / 'config.json', root / 'config.json')
        shutil.copyfile(FIX / 'scxctl.py', root / 'bin/scxctl')
        (root / 'bin/scxctl').chmod(0o755)
        for name in ('scx_bpfland', 'scx_lavd'):
            (root / 'bin' / name).write_text('#!/bin/sh\nexit 97\n')
            (root / 'bin' / name).chmod(0o755)
        (root / 'state.json').write_text('null')
        (root / 'kernel-state').write_text('disabled\n')
        (root / 'control.json').write_text('{}')
        (root / 'calls.jsonl').write_text('')
        s.env['PEARL_TEST_SCX_ROOT'] = str(root)
        # Also isolate the system bus; the fake CLI never uses it.
        s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path=' + str(s.runtime / 'no-system-bus')
        ipc = IPC(s)
        wm = Path(s.env['AQUEOUS_CONFIG'])
        wm.write_text(wm.read_text().replace('"floating"', '"stacking"'))
        output = next(iter(ipc.outputs().values()))
        s.run(['wlr-randr', '--output', output['name'], '--custom-mode', '1600x1100@60Hz'])
        rules = Path(s.env['XDG_CONFIG_HOME']) / 'aqueous/rules.toml'
        rules.write_text('[[window]]\napp_id="' + APP_ID + '"\nfloating=true\nwidth=1040\nheight=950\n')
        ipc.call('command', action='session.reload', fields={})
        shell = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings')
        shell.expect('event=control-ready')
        # Installed GTK can report compositor frame-timing warnings on dropdowns.
        # Keep criticals fatal and reject every warning except those exact diagnostics.
        app = s.child('settings', [args.settings, '--page', 'system'], G_DEBUG='fatal-criticals')
        app.expect('event=settings-window-created')
        peer = Peer(s, ipc)
        peer.enter('system')
        ready(s, ipc)

        def state(): return peer.page()['live']['sched_ext']
        def settled(): return wait_for(lambda: (v if not (v := state())['pending'] else False), 20)
        def control(**value): (root / 'control.json').write_text(json.dumps(value))
        def calls(): return [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
        def mutations(): return [argv for argv in calls() if argv[0] in ('start', 'switch', 'stop')]
        def receipt(operation):
            return wait_for(lambda: (v['result'] if (v := peer.call('operation.get', operation=operation))['result']['state'] != 'pending' else False), 20)
        def action(which, wait=True, **extra):
            snapshot = settled()
            operation = uuid.uuid4().hex
            reply = peer.call('sched-ext.action', view=peer.view, operation=operation, generation=snapshot['generation'], action=which, **extra)
            assert reply['ok'], reply
            return receipt(operation) if wait else (operation, reply)
        def refresh(): action('refresh'); return settled()
        def enabled(field): return next(c['enabled'] for c in probe(s, ipc)['controls'] if c['field'] == 'sched-ext/' + field)

        initial = settled()
        assert initial['available'] and initial['status']['kind'] == 'stopped', initial
        assert [v['name'] for v in initial['catalog']['schedulers'] if v['installed']] == ['scx_bpfland', 'scx_lavd']
        wait_for(lambda: enabled('apply'))
        assert mutations() == []
        prior_generation = initial['generation']
        click(s, ipc, 'sched-ext/refresh')
        wait_for(lambda: state()['generation'] != prior_generation and not state()['pending'])
        assert probe(s, ipc)['editor']['error_code'] == ''
        capture(s, 'system-ready', output['name'])
        checks['catalog-and-executable-detection'] = True

        click(s, ipc, 'sched-ext/scheduler'); keys(s, 'End', 'Return')
        wait_for(lambda: probe(s, ipc)['sched_ext']['scheduler'] == 'scx_lavd')
        click(s, ipc, 'sched-ext/mode'); keys(s, 'End', 'Return')
        wait_for(lambda: probe(s, ipc)['sched_ext']['mode'] == 'powersave')
        assert mutations() == [], mutations()
        time.sleep(3.3)
        assert probe(s, ipc)['sched_ext']['scheduler'] == 'scx_lavd'
        assert probe(s, ipc)['sched_ext']['mode'] == 'powersave'
        click(s, ipc, 'sched-ext/apply')
        wait_for(lambda: state()['status'].get('scheduler') == 'scx_lavd' and not state()['pending'])
        assert mutations() == [['start', '--sched', 'scx_lavd', '--mode', 'powersave']], mutations()
        wait_for(lambda: enabled('stop') and not enabled('apply'))
        checks['native-staging-poll-preservation-and-apply'] = True

        result = action('apply', scheduler='scx_bpfland', mode='gaming')
        assert result['state'] == 'succeeded', result
        assert mutations()[-1] == ['switch', '--sched', 'scx_bpfland', '--mode', 'gaming']
        result = action('apply', scheduler='scx_bpfland', mode='powersave')
        assert result['state'] == 'succeeded', result
        assert settled()['status']['mode'] is None
        checks['switch-and-empty-mode-defaults'] = True

        before = len(mutations())
        result = action('apply', scheduler='scx_missing', mode='auto')
        assert result['state'] == 'failed' and len(mutations()) == before, result
        result = action('apply', scheduler='scx_lavd', mode='server')
        assert result['state'] == 'failed' and len(mutations()) == before, result
        old = settled()['generation']; refresh()
        reply = peer.call('sched-ext.action', view=peer.view, operation=uuid.uuid4().hex, generation=old, action='stop')
        assert reply['result']['state'] == 'failed', reply
        checks['missing-binary-mode-and-stale-generation-denied'] = True

        # Changing configured arguments after selection must reject before a write.
        config = json.loads((root / 'config.json').read_text())
        config['scheds']['scx_bpfland']['gaming_mode'] = ['--changed']
        (root / 'config.json').write_text(json.dumps(config))
        result = action('apply', scheduler='scx_bpfland', mode='gaming')
        assert result['state'] == 'failed' and len(mutations()) == before, result
        assert 'ConfigurationChanged' in settled()['summary']
        shutil.copyfile(FIX / 'config.json', root / 'config.json'); refresh()
        checks['configuration-revalidation-before-dispatch'] = True

        control(delay=1)
        operation, _ = action('apply', wait=False, scheduler='scx_lavd', mode='gaming')
        other = Peer(s, ipc); other.enter('system')
        snapshot = state()
        denied = other.call('sched-ext.action', view=other.view, operation=uuid.uuid4().hex, generation=snapshot['generation'], action='stop')
        assert denied['result']['state'] == 'failed', denied
        assert receipt(operation)['state'] == 'succeeded'
        other.enter('sound')
        denied = other.call('sched-ext.action', view=other.view, operation=uuid.uuid4().hex, generation=settled()['generation'], action='stop')
        assert denied['result']['state'] == 'failed', denied
        other.close(); control()
        checks['serialized-mutations-and-route-ownership'] = True

        # Reject a stop if another client has changed runtime state since the snapshot.
        snapshot = settled()
        before_race = len(mutations())
        (root / 'state.json').write_text(json.dumps(dict(scheduler='scx_bpfland', mode='server')))
        operation = uuid.uuid4().hex
        reply = peer.call('sched-ext.action', view=peer.view, operation=operation, generation=snapshot['generation'], action='stop')
        assert reply['ok'] and receipt(operation)['state'] == 'failed', reply
        assert len(mutations()) == before_race
        assert settled()['status']['scheduler'] == 'scx_bpfland'
        checks['external-change-before-stop-is-not-overwritten'] = True

        control(fail=True)
        result = action('apply', scheduler='scx_bpfland', mode='auto')
        assert result['state'] == 'failed' and settled()['status']['kind'] == 'stopped', result
        assert 'Scheduler failed to attach' in settled()['summary']
        control(no_effect=True)
        result = action('apply', scheduler='scx_lavd', mode='auto')
        assert result['state'] == 'failed' and 'OutcomeUnconfirmed' in settled()['summary'], result
        checks['failed-switch-and-success-without-attachment'] = True

        for flag in ('offline', 'malformed', 'unknown', 'timeout'):
            control(**{flag: True})
            snapshot = refresh()
            assert not snapshot['available'], (flag, snapshot)
            wait_for(lambda: not enabled('apply'))
        control(); assert refresh()['available']
        (root / 'kernel-state').write_text('enabled\n')
        assert not refresh()['available']
        (root / 'kernel-state').unlink()
        assert not refresh()['available']
        (root / 'kernel-state').write_text('disabled\n')
        (root / 'bin/scxctl').rename(root / 'bin/scxctl.off')
        assert 'ScxctlMissing' in refresh()['summary']
        capture(s, 'system-unavailable', output['name'])
        (root / 'bin/scxctl.off').rename(root / 'bin/scxctl')
        for name in ('scx_bpfland', 'scx_lavd'): (root / 'bin' / name).chmod(0o644)
        assert not refresh()['available']
        for name in ('scx_bpfland', 'scx_lavd'): (root / 'bin' / name).chmod(0o755)
        assert refresh()['available']
        checks['unavailable-states-timeout-and-recovery'] = True

        assert action('apply', scheduler='scx_bpfland', mode='auto')['state'] == 'succeeded'
        wait_for(lambda: enabled('stop'))
        click(s, ipc, 'sched-ext/stop')
        try:
            wait_for(lambda: state()['status']['kind'] == 'stopped' and not state()['pending'])
        except Exception:
            (args.output / 'stop-diagnostic.json').write_text(json.dumps(dict(probe=probe(s, ipc), state=state(), calls=calls()[-15:]), indent=2))
            capture(s, 'stop-diagnostic', output['name'])
            raise
        assert mutations()[-1] == ['stop']
        assert action('apply', scheduler='scx_lavd', mode='auto')['state'] == 'succeeded'
        capture(s, 'system-running', output['name'])
        rules.write_text('[[window]]\napp_id="' + APP_ID + '"\nfloating=true\nwidth=480\nheight=760\n')
        ipc.call('command', action='session.reload', fields={})
        # Match presentation tests: create a fresh window at the narrow placement,
        # avoiding the prior wide page's cached GTK minimum-size hint.
        app.stop(); clean(app, allowed_warnings=('gdk_frame_timings_discarded() called on already presented frame', 'gdk_frame_timings_throttling_hint: runtime check failed'))
        app = s.child('settings-narrow', [args.settings, '--page', 'system'], G_DEBUG='fatal-criticals')
        app.expect('event=settings-window-created'); ready(s, ipc)
        try:
            wait_for(lambda: probe(s, ipc)['width'] == 480)
        except Exception:
            (args.output / 'narrow-diagnostic.json').write_text(json.dumps(probe(s, ipc), indent=2))
            capture(s, 'narrow-diagnostic', output['name'])
            raise
        capture(s, 'system-narrow', output['name'])
        checks['native-stop-and-narrow-layout'] = True

        locker = s.child('locker', [args.spike], input_pipe=True, PEARL_T00_ISOLATED='1', WLR_BACKENDS='headless', PEARL_T00_MODE='plain')
        locker.expect('T00 event=ready')
        locker.proc.stdin.write('lock\n'); locker.proc.stdin.flush(); locker.expect('T00 event=locked')
        wait_for(lambda: not probe(s, ipc)['visible'])
        denied = peer.call('sched-ext.action', view=peer.view, operation=uuid.uuid4().hex, generation=state()['generation'] if peer.page().get('live') else '0', action='stop')
        assert not denied['ok'] and denied['err']['code'] == 'Locked', denied
        locker.proc.stdin.write('unlock\n'); locker.proc.stdin.flush(); locker.expect('T00 event=unlocked')
        time.sleep(.3)
        assert not probe(s, ipc)['visible']
        navigate(s, ipc, 'system'); ready(s, ipc); peer.enter('system'); settled()
        locker.proc.stdin.write('quit\n'); locker.proc.stdin.flush(); clean(locker)
        checks['lock-revokes-authority-without-stopping-scheduler'] = True
        before = len(mutations())
        peer.enter('sound'); navigate(s, ipc, 'sound'); ready(s, ipc)
        time.sleep(3.5)
        assert len(mutations()) == before
        assert json.loads((root / 'state.json').read_text())['scheduler'] == 'scx_lavd'
        call_count = len(calls()); time.sleep(3.5); assert len(calls()) == call_count
        checks['page-release-stops-polling-without-stopping-scheduler'] = True
        # A departing owner cancels its helper without stopping established state.
        peer.enter('system'); settled(); control(delay=2)
        prior = len(mutations())
        operation, _ = action('apply', wait=False, scheduler='scx_bpfland', mode='gaming')
        wait_for(lambda: len(mutations()) > prior)
        peer.close()
        time.sleep(2.3)
        assert json.loads((root / 'state.json').read_text())['scheduler'] == 'scx_lavd'
        checks['pending-owner-release-cancels-only-owned-work'] = True
        app.stop(); clean(app, allowed_warnings=('gdk_frame_timings_discarded() called on already presented frame', 'gdk_frame_timings_throttling_hint: runtime check failed')); shell.stop(); clean(shell)
      report['status'] = 'passed'
    except Exception as exc:
        report.update(status='failed', error=repr(exc)); raise
    finally:
        (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))

if __name__ == '__main__': main()
