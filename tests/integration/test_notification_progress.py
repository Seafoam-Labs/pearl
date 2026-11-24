#!/usr/bin/env python3
"""Transfer progress hint: one live card, no toast pinning, final result re-toasts."""
import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for, fixture_prefix
from test_surfaces import ctl, status, capture, clean
from test_session_services import state, await_state, records, action, FIX, command, notified, record_with, invoked, closed


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pearl', type=Path, required=True)
    p.add_argument('--ctl', type=Path, required=True)
    p.add_argument('--output', type=Path, default=ROOT / 'artifacts/notification-progress')
    args = p.parse_args()
    args.pearl = args.pearl.resolve(); args.ctl = args.ctl.resolve(); args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    result = dict(status='running', checks=checks,
                  pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(),
                  ctl_sha256=hashlib.sha256(args.ctl.read_bytes()).hexdigest())
    try:
        with PrivateSession(args.output / 'session', tool_prefix=fixture_prefix()) as s:
            s.env['PEARL_TEST_SESSION_LOG'] = str(s.output / 'clients.jsonl')
            Path(s.env['PEARL_TEST_SESSION_LOG']).write_text('')
            fixture = s.child('clients', ['python3', FIX], input_pipe=True); fixture.expect('event=ready')
            pearl = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings'); pearl.expect('event=control-ready')
            await_state(s, args.ctl, lambda v: v['notifications']['available'])
            caps = s.run(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.Notifications',
                          '--object-path', '/org/freedesktop/Notifications',
                          '--method', 'org.freedesktop.Notifications.GetCapabilities']).stdout
            assert "'x-pearl-progress'" in caps, caps
            checks['progress-capability-advertised'] = True
            output = status(s, args.ctl)['outputs'][0]

            def progress(replaces, body, value):
                return notified(s, fixture, app='Phyto', replaces=replaces, summary='Copying 12 items',
                                body=body, progress=value, resident=True, timeout=0,
                                actions=['cancel', 'Cancel', 'default', ' '])

            # A persistent indeterminate progress record toasts once.
            id = progress(0, 'Starting…', -1.0)
            rec = record_with(s, args.ctl, id)
            assert rec['progress'] == -1.0 and rec['toast'] and rec['active'], rec
            wait_for(lambda: status(s, args.ctl)['notification'])
            ctl(s, args.ctl, 'notifications', 'toggle', '--output', output['id']); time.sleep(.4)
            capture(s, 'progress-indeterminate', output['connector'])
            # Determinate updates replace the same card.
            assert progress(id, '45.2 MB · item 3 of 12', 0.25) == id
            rec = record_with(s, args.ctl, id)
            assert rec['progress'] == 0.25 and rec['active'], rec
            capture(s, 'progress-determinate', output['connector'])
            checks['progress-replacement-updates-one-card'] = True
            # The original 8s toast expires on schedule while updates continue.
            deadline = time.monotonic() + 9
            while time.monotonic() < deadline:
                assert progress(id, 'More bytes…', 0.6) == id
                time.sleep(1)
            rec = record_with(s, args.ctl, id)
            assert rec['active'] and rec['progress'] == 0.6 and not rec['toast'], rec
            checks['progress-updates-do-not-pin-the-toast'] = True
            # Invalid hint values are ignored, never fatal, on their own records.
            for bad in (2.0, -2.0, float('inf'), float('nan')):
                bid = notified(s, fixture, app='Phyto', summary='Bad hint', progress=bad, timeout=0)
                assert record_with(s, args.ctl, bid)['progress'] is None, bad
                command(fixture, close=bid)
            checks['invalid-progress-hints-are-ignored'] = True
            # The cancel action reaches the sender; resident keeps the card.
            action(s, args.ctl, 'invoke', notification=id, text='cancel')
            wait_for(lambda: invoked(s, id, 'cancel'))
            assert record_with(s, args.ctl, id)['active']
            checks['cancel-action-invokes-and-resident-card-survives'] = True
            # The final result clears the bar and toasts again.
            assert notified(s, fixture, app='Phyto', replaces=id, summary='Copy complete',
                            body='12 completed · 0 skipped', timeout=-1, actions=['default', ' ']) == id
            rec = record_with(s, args.ctl, id)
            assert rec['progress'] is None and rec['toast'], rec
            capture(s, 'progress-final', output['connector'])
            checks['final-result-clears-progress-and-re-toasts'] = True
            action(s, args.ctl, 'dismiss', notification=id); wait_for(lambda: closed(s, id, 2))
            checks['dismissal-closes-the-result'] = True
            ctl(s, args.ctl, 'quit'); clean(pearl); checks['clean-shutdown'] = True
        result['status'] = 'passed'
    finally:
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
