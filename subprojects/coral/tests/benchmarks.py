#!/usr/bin/env python3
"""Validation harness for the Zig M0 workloads, not application implementation.

Owns private test sessions, hard per-process watchdogs, provenance and reporting.
All fixture generation and measured editor/process/PTY operations live in Zig.
No cache dropping, provider calls, host session injection or package installation.
"""
import argparse
import hashlib
import json
import math
import os
import io
import signal
import shutil
from pathlib import Path
import platform
import re
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

PROJECT = Path(__file__).resolve().parents[1]
PEARL = PROJECT.parents[1]
sys.path.insert(0, str(PEARL / 'scripts'))
from pearl_session import PrivateSession, fixture_prefix


def sha(data):
    return hashlib.sha256(data).hexdigest()


def command(argv):
    try:
        run = subprocess.run(argv, cwd=PROJECT, capture_output=True, timeout=10)
        return {'argv': argv, 'returncode': run.returncode,
                'stdout': run.stdout.decode(errors='replace'),
                'stderr': run.stderr.decode(errors='replace')}
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {'argv': argv, 'unavailable': str(exc)}


def read(path):
    try:
        return Path(path).read_text()
    except OSError as exc:
        return f'unavailable: {exc}'


def sources():
    paths = [PROJECT / 'build.zig', PROJECT / 'build.zig.zon', PROJECT / '.zigversion',
             Path(__file__), PEARL / 'scripts/pearl_session.py',
             PEARL / 'src/i18n/runtime.zig', PEARL / 'src/testing/repeat.zig',
             PEARL / 'bindings/c/build.zig']
    for directory in ('src', 'resources'):
        paths.extend(p for p in (PROJECT / directory).rglob('*') if p.is_file())
    files = {str(p.relative_to(PEARL)): sha(p.read_bytes()) for p in sorted(paths)}
    return {'files': files, 'manifest_sha256': sha(json.dumps(files, sort_keys=True).encode())}


def engine_sources(snapshot):
    """Conservative local import closure; includes imported test declarations too."""
    pending = ['subprojects/coral/src/benchmark_m0.zig', 'subprojects/coral/src/c.h',
               'subprojects/coral/build.zig', 'subprojects/coral/build.zig.zon',
               'src/i18n/runtime.zig', 'src/testing/repeat.zig', 'bindings/c/build.zig']
    found = {}
    while pending:
        key = pending.pop()
        if key in found or key not in snapshot['files']:
            continue
        found[key] = snapshot['files'][key]
        path = PEARL / key
        if path.suffix == '.zig':
            for relative in re.findall(r'@import\("([^"]+\.zig)"\)', path.read_text()):
                imported = (path.parent / relative).resolve()
                if imported.is_relative_to(PEARL):
                    pending.append(str(imported.relative_to(PEARL)))
    return {'files': dict(sorted(found.items())),
            'manifest_sha256': sha(json.dumps(found, sort_keys=True).encode())}


def distribution(values):
    ordered = sorted(values)
    def rank(p):
        return ordered[max(0, math.ceil(p * len(ordered)) - 1)]
    return {'n': len(ordered), 'p50_us': rank(.5), 'p95_us': rank(.95),
            'p99_us': rank(.99), 'max_us': ordered[-1]} if ordered else {'n': 0}


def heavy_work(owned_root=None):
    rows = subprocess.check_output(['ps', '-eo', 'pid=,ppid=,args='], text=True).splitlines()
    processes = {int(p): (int(parent), argv) for row in rows if len(parts := row.split(None, 2)) == 3
                 for p, parent, argv in [parts]}
    ancestors = set()
    pid = os.getpid()
    while pid in processes and pid not in ancestors:
        ancestors.add(pid)
        pid = processes[pid][0]
    if owned_root is not None:
        # PTY/capture's private supervisors fork without exec, retaining the
        # benchmark argv. They are workload children, not competing benchmarks.
        owned = {owned_root}
        while True:
            more = {pid for pid, (parent, _) in processes.items() if parent in owned}
            if more <= owned:
                break
            owned.update(more)
        ancestors.update(owned)
    markers = ('zig build ', 'tests/native.py', 'tests/widgets.py', 'tests/app_groups.py',
               'tests/app_recovery.py', 'tests/terminal_spike.py', 'tests/prototype_m0.py',
               'coral-benchmark-m0')
    return {pid: argv for pid, (_, argv) in processes.items()
            if pid not in ancestors and any(marker in argv for marker in markers)
            and 'python3 -c' not in argv and 'sh -c' not in argv}


def wait_idle():
    deadline = time.monotonic() + 60
    while busy := heavy_work():
        if time.monotonic() >= deadline:
            raise RuntimeError(f'other heavy validation still active; no timing run started: {busy}')
        time.sleep(1)


def execute(session, binary, name, options, timeout, output, extra=None):
    wait_idle()
    started = time.monotonic_ns() // 1000
    child = session.child(name, [binary], G_DEBUG='fatal-criticals',
                          GSETTINGS_BACKEND='memory', LANG='C.UTF-8', LC_ALL='C.UTF-8',
                          LANGUAGE='en', **options, **(extra or {}))
    result = {'name': name, 'options': options, 'timeout_seconds': timeout,
              'log': str(child.logfile), 'launch_monotonic_us': started}
    overlaps = []
    stop_monitor = threading.Event()
    def monitor():
        while not stop_monitor.wait(2):
            busy = heavy_work(owned_root=child.proc.pid)
            if busy:
                overlaps.append({'monotonic_us': time.monotonic_ns() // 1000, 'processes': busy})
    watcher = threading.Thread(target=monitor, daemon=True)
    watcher.start()
    try:
        try:
            result['returncode'] = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            result['failure'] = 'watchdog timeout (retained as failure, never dropped)'
            child.stop()
            result['returncode'] = child.proc.returncode
    finally:
        stop_monitor.set()
        watcher.join(timeout=3)
    result['concurrent_validation_observed'] = overlaps
    if overlaps:
        result.setdefault('failure', 'overlapping heavy validation; not a qualifying timing baseline')
    result['elapsed_seconds'] = (time.monotonic_ns() // 1000 - started) / 1e6
    records = []
    for line in child.logfile.read_text(errors='replace').splitlines():
        if line.startswith('{'):
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                result['failure'] = 'malformed/truncated measurement record'
    if not any(r.get('kind') == 'complete' for r in records) or result['returncode'] != 0:
        result.setdefault('failure', 'workload failed or terminated before completion')
    if 'CRITICAL' in child.logfile.read_text(errors='replace'):
        result['failure'] = 'GTK critical'
    metrics = {}
    for row in records:
        if row['kind'] == 'sample':
            metrics.setdefault(row['metric'], []).append(row['us'])
        if row['kind'] == 'ready':
            metrics.setdefault('launch-to-mapped-edit-probe', []).append(row['monotonic_us'] - started)
            # GTK focus is not compositor presentation or input event acknowledgement.
            result['focus_within'] = row['focus_within']
    input_values = [value for key, values in metrics.items()
                    if key in ('insert-buffer-drain', 'delete-buffer-drain',
                               'undo-delete-buffer-drain', 'undo-insert-buffer-drain',
                               'grouped-edit-refresh-drain', 'grouped-undo-refresh-drain',
                                                              'bounded-edit-refresh-drain', 'bounded-undo-refresh-drain')
                    for value in values]
    if input_values:
        metrics['all-input-operations'] = input_values
    if options['BENCH_MODE'] in ('B02', 'B03', 'B04', 'B05', 'B03-bounded-excerpt') and len(input_values) != 1000:
        result.setdefault('failure', f'incomplete input sample gate: {len(input_values)}/1000')
    result['metrics'] = {k: distribution(v) for k, v in metrics.items()}
    result['max_dispatch_us'] = max((r['dispatch_us'] for r in records if r['kind'] == 'stall'), default=0)
    closed = [r for r in records if r['kind'] == 'memory' and r['stage'] == 'closed' and r['cycle'] < 5]
    if options['BENCH_MODE'] == 'B04':
        closed = closed[:5]
        warmed = [r['rss_kib'] for r in closed]
        result['post_close_rss_kib'] = warmed
        if len(warmed) == 5:
            result['retention_screen_exceeded'] = (all(x < y for x, y in zip(warmed[1:], warmed[2:]))
                                                    and warmed[-1] - warmed[0] > max(10240, .05 * warmed[0]))
    result['records'] = records
    result['log_sha256'] = sha(child.logfile.read_bytes())
    (output / (name + '.json')).write_text(json.dumps(result, indent=2) + '\n')
    print(('FAIL' if 'failure' in result else 'PASS'), name,
          f"{result['elapsed_seconds']:.3f}s", result.get('failure', ''), flush=True)
    return result


def main():
    def interrupted(signum, _frame):
        raise KeyboardInterrupt(f'received signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--capture-sources', type=Path, help='build-owned source snapshot before compilation; no workloads')
    parser.add_argument('--expected-sources', type=Path, help='require benchmark import closure to match pre-compilation snapshot')
    parser.add_argument('--optimize', default='unknown')
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-benchmarks')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    parser.add_argument('--workload', action='append', choices=['B01', 'B02', 'B03', 'B04', 'B05', 'B03-bounded-excerpt', 'frame-probe', 'transport'])
    parser.add_argument('--bounded-bytes', type=int, choices=[65536, 1048576], default=1048576,
                        help='explicit bounded-excerpt source size; 64KiB is a separate smaller policy case, never full B03')
    parser.add_argument('--bounded-close-source', action='store_true',
                        help='explicit alternate fallback workflow: close guarded full-source view after opening excerpt')
    parser.add_argument('--input-bytes', type=int, choices=[1048576, 10485760],
                        help='select one B02 size; default runs both, never reduces sample counts')
    args = parser.parse_args()
    if args.capture_sources:
        snapshot = sources()
        args.capture_sources.write_text(json.dumps({'all': snapshot, 'engine': engine_sources(snapshot)}, indent=2) + '\n')
        return 0
    if args.binary is None:
        parser.error('--binary is required unless capturing sources')
    args.output.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=args.output.resolve()))
    binary = args.binary.resolve()
    before = sources()
    engine_before = engine_sources(before)
    expected = json.loads(args.expected_sources.read_text()) if args.expected_sources else None
    if expected and expected['engine'] != engine_before:
        raise RuntimeError('benchmark source closure changed between compilation snapshot and execution; rebuild after writers finish')
    # Include untracked Zig work as well as the tracked diff: hashes alone cannot
    # reconstruct a concurrently developed source tree after it changes.
    with tarfile.open(output / 'sources.tar.gz', 'w:gz') as archive:
        for path in before['files']:
            data = (PEARL / path).read_bytes()
            if sha(data) != before['files'][path]:
                raise RuntimeError(f'source changed during archive: {path}')
            archive.addfile(archive.gettarinfo(PEARL / path, arcname=path), io.BytesIO(data))
    diff = command(['git', '--no-pager', 'diff', '--binary', 'HEAD', '--', '.'])
    (output / 'dirty.diff').write_text(diff.get('stdout', ''))
    report = {
        'schema': 1, 'status': 'running', 'invocation': sys.argv,
        'build_command': f'zig build benchmarks -Doptimize={args.optimize}',
        'optimize': args.optimize, 'binary': str(binary), 'binary_sha256': sha(binary.read_bytes()),
        'source_before': before, 'engine_source_before': engine_before, 'precompile_sources': expected,
                'source_archive_sha256': sha((output / 'sources.tar.gz').read_bytes()),
        'revision': command(['git', '--no-pager', 'rev-parse', 'HEAD']),
        'git_status': command(['git', '--no-pager', '--no-optional-locks', 'status', '--short']),
        'dirty_diff_sha256': sha((output / 'dirty.diff').read_bytes()),
        'environment': {
            'platform': platform.uname()._asdict(),
            'cpu': command(['lscpu']), 'ram': read('/proc/meminfo'),
            'storage': command(['findmnt', '-T', str(PROJECT)]),
            'block_devices': command(['lsblk', '-o', 'NAME,MODEL,SIZE,ROTA,TYPE']),
            'gpu': command(['lspci', '-nn']),
            'power_profile': command(['powerprofilesctl', 'get']),
            'governors': {str(p): read(p) for p in Path('/sys/devices/system/cpu').glob('cpu*/cpufreq/scaling_governor')},
            'zig': command(['zig', 'version']),
            'libraries': command(['pkg-config', '--modversion', 'gtk4', 'gtksourceview-5', 'enchant-2']),
            'font': command(['fc-match', 'monospace']),
            'session': 'private Aqueous headless; requested WLR_RENDERER=pixman (actual renderer recorded in compositor log); GTK cairo',
            'window': 'requested 1000x700 logical pixels; no frame/presentation timestamps',
            'theme': 'GTK default in isolated empty config; no Coral app CSS',
            'features': 'Production syntax policy: disabled at >=512Ki characters or >16KiB paragraph; canonical undo/search/spelling tag; no app spell worker/watcher/recovery controller',
            'wrap': 'B03 full-render control bypasses layout guard (not syntax policy); separate B03-bounded-excerpt uses production guard and 2048-character excerpt; both wrap variants recorded',
            'cache': 'unspecified OS cache; never dropped; first class uses fresh private config/cache, warm reuses each config',
            'background': 'private bus/compositor only; host activity is uncontrolled',
        },
        'limitations': [
            'Engine subsystem baselines, not full Coral application benchmarks.',
            'No input-event injection or compositor presentation measurement: all paint/startup gates remain unverified.',
            'B03 10s load/layout alarm; failures and partial records are retained.',
            'Tab/excerpt RSS includes GTK allocator retention; memory screening is not a leak diagnosis.',
            'Save/durability and cancellation correctness are covered by unit/native tests, not these timing proxies.',
            '10MiB engine input does not establish app >10MiB reduced-feature boundary behavior.',
        ], 'trials': []}
    summary = output / 'results.json'
    def publish():
        summary.write_text(json.dumps(report, indent=2) + '\n')
    publish()
    selected = args.workload or ['B01', 'B02', 'B03', 'B04', 'B05', 'B03-bounded-excerpt', 'frame-probe', 'transport']
    try:
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            report['environment']['session_env'] = session.env
            report['environment']['compositor_baseline'] = session.baseline
            report['environment']['compositor_sha256'] = sha(session.aqueous.read_bytes())
            report['environment']['display'] = command([str(args.aqueous_prefix / 'bin/aqueous'), '--version'])
            # wayland-info reports the actual headless output refresh and scale.
            report['environment']['wayland_info'] = session.run(['wayland-info'], check=False).stdout if shutil.which('wayland-info') else 'unavailable (see compositor log)'
            def run(name, opts, timeout=120, extra=None):
                report['in_progress'] = {'name': name, 'options': opts, 'timeout_seconds': timeout,
                                         'log': str(output / 'session' / (name + '.log'))}
                publish()
                report['trials'].append(execute(session, binary, name, opts, timeout, output, extra))
                report.pop('in_progress')
                publish()
                if session.compositor.proc.poll() is not None:
                    raise RuntimeError('private compositor exited; remaining trials not run')
            if 'B01' in selected:
                fixtures = session.base / 'benchmark-fixtures'
                fixtures.mkdir(mode=0o700)
                report['fixture_setup'] = execute(session, binary, 'fixtures',
                    {'BENCH_MODE': 'fixtures', 'BENCH_FIXTURE_DIR': str(fixtures)}, 15, output)
                if 'failure' in report['fixture_setup']:
                    raise RuntimeError('Zig fixture save/cancel/readback validation failed')
                for size in (0, 1048576):
                    for i in range(20):
                        overrides = {}
                        for key in ('XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'XDG_DATA_HOME'):
                            path = session.base / f'start-{size}-{i}-{key}'
                            path.mkdir(mode=0o700)
                            overrides[key] = str(path)
                        for cls in ('first-process-cache-unspecified', 'warm'):
                            run(f'B01-{size}-{cls}-{i:02}', {'BENCH_MODE': 'B01', 'BENCH_BYTES': str(size), 'BENCH_FILE': str(fixtures / f'{size}.txt')}, 15, overrides)
            if 'B02' in selected:
                for size in ([args.input_bytes] if args.input_bytes else (1048576, 10485760)):
                    for panes in (1, 2):
                        run(f'B02-{size}-{panes}panes', {'BENCH_MODE': 'B02', 'BENCH_BYTES': str(size), 'BENCH_PANES': str(panes)}, 180 if size == 1048576 else 60)
            if 'B03' in selected:
                for wrap in (0, 1):
                    run(f'B03-wrap{wrap}', {'BENCH_MODE': 'B03', 'BENCH_WRAP': str(wrap)}, 60)
            if 'B04' in selected:
                for tabs in (1, 20, 100):
                    run(f'B04-{tabs}tabs', {'BENCH_MODE': 'B04', 'BENCH_TABS': str(tabs)}, 180)
            if 'B05' in selected:
                run('B05', {'BENCH_MODE': 'B05'}, 180)
            if 'B03-bounded-excerpt' in selected:
                for wrap in (0, 1):
                    suffix = '-source-view-closed' if args.bounded_close_source else '-source-view-retained'
                    run(f'B03-bounded-excerpt-{args.bounded_bytes}-wrap{wrap}{suffix}',
                        {'BENCH_MODE': 'B03-bounded-excerpt', 'BENCH_WRAP': str(wrap), 'BENCH_BYTES': str(args.bounded_bytes),
                         'BENCH_CLOSE_SOURCE_VIEW': str(int(args.bounded_close_source))}, 120)
            if 'frame-probe' in selected:
                run('frame-probe', {'BENCH_MODE': 'frame-probe'}, 15)
            if 'transport' in selected:
                run('transport', {'BENCH_MODE': 'transport'}, 30)
            if session.compositor.proc.poll() is not None:
                raise RuntimeError('private compositor exited')
        report['status'] = 'failed' if any('failure' in t for t in report['trials']) else 'passed-proxies-only'
    except (Exception, KeyboardInterrupt) as exc:
        report['status'] = 'failed'
        report['error'] = f'{type(exc).__name__}: {exc}'
    compositor_log = output / 'session/compositor.log'
    if compositor_log.exists():
        report['environment']['compositor_log_sha256'] = sha(compositor_log.read_bytes())
        report['environment']['compositor_startup_log'] = compositor_log.read_text(errors='replace').splitlines()[:60]
    report['source_after'] = sources()
    report['source_changed_during_run'] = before != report['source_after']
    report['source_changed_paths'] = [p for p in sorted(before['files'].keys() | report['source_after']['files'].keys())
                                      if before['files'].get(p) != report['source_after']['files'].get(p)]
    report['engine_source_after'] = engine_sources(report['source_after'])
    report['engine_changed_during_run'] = engine_before != report['engine_source_after']
    if report['engine_changed_during_run']:
        report['status'] = 'failed'
        report['source_error'] = 'benchmark import closure changed; results retained but not a stable-source baseline'
    aggregates = {}
    for trial in report['trials']:
        for row in trial['records']:
            if row['kind'] == 'ready':
                cls = trial['name'].rsplit('-', 1)[0]
                aggregates.setdefault(cls, []).append(row['monotonic_us'] - trial['launch_monotonic_us'])
    report['startup_distributions'] = {k: distribution(v) for k, v in aggregates.items()}
    report['trial_count'] = len(report['trials'])
    report['failed_trial_count'] = sum('failure' in t for t in report['trials'])
    publish()
    print(f"{report['status']}: {report['trial_count']} trials; {report['failed_trial_count']} failed; {summary}", flush=True)
    return 0 if report['status'] == 'passed-proxies-only' else 1


if __name__ == '__main__':
    raise SystemExit(main())
