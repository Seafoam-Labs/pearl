#!/usr/bin/env python3
"""Native Dome verification in an isolated Wayland/D-Bus session."""
import argparse
import hashlib
import json
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
    parser.add_argument('--output', type=Path, default=PROJECT / 'artifacts/native')
    parser.add_argument('--aqueous-prefix', type=Path, default=PEARL / '.cache/aqueous-activity-production')
    args = parser.parse_args()
    binary, output = args.binary.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {'status': 'running', 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'checks': [], 'captures': []}
    def passed(name):
        report['checks'].append(name)
        print('PASS', name, flush=True)
    try:
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env['GSETTINGS_BACKEND'] = 'memory'
            ipc = IPC(session)
            display = next(iter(ipc.outputs().values()))
            session.run(['wlr-randr', '--output', display['name'], '--custom-mode', '1600x1100@60Hz'])
            rules = Path(session.env['XDG_CONFIG_HOME']) / 'aqueous/rules.toml'
            app = None
            def windows():
                return [w for w in ipc.state() if w['kind'] == 'window' and w.get('app_id') == 'org.aqueous.Dome']
            def key(name, *modifiers, delay=70):
                command = ['wtype', '-s', str(delay)]
                for mod in modifiers:
                    command += ['-M', mod]
                command += ['-k', name]
                for mod in reversed(modifiers):
                    command += ['-m', mod]
                session.run(command)
            def text(value):
                session.run(['wtype', '-s', '70', '--', str(value)])
            def probe(delay=70):
                assert app.proc.poll() is None, app.lines[-30:]
                start = len(app.lines)
                key('F12', delay=delay)
                line = wait_for(lambda: next((line for line in app.lines[start:] if line.startswith('DOME_PROBE ')), None))
                return json.loads(line.removeprefix('DOME_PROBE '))
            def capture(name):
                time.sleep(.2)
                rect = windows()[0]['geometry']
                path = output / f'{name}.png'
                session.run(['grim', '-g', f"{rect['x']},{rect['y']} {rect['width']}x{rect['height']}", path])
                report['captures'].append({'file': path.name, 'geometry': rect, 'state': probe()})
            def launch(width=1120, height=800, *flags, fixture_count=0, font_scale=1, theme="", hang_gpu=False):
                nonlocal app
                rules.write_text(f'[[window]]\napp_id = "org.aqueous.Dome"\nfloating = true\nwidth = {width}\nheight = {height}\n')
                settings = Path(session.env['XDG_CONFIG_HOME']) / 'gtk-4.0/settings.ini'
                settings.parent.mkdir(exist_ok=True)
                settings.write_text(f'[Settings]\ngtk-font-name=Sans {11 * font_scale}\n')
                time.sleep(.2)
                ipc.call('command', action='session.reload', fields={})
                overrides = {'DOME_TEST_GPU_HANG': '1'} if hang_gpu else {}
                app = session.child(f'dome-{len(report["captures"])}', [binary, f'--width={width}', f'--height={height}', '--page=0', *flags], G_DEBUG='fatal-warnings', DOME_TEST_PROCESSES=str(fixture_count), GDK_DPI_SCALE="1", GTK_THEME=theme, **overrides)
                win = wait_for(lambda: next(iter(windows()), None))
                ipc.call('command', action='window.activate', fields={'id': win['id']})
                return wait_for(lambda: (v if (v := probe())['sample'] >= 2 else False))
            def close():
                time.sleep(.25)
                ipc.call('command', action='window.activate', fields={'id': windows()[0]['id']})
                probe()
                key('w', 'ctrl')
                assert app.wait(timeout=8) == 0, app.lines[-30:]
                assert not any(word in line for line in app.lines for word in ['WARNING', 'CRITICAL', 'panic:']), app.lines[-30:]
                wait_for(lambda: not windows())

            initial = launch()
            assert initial['processes'] > 0
            capture('overview-dark')
            for index, name in enumerate(['overview', 'cpu', 'memory', 'disks', 'network', 'gpu', 'sensors', 'processes', 'services']):
                key(str(index + 1), 'alt')
                assert probe()['page'] == index
                if index:
                    capture(name)
            passed('All nine native pages render using live collectors; optional systemd absence remains usable')
            key('2', 'alt')
            key('F7')
            capture('cpu-cores')
            key('F7')
            passed('CPU overall/core views switch without restarting sampling')

            key('2', 'ctrl')
            key('f', 'ctrl')
            text('dome-no-such-process-12345')
            wait_for(lambda: probe()['visible'] == 0)
            key('Escape')
            wait_for(lambda: probe()['visible'] > 0)
            assert probe()['realized_cells'] < probe()['processes'] * 6
            key('F11')
            assert probe()['selected_pid'] > 0
            capture('process-selected')
            passed('Process search, recovery, selection and recycled table cells')

            key('p', 'ctrl')
            # Allow a collection already in flight to finish before asserting quiescence.
            time.sleep(.5)
            paused = probe()
            time.sleep(1.3)
            assert probe()['sample'] == paused['sample']
            key('F5')
            wait_for(lambda: probe()['sample'] > paused['sample'])
            assert probe()['paused']
            key('p', 'ctrl')
            assert not probe()['paused']
            passed('Pause stops periodic collection; manual sampling preserves pause state')

            # Only a child created by this test may be targeted by process-action tests.
            target = session.child('disposable-process', ['/usr/bin/sleep', '300'])
            key('f', 'ctrl'); text(target.proc.pid)
            wait_for(lambda: probe()['visible'] == 1)
            key('F11')
            assert probe()['selected_pid'] == target.proc.pid
            key('F8')
            session.run(['grim', '-o', display['name'], output / 'process-confirmation.png'])
            key('Escape')
            assert target.proc.poll() is None
            key('F8')
            # Cancel is default; Tab advances to the explicitly labeled destructive action.
            key('Tab'); key('Return')
            wait_for(lambda: target.proc.poll() is not None)
            passed('pidfd termination confirmation cancels safely and targets only a disposable child')
            key('Escape')
            fixture = session.child('service-fixture', ['python3', PROJECT / 'tests/service_fixture.py'])
            fixture.expect('READY')
            key('9', 'alt')
            wait_for(lambda: probe()['services'] == 3)
            key('f', 'ctrl'); text('dome-fixture')
            wait_for(lambda: probe()['service_visible'] == 1)
            key('F11')
            key('F8')
            key('Tab'); key('Return')
            fixture.expect('ACTION StopUnit dome-fixture.service inactive')
            time.sleep(.6)
            key('F9')
            key('Tab'); key('Return')
            fixture.expect('ACTION StartUnit dome-fixture.service active')
            time.sleep(.6)
            key('F7'); key('Tab'); key('Return')
            fixture.expect('ACTION RestartUnit dome-fixture.service active')
            key('f', 'ctrl'); key('a', 'ctrl'); text('dome-denied')
            wait_for(lambda: probe()['service_visible'] == 1)
            key('F11'); key('F9'); key('Tab'); key('Return')
            fixture.expect('DENIED')
            time.sleep(.6)
            assert probe()['service_error']
            capture('service-denied')
            key('Escape')
            capture('service-fixture')
            passed('Asynchronous service discovery, stop/start and state refresh use an isolated mock manager')
            fixture.stop()
            wait_for(lambda: probe()['services'] == 0)
            key('1', 'ctrl')
            key('F6')
            session.run(['grim', '-o', display['name'], output / 'preferences.png'])
            key('Escape')
            key('F10')
            capture('summary')
            key('F10')
            close()
            passed('Preferences/summary and clean shutdown with fatal GTK warnings enabled')
            launch(1120, 800, '--light'); capture('overview-light'); close()
            launch(1120, 800, '--native-theme'); capture('native-theme'); close()
            launch(480, 800, '--dark')
            assert not probe()['sidebar']
            report['narrow_actual_width'] = probe()['width']
            assert report['narrow_actual_width'] == 480
            capture('narrow')
            key('2', 'ctrl'); key('F11'); key('Return', 'alt')
            session.run(['grim', '-o', display['name'], output / 'details-narrow.png'])
            key('Escape'); close()
            passed('Light/native theme and narrow navigation/detail layout')
            launch(1120, 800, '--dark', font_scale=2); capture('text-200-percent'); close()
            launch(1120, 800, '--native-theme', theme='HighContrast'); capture('high-contrast'); close()
            passed('200% text scaling and native high contrast render with fatal GTK warnings enabled')
            launch(1120, 800, '--dark', fixture_count=10000)
            key('2', 'ctrl')
            wait_for(lambda: probe()['visible'] == 10000)
            stress = probe()
            assert stress['realized_cells'] < 6000, stress
            capture('processes-10000')
            updates = []
            acknowledgements = []
            for _ in range(8):
                time.sleep(1.1)
                started = time.monotonic()
                updates.append(probe(delay=1)['update_us'])
                acknowledgements.append(round((time.monotonic() - started) * 1000, 2))
            report['process_stress'] = {'rows': 10000, 'realized_cells': stress['realized_cells'], 'update_us': updates, 'key_ack_ms': acknowledgements}
            close()
            passed('10,000 synthetic process rows use bounded recycled cells; update timings recorded')
            launch(1120, 800, '--dark', hang_gpu=True)
            # Force helper coverage even on a system without NVIDIA hardware.
            wait_for(lambda: probe()['gpu_timeouts'] >= 1)
            before = probe()['sample']
            wait_for(lambda: probe()['sample'] > before)
            close()
            passed('A hung GPU helper is killed while core sampling and shutdown stay responsive')
        report['status'] = 'passed'
    except Exception as error:
        report['status'] = 'failed'
        report['error'] = repr(error)
        raise
    finally:
        (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
