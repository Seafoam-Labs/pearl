#!/usr/bin/env python3
"""Exercise the optional Zig/GTK4 VTE candidate, never Coral's live application.

Requires separately compiled --binary and --child (see WORKBENCH_M0_TERMINAL.md).
No downloads, package installation, production wiring, or live configuration edits.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[1]
PEARL = PROJECT.parents[1]
sys.path[:0] = [str(PEARL / 'scripts'), str(PEARL / 'tests/integration')]
from pearl_session import PrivateSession, fixture_prefix, wait_for
from test_surfaces import IPC
from PIL import Image, ImageStat

TITLE = 'Coral M0 — embedded GTK4 VTE'
SENTINEL = 'CORAL-CLIPBOARD-SENTINEL'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--child', type=Path, required=True)
    parser.add_argument('--vte-prefix', type=Path,
                        help='explicit private VTE prefix; only fixture loader is changed')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-terminal-spike/evidence')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='run-', dir=output))
    report = dict(status='running', run=str(run), cases=[],
                  scope='GTK4 VTE embedding feasibility, NOT M5 or job-control containment')
    started = time.monotonic()
    try:
        binary, child = args.binary.resolve(), args.child.resolve()
        for path in (binary, child):
            if not path.is_file() or not os.access(path, os.X_OK):
                raise ValueError(f'not an executable fixture: {path}')
        report['binaries'] = {str(path): sha(path) for path in (binary, child)}
        with PrivateSession(run / 'session', tool_prefix=args.aqueous_prefix) as session:
            report['compositor_baseline'] = session.baseline
            report['private_display'] = str(session.display_path)
            ipc = IPC(session)
            try:
                display = next(iter(ipc.outputs().values()))
                session.run(['wlr-randr', '--output', display['name'], '--custom-mode', '1600x1100@60Hz'])
                # Do not overwrite the compositor's private wlroots loader path.
                overrides = dict(G_DEBUG='fatal-criticals', GSETTINGS_BACKEND='memory',
                                 LANG='C.UTF-8', LC_ALL='C.UTF-8', LANGUAGE='en',
                                 CORAL_SPIKE_CHILD=str(child))
                if args.vte_prefix:
                    lib = args.vte_prefix.resolve() / 'lib'
                    if not (lib / 'libvte-2.91-gtk4.so.0').is_file():
                        raise ValueError(f'GTK4 VTE library missing in {lib}')
                    overrides['LD_LIBRARY_PATH'] = str(lib)
                for serial, mode in enumerate(('exit', 'cancel', 'close', 'exit')):
                    case = dict(mode=mode, serial=serial, checks=[])
                    report['cases'].append(case)
                    app = session.child(f'spike-{serial}-{mode}', [binary], input_pipe=True,
                                        CORAL_SPIKE_MODE=mode, **overrides)
                    app.expect('SPIKE_READY ')
                    ready = json.loads(next(x.removeprefix('SPIKE_READY ') for x in app.lines if x.startswith('SPIKE_READY ')))
                    case['ready'] = ready
                    windows = lambda: [w for w in ipc.state() if w['kind'] == 'window' and w.get('title') == TITLE]
                    window = wait_for(lambda: next(iter(windows()), None))
                    ipc.call('command', action='window.activate', fields={'id': window['id']})

                    def control(command):
                        assert app.proc.poll() is None, app.lines[-20:]
                        app.proc.stdin.write(command + '\n')
                        app.proc.stdin.flush()

                    def probe():
                        start = len(app.lines)
                        control('probe')
                        line = wait_for(lambda: next((x for x in app.lines[start:] if x.startswith('SPIKE_STATE ')), None), 3)
                        return json.loads(line.removeprefix('SPIKE_STATE '))

                    def until(predicate):
                        return wait_for(lambda: (state if predicate(state := probe()) else None), 8)

                    def type_line(text):
                        session.run(['wtype', '-s', '30', '--', text])
                        session.run(['wtype', '-s', '40', '-k', 'Return'])

                    initial = until(lambda s: 'READY\n' in s['text'] and s['mapped'])
                    assert 'Unicode: héλ 中文 e\u0301 🙂' in initial['text'], initial
                    assert 'ANSI green' in initial['text'], initial
                    pids = re.search(r'PIDS:(\d+) (\d+)', initial['text'])
                    assert pids, initial
                    owned = [ready['supervisor'], *map(int, pids.groups())]
                    assert all(Path(f'/proc/{pid}').exists() for pid in owned)
                    case['owned_pids'] = owned
                    maps = Path(f'/proc/{app.proc.pid}/maps').read_text()
                    libraries = sorted({x.split()[-1] for x in maps.splitlines()
                                        if '/libvte-2.91-gtk4.so' in x or '/libgtk-4.so' in x})
                    assert len(libraries) == 2, libraries
                    case['loaded_libraries'] = {p: sha(p) for p in libraries}
                    case['initial'] = initial
                    # Wayland selection ownership needs an input serial. A
                    # modifier-only event supplies one without typing PTY data.
                    session.run(['wtype', '-s', '40', '-k', 'Shift_L'])
                    control('clipboard')
                    probe()
                    wait_for(lambda: session.run(['wl-paste', '--no-newline'], check=False).stdout == SENTINEL)
                    assert initial['actions'] == 0
                    type_line('héλ中文🙂')
                    attacked = until(lambda s: 'ATTACK-DONE' in s['text'])
                    assert 'INPUT:héλ中文🙂' in attacked['text'], attacked
                    assert '"action":"workbench.tripwire"' in attacked['text'], attacked
                    assert attacked['actions'] == 0, attacked
                    assert attacked['rows'] == initial['rows'] and attacked['columns'] == initial['columns'], attacked
                    assert session.run(['wl-paste', '--no-newline']).stdout == SENTINEL
                    assert windows()[0]['title'] == TITLE
                    case['checks'] += ['mapped native GTK4 VTE widget', 'split UTF-8 rendered text',
                                       'Wayland keyboard Unicode round trip',
                                       'OSC/title/link/custom action/window-resize output has no authority',
                                       'OSC52 leaves private clipboard sentinel unchanged']
                    # Positive control: a real ancestor GAction exists and is
                    # resolvable FROM the terminal; zero was not a missing action.
                    control('tripwire')
                    assert until(lambda s: s['actions'] == 1)['actions'] == 1
                    control('resize')
                    resized = until(lambda s: s['rows'] != initial['rows'] and s['columns'] != initial['columns'])
                    type_line('size')
                    resized = until(lambda s: 'RESIZE-DONE' in s['text'])
                    actual = re.search(r'RESIZED:(\d+) (\d+)', resized['text'])
                    assert actual and tuple(map(int, actual.groups())) == (resized['rows'], resized['columns']), resized
                    assert resized['actions'] == 1
                    case['resized'] = resized
                    case['checks'] += ['GAction positive control', 'GTK allocation -> VTE grid -> PTY TIOCGWINSZ']
                    time.sleep(.15)
                    rect = windows()[0]['geometry']
                    capture = run / f'{serial}-{mode}.png'
                    session.run(['grim', '-g', f"{rect['x']},{rect['y']} {rect['width']}x{rect['height']}", capture])
                    with Image.open(capture) as image:
                        # Necessary, not sufficient: visual review also checks
                        # glyphs. Extraction alone cannot prove actual rendering.
                        assert max(ImageStat.Stat(image.convert('RGB')).stddev) > 10
                    case['capture'] = dict(path=str(capture), sha256=sha(capture), geometry=rect)
                    if mode == 'exit':
                        type_line('exit')
                    elif mode == 'cancel':
                        control('cancel')
                    else:
                        ipc.call('command', action='window.close', fields={'id': window['id']})
                    app.expect('SPIKE_REAP ', timeout=8)
                    reaped = json.loads(next(x.removeprefix('SPIKE_REAP ') for x in app.lines if x.startswith('SPIKE_REAP ')))
                    case['reaped'] = reaped
                    assert reaped['report']['spawn_errno'] == 0 and reaped['report']['reaped'] == 1, reaped
                    assert reaped['report']['status'] == (7 << 8 if mode == 'exit' else 9), reaped
                    assert all(not Path(f'/proc/{pid}').exists() for pid in owned), owned
                    if mode != 'close':
                        final = probe()
                        assert final['eof'] and final['report'] is not None and final['actions'] == 1, final
                        if mode == 'exit':
                            assert 'EXIT:7' in final['text'], final
                        control('quit')
                    assert app.wait(timeout=8) == 0, app.lines[-20:]
                    assert not any('CRITICAL' in x or 'panic:' in x for x in app.lines), app.lines[-20:]
                    wait_for(lambda: not windows())
                    assert session.compositor.proc.poll() is None
                    case['checks'].append('leader, stubborn same-group descendant and supervisor reaped; EOF; clean teardown')
                    print(f'PASS terminal {serial}/{mode}', flush=True)
            finally:
                ipc.close()
        report['status'] = 'passed'
    except (Exception, KeyboardInterrupt) as exc:
        report['status'] = 'failed'
        report['error'] = f'{type(exc).__name__}: {exc}'
        print(report['error'], file=sys.stderr)
        for path in sorted((run / 'session').glob('spike-*.log')):
            print(f'--- {path} ---\n' + '\n'.join(path.read_text(errors='replace').splitlines()[-20:]), file=sys.stderr)
    report['elapsed_seconds'] = round(time.monotonic() - started, 3)
    (run / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'{report["status"].upper()}: {output / "results.json"}', flush=True)
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
