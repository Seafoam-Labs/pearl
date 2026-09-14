#!/usr/bin/env python3
"""Exercise real GTK lifecycle and session isolation without touching the host desktop."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession


def clean(child, cycles=1):
    assert child.wait() == 0, '\n'.join(child.lines)
    assert sum('event=cleanup pending=false watched_objects=0' in x for x in child.lines) == cycles, child.lines
    assert not any(word in line for line in child.lines for word in ('CRITICAL', 'WARNING', 'event=css-error', 'panic:')), child.lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', required=True, type=Path, help='instrumented executable from zig build integration')
    parser.add_argument('--production-pearl', required=True, type=Path, help='ordinary executable without test hooks')
    parser.add_argument('--aqueous', type=Path, default=Path(os.environ.get('PEARL_TEST_AQUEOUS_PREFIX', ROOT / '.cache/aqueous')) / 'bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=Path(os.environ.get('PEARL_TEST_AQUEOUS_PREFIX', ROOT / '.cache/aqueous')) / 'bin/aqueousctl')
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/t01/latest')
    args = parser.parse_args()
    args.pearl = args.pearl.resolve()
    args.production_pearl = args.production_pearl.resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    result = dict(status='running', recorded_utc=datetime.now(timezone.utc).isoformat(),
                  executable_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(), checks={})
    result['production_executable_sha256'] = hashlib.sha256(args.production_pearl.read_bytes()).hexdigest()
    checks = result['checks']
    directories = []
    try:
        isolated_cli = dict(PATH=os.environ.get('PATH', '/usr/bin'), LANG='C.UTF-8')
        for argv, code, text in [(['--help'], 0, 'Usage: pearl'), (['--version'], 0, 'Zig 0.16.0'),
                                 (['--bogus'], 2, 'Unknown argument'), ([], 2, 'requires a Wayland display')]:
            response = subprocess.run([str(args.pearl), *argv], env=isolated_cli, capture_output=True, text=True, timeout=5)
            assert response.returncode == code and text in response.stdout + response.stderr, response
        response = subprocess.run([str(args.pearl)], env=dict(isolated_cli, XDG_CURRENT_DESKTOP='GNOME', WAYLAND_DISPLAY='absent'),
                                  capture_output=True, text=True, timeout=5)
        assert response.returncode == 2 and 'requires an Aqueous session' in response.stderr, response
        checks['cli_without_display_and_unsupported_desktop'] = 'pass'
        failed_session = PrivateSession(args.output / 'failed-start', aqueous='/usr/bin/false')
        try:
            with failed_session:
                raise AssertionError('a failing compositor was accepted')
        except RuntimeError as error:
            assert 'private Aqueous failed' in str(error)
        assert failed_session.temp is None and not failed_session.base.exists()
        checks['failed_compositor_start_cleans_private_bus_and_directories'] = 'pass'
        poisoned = dict(os.environ, AQUEOUS_SOCKET='/host/aqueous/ipc.sock', DMS_SOCKET='/host/dms.sock',
                        DBUS_SESSION_BUS_ADDRESS='unix:path=/host/bus', WAYLAND_SOCKET='9999',
                        DISPLAY=':999', LD_PRELOAD='/host/nonexistent.so', XDG_ACTIVATION_TOKEN='host-token',
                        AQUEOUS_CONFIG='/host/wm.toml', XDG_CONFIG_DIRS='/host/config', WAYLAND_DISPLAY='host-wayland')
        with PrivateSession(args.output / 'outer', args.aqueous, inherited=poisoned) as outer:
            directories.append(outer.base)
            for name in ('DMS_SOCKET', 'WAYLAND_SOCKET', 'DISPLAY', 'LD_PRELOAD', 'XDG_ACTIVATION_TOKEN'):
                assert name not in outer.env
            assert all('/host/' not in value for value in outer.env.values())
            checks['poisoned_host_environment_removed'] = 'pass'
            stale = outer.run([args.pearl], check=False, AQUEOUS_SOCKET=str(outer.runtime / 'aqueous/missing/ipc.sock'))
            assert stale.returncode == 2 and 'not a Unix socket' in stale.stderr
            regular = outer.runtime / 'aqueous/fake/ipc.sock'
            regular.parent.mkdir()
            regular.write_text('not a socket')
            wrong_type = outer.run([args.pearl], check=False, AQUEOUS_SOCKET=str(regular))
            assert wrong_type.returncode == 2 and 'not a Unix socket' in wrong_type.stderr
            checks['missing_and_non_socket_endpoints_rejected'] = 'pass'
            common = dict(G_DEBUG='fatal-warnings')
            production = outer.child('production', [args.production_pearl, '--demo'], **common,
                                     PEARL_TEST_CLOSE_MS='1', PEARL_TEST_WORKER_DELAY_MS='5000', PEARL_TEST_CYCLES='50')
            production.expect('event=work-finished applied=true')
            time.sleep(.1)
            assert production.proc.poll() is None, 'production executable honored test shutdown hooks'
            production.signal()
            clean(production)
            checks['production_executable_ignores_test_hooks'] = 'pass'
            preview = outer.child('gallery', [args.pearl, '--demo'], **common)
            preview.expect('event=work-finished applied=true')
            time.sleep(.2)
            outputs = json.loads(outer.run([args.ctl, 'outputs', '--json']).stdout)
            outer.run(['grim', '-o', outputs[0]['name'], args.output / 'gallery.png'])
            preview.signal()
            clean(preview)
            normal = outer.child('normal', [args.pearl], **common, PEARL_TEST_CLOSE_MS='200')
            normal.expect('event=ready mode=session')
            clean(normal)
            assert not any('event=work-started' in line for line in normal.lines)
            checks['session_mode_has_no_fixture_work'] = 'pass'

            cancel = outer.child('cancel-cycles', [args.pearl, '--demo'], **common,
                                 PEARL_TEST_WORKER_DELAY_MS='2000', PEARL_TEST_CLOSE_MS='100', PEARL_TEST_CYCLES='8')
            clean(cancel, cycles=8)
            assert sum('event=work-finished applied=false canceled=true' in x for x in cancel.lines) == 8
            assert sum('reason=window-close' in x for x in cancel.lines) == 8
            checks['eight_cycles_cancel_drain_finalize_unregister'] = 'pass'

            completed = outer.child('complete-cycles', [args.pearl, '--demo'], **common,
                                    PEARL_TEST_CLOSE_MS='350', PEARL_TEST_CYCLES='8')
            clean(completed, cycles=8)
            assert sum('event=work-finished applied=true canceled=false' in x for x in completed.lines) == 8
            checks['eight_cycles_complete_finalize_unregister'] = 'pass'

            # This private display stands in for the host. Tests never address the real host.
            first = outer.child('first-instance', [args.pearl, '--demo'], **common)
            first.expect('event=work-finished applied=true')
            second = outer.child('same-display-instance', [args.pearl, '--demo'], **common, PEARL_TEST_CLOSE_MS='200')
            second.expect('event=ready mode=demo')
            clean(second)
            assert first.proc.poll() is None
            bus_names = outer.run(['busctl', '--address=' + outer.env['DBUS_SESSION_BUS_ADDRESS'], '--no-pager', 'list']).stdout
            assert 'org.aqueous.Pearl' not in bus_names
            result['private_bus_names'] = bus_names
            checks['same_bus_and_display_launches_are_independent'] = 'pass'
            with PrivateSession(args.output / 'nested', args.aqueous, backend='nested', parent_display=outer.display_path) as nested:
                directories.append(nested.base)
                assert nested.env['AQUEOUS_SOCKET'] != outer.env['AQUEOUS_SOCKET']
                assert nested.env['DBUS_SESSION_BUS_ADDRESS'] != outer.env['DBUS_SESSION_BUS_ADDRESS']
                result['nested_outputs'] = json.loads(nested.run([args.ctl, 'outputs', '--json']).stdout)
                third = nested.child('nested-instance', [args.pearl, '--demo'], **common, PEARL_TEST_CLOSE_MS='250')
                third.expect('event=ready mode=demo')
                clean(third)
                # Even an accidentally reused bus cannot redirect activation.
                leaked_bus = nested.child('shared-bus-instance', [args.pearl, '--demo'], **common,
                                          DBUS_SESSION_BUS_ADDRESS=outer.env['DBUS_SESSION_BUS_ADDRESS'], PEARL_TEST_CLOSE_MS='250')
                leaked_bus.expect('event=ready mode=demo')
                clean(leaked_bus)
                assert first.proc.poll() is None
            checks['nested_display_private_bus_and_reused_bus_isolation'] = 'pass'
            first.signal(signal.SIGINT)
            clean(first)
            stopped_work = outer.child('signal-during-work', [args.pearl, '--demo'], **common, PEARL_TEST_WORKER_DELAY_MS='2000')
            stopped_work.expect('event=work-started')
            stopped_work.signal(signal.SIGTERM)
            clean(stopped_work)
            assert any('event=work-finished applied=false canceled=true' in line for line in stopped_work.lines)
            checks['sigint_and_sigterm_drain_cleanly'] = 'pass'
        assert all(not directory.exists() for directory in directories)
        checks['private_directories_removed'] = 'pass'
        result['status'] = 'pass'
        print('PASS: T01 lifecycle, resources, cancellation and session isolation', flush=True)
    except BaseException as error:
        result['status'] = 'failed'
        result['error'] = repr(error)
        raise
    finally:
        (args.output / 'results.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
