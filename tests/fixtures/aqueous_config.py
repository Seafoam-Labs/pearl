#!/usr/bin/python3
"""Private T11 fault injection; never installed with Pearl."""
import json, os, pathlib, subprocess, sys, time
mode = pathlib.Path(os.environ['PEARL_AQUEOUS_FAULT_FILE']).read_text().strip()
args = sys.argv[1:]
with open(os.environ['PEARL_AQUEOUS_CALLS'], 'a') as log:
    log.write(json.dumps(args) + '\n')
assert '--shell' in args and args[args.index('--shell') + 1] == 'none'
if args[0] == 'apply' and mode == 'reject':
    print(json.dumps(dict(ok=False, protocol=1, code='fixture_rejected')))
    sys.exit(1)
if args[0] == 'apply' and mode == 'slow': time.sleep(.8)
if args[0] == 'apply' and mode == 'race':
    p = pathlib.Path(os.environ['AQUEOUS_CONFIG']); p.write_text(p.read_text() + '\n# competing edit during apply\n')
result = subprocess.run(['/usr/bin/aqueous-config', *args], stdin=sys.stdin.buffer, capture_output=True)
if args[0] == 'apply' and mode == 'lost':
    sys.stdout.write('{truncated after save')
else:
    sys.stdout.buffer.write(result.stdout)
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
