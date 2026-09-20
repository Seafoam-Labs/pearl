#!/usr/bin/env python3
"""Measure native lifecycle/RSS/fd/CPU behavior in an isolated display session."""
import argparse
import hashlib
import json
import os
import platform
import sys
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
PEARL = PROJECT.parents[1]
sys.path[:0] = [str(PEARL / 'scripts'), str(PEARL / 'tests/integration')]
from pearl_session import PrivateSession, wait_for
from test_surfaces import IPC


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--seconds', type=int, default=1800)
    parser.add_argument('--output', type=Path, default=PROJECT / 'artifacts/soak')
    parser.add_argument('--aqueous-prefix', type=Path, default=PEARL / '.cache/aqueous-activity-production')
    args = parser.parse_args()
    binary = args.binary.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {'status': 'running', 'kernel': platform.release(),
              'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'requested_seconds': args.seconds, 'samples': []}
    try:
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env['GSETTINGS_BACKEND'] = 'memory'
            ipc = IPC(session)
            started = time.monotonic()
            app = session.child('dome-soak', [binary, '--dark', '--page=0'], G_DEBUG='fatal-warnings')
            win = wait_for(lambda: next((w for w in ipc.state() if w.get('app_id') == 'org.aqueous.Dome'), None))
            report['window_mapped_seconds'] = time.monotonic() - started
            ipc.call('command', action='window.activate', fields={'id': win['id']})
            previous_ticks = None
            previous_time = None
            while time.monotonic() - started < args.seconds:
                assert app.proc.poll() is None, app.lines[-30:]
                root = Path('/proc') / str(app.proc.pid)
                stat = (root / 'stat').read_text().rsplit(')', 1)[1].split()
                ticks = int(stat[11]) + int(stat[12])
                status = dict(line.split(':', 1) for line in (root / 'status').read_text().splitlines())
                now = time.monotonic()
                item = {'seconds': round(now - started, 2), 'rss_kib': int(status['VmRSS'].split()[0]),
                        'fds': len(list((root / 'fd').iterdir())), 'threads': int(status['Threads']),
                        'cpu_one_core_percent': None if previous_ticks is None else
                        round((ticks - previous_ticks) / os.sysconf('SC_CLK_TCK') / (now - previous_time) * 100, 3)}
                report['samples'].append(item)
                previous_ticks, previous_time = ticks, now
                # Exercise all pages and allocation/destruction paths repeatedly.
                page = len(report['samples']) % 9 + 1
                session.run(['wtype', '-M', 'alt', '-k', str(page), '-m', 'alt'])
                (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
                print(json.dumps(item), flush=True)
                time.sleep(min(15, max(0, args.seconds - (time.monotonic() - started))))
            session.run(['wtype', '-M', 'ctrl', '-k', 'w', '-m', 'ctrl'])
            assert app.wait(timeout=8) == 0, app.lines[-30:]
            assert not any(x in line for line in app.lines for x in ('WARNING', 'CRITICAL', 'panic:')), app.lines[-30:]
            report['elapsed_seconds'] = round(time.monotonic() - started, 2)
            report['clean_shutdown'] = True
        report['status'] = 'passed'
    except Exception as error:
        report['status'] = 'failed'
        report['error'] = repr(error)
        raise
    finally:
        (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
