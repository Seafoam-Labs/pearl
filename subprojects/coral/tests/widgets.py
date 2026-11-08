#!/usr/bin/env python3
"""Run Coral's Zig widget tests in a private headless Aqueous/Wayland session.

Build wiring supplies --binary; this runner never builds or installs anything.
Use --aqueous-prefix /usr for installed fixtures, or the default fixture prefix.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[1]
PEARL = PROJECT.parents[1]
sys.path.insert(0, str(PEARL / 'scripts'))
from pearl_session import PrivateSession, fixture_prefix

BINARY_TIMEOUT = 60


def failure_logs(directory):
    for path in sorted(directory.glob('*.log')):
        print(f'\n--- {path} (last 80 lines) ---', file=sys.stderr)
        print('\n'.join(path.read_text(errors='replace').splitlines()[-80:]),
              file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True,
                        help='compiled Zig test artifact (not the Coral application)')
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-widgets')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    args = parser.parse_args()
    binary = args.binary.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Each invocation has its own logs, including when compositor startup fails.
    session_output = Path(tempfile.mkdtemp(prefix='session-', dir=output))
    started = time.monotonic()
    report = {
        'status': 'running',
        'binary': str(binary),
        'aqueous_prefix': str(args.aqueous_prefix.resolve()),
        'session_logs': str(session_output),
        'timeout_seconds': BINARY_TIMEOUT,
    }
    try:
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError(f'--binary must be an executable Zig test artifact: {binary}')
        report['binary_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
        with PrivateSession(session_output, tool_prefix=args.aqueous_prefix) as session:
            # PrivateSession discards host display/bus/config and loader overrides.
            child = session.child(
                'widgets', [binary], G_DEBUG='fatal-criticals',
                GSETTINGS_BACKEND='memory', LANG='C.UTF-8', LC_ALL='C.UTF-8',
                LANGUAGE='en',
            )
            try:
                report['returncode'] = child.wait(timeout=BINARY_TIMEOUT)
            except subprocess.TimeoutExpired as exc:
                raise TimeoutError(f'Zig widget tests exceeded {BINARY_TIMEOUT}s') from exc
            if report['returncode'] != 0:
                raise RuntimeError(f'Zig widget tests exited {report["returncode"]}')
            if session.compositor.proc.poll() is not None:
                raise RuntimeError('Private compositor exited during widget tests')
            print(child.logfile.read_text(errors='replace'), end='', flush=True)
        report['status'] = 'passed'
    except (Exception, KeyboardInterrupt) as exc:
        report['status'] = 'failed'
        report['error'] = f'{type(exc).__name__}: {exc}'
        print(f'FAIL: {report["error"]}', file=sys.stderr)
        # The context manager has stopped the binary (including timed-out process
        # groups) and joined log collectors before diagnostics are read.
        failure_logs(session_output)
    report['elapsed_seconds'] = round(time.monotonic() - started, 3)
    summary = output / 'results.json'
    summary.write_text(json.dumps(report, indent=2) + '\n')
    print(f'{report["status"].upper()}: Coral widget tests '
          f'({report["elapsed_seconds"]:.3f}s); summary: {summary}', flush=True)
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
