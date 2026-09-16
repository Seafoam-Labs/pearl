#!/usr/bin/env python3
"""Run the complete compact-settings acceptance suite in private sessions."""
import argparse, hashlib, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('pearl', 'production-pearl', 'ctl', 'spike'):
        p.add_argument('--'+name, type=Path, required=True)
    p.add_argument('--output', type=Path, default=ROOT/'artifacts/settings-navigation/f5')
    args = p.parse_args()
    for name in ('pearl', 'production_pearl', 'ctl', 'spike', 'output'):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    suites = [
        ('pages', 'test_settings_pages.py', args.pearl, [], 'results.json'),
        ('lifecycle', 'test_settings_lifecycle.py', args.pearl, ['--spike', args.spike], 'results.json'),
        ('accessibility', 'test_settings_accessibility.py', args.pearl, ['--full-matrix'], 'results.json'),
        ('desktop', 'test_desktop.py', args.production_pearl, [], 'results.json'),
        ('surfaces', 'test_surfaces.py', args.production_pearl, ['--spike', args.spike], 'results.json'),
        ('services', 'test_services.py', args.pearl, [], 'results.json'),
        ('connectivity', 'test_connectivity.py', args.pearl, [], 'result.json'),
        ('session-services', 'test_session_services.py', args.pearl, ['--production-pearl', args.production_pearl, '--spike', args.spike], 'result.json'),
    ]
    result = dict(status='running', suites={}, binaries={name:hashlib.sha256(getattr(args,name).read_bytes()).hexdigest() for name in ('pearl','production_pearl','ctl','spike')}, bar_keyboard_policy='none: user-approved', handoff='covered by test-settings-integration', concurrent_frontend='real frontend covered by test-settings-services; owner fixtures here')
    try:
        for name, script, binary, extra, filename in suites:
            print('Settings acceptance: '+name, flush=True)
            out = args.output/name
            command = [sys.executable, ROOT/'tests/integration'/script, '--pearl', binary, '--ctl', args.ctl, '--output', out, *extra]
            with (args.output/(name+'.log')).open('w') as log:
                completed = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            if completed.returncode:
                print((args.output/(name+'.log')).read_text(), file=sys.stderr)
                raise RuntimeError(name+' failed; see '+str(args.output/(name+'.log')))
            receipt = json.loads((out/filename).read_text())
            assert receipt['status'] == 'passed', receipt
            result['suites'][name] = dict(status='passed', evidence=name+'/'+filename)
        result['status'] = 'passed'
    except Exception as error:
        result.update(status='failed', error=str(error)); raise
    finally:
        (args.output/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))

if __name__ == '__main__': main()
