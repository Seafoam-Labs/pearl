#!/usr/bin/python3
"""Isolated command fixture; never contacts D-Bus or launches schedulers."""
import json
import sys
import time
from pathlib import Path
root = Path(__file__).resolve().parent.parent
assert (root / 'fixture-marker').is_file(), 'Private fixture marker required'
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\n')
control = json.loads((root / 'control.json').read_text())
state_path = root / 'state.json'
state = json.loads(state_path.read_text())
if control.get('offline'):
    sys.exit('AccessDenied: private loader unavailable')
if control.get('timeout'):
    time.sleep(8)
if args == ['config', '--json']:
    print('{' if control.get('malformed') else (root / 'config.json').read_text())
elif args == ['get']:
    if control.get('unknown'):
        print('unrecognized status')
    elif state is None:
        print('no scx scheduler running')
    elif state.get('custom'):
        print(f'running {state["scheduler"][4:].capitalize()} with arguments "--custom value"')
    elif state.get('defaults'):
        print(f'running {state["scheduler"][4:].capitalize()} with its own defaults')
    else:
        print(f'running {state["scheduler"][4:].capitalize()} in {state["mode"].capitalize()} mode')
elif args and args[0] in ('start', 'switch', 'stop'):
    time.sleep(control.get('delay', .25))
    if control.get('fail'):
        # Model a failed switch that also loses the previous scheduler.
        state_path.write_text('null')
        (root / 'kernel-state').write_text('disabled\n')
        sys.exit('Scheduler failed to attach')
    if args[0] == 'stop':
        assert len(args) == 1
        state = None
    else:
        assert len(args) == 5 and args[1] == '--sched' and args[3] == '--mode', args
        assert (state is None) == (args[0] == 'start'), (state, args)
        assert (root / 'bin' / args[2]).is_file()
        configured = json.loads((root / 'config.json').read_text())['scheds'][args[2]][args[4] + '_mode']
        state = dict(scheduler=args[2], mode=args[4], defaults=not configured)
    if not control.get('no_effect'):
        state_path.write_text(json.dumps(state))
        (root / 'kernel-state').write_text('enabled\n' if state else 'disabled\n')
    print('accepted')
else:
    sys.exit('Unsupported fixture command: ' + repr(args))
