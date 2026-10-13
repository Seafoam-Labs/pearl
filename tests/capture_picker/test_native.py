#!/usr/bin/env python3
"""Capture picker protocol and UI in a private Wayland session."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, fixture_prefix
BINARY = ROOT / 'zig-out/capture-test/bin/pearl-capture-picker'
PRODUCTION = ROOT / 'zig-out/bin/pearl-capture-picker'

def run():
    identity=subprocess.run([BINARY,'--identity'],capture_output=True)
    assert identity.returncode==2 and not identity.stdout, 'Instrumented pickers must not pass the installer identity check'
    for data in (b'', b'\n', b'bad\x00source', b'\xff', b'a' * (1024 * 1024 + 1), b'a\n' * 4097):
        result = subprocess.run([BINARY], input=data, capture_output=True, timeout=5)
        assert result.returncode == (0 if data in (b'', b'\n') else 2), result
        assert not result.stdout
    with PrivateSession(ROOT / 'artifacts/capture-picker/native', tool_prefix=fixture_prefix()) as session:
        processes = []
        def start(data, binary=BINARY, **options):
            process = subprocess.Popen([binary], env={**session.env, 'G_DEBUG': 'fatal-warnings', **options}, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            processes.append(process)
            process.stdin.write(data); process.stdin.close(); process.stdin = None
            return process
        def finish(process, expected=b'', status=0):
            out, err = process.communicate(timeout=8)
            assert process.returncode == status and out == expected, (process.returncode, out, err)
        try:
            data = 'Monitor: DP-1 café <b>original</b>  \nMonitor: HDMI-A-1\n'.encode()
            for index in (0, 1):
                finish(start(data, PEARL_CAPTURE_TEST_SELECT=str(index), PEARL_CAPTURE_TEST_ACTION='share'), data.splitlines(keepends=True)[index])
            finish(start(data, PEARL_CAPTURE_TEST_ACTION='cancel'))
            p = start(data, PEARL_CAPTURE_TEST_ACTION='share')
            time.sleep(.8)
            assert p.poll() is None, 'No selection must keep sharing disabled'
            session.run(['grim',str(session.output/'initial.png')])
            session.run(['wlrctl', 'toplevel', 'focus', 'app_id:org.aqueous.Pearl.CapturePicker']); session.run(['wtype', '-s', '100', '-k', 'Escape']); finish(p)
            for light in ('0', '1'):
                options = {'PEARL_CAPTURE_TEST_SELECT': '1'}
                if light == '1': options['PEARL_CAPTURE_TEST_LIGHT'] = '1'
                p = start(data, **options)
                time.sleep(.8)
                session.run(['grim', str(session.output / ('light.png' if light == '1' else 'dark.png'))])
                session.run(['wlrctl', 'toplevel', 'focus', 'app_id:org.aqueous.Pearl.CapturePicker']); session.run(['wtype', '-s', '100', '-k', 'Escape']); finish(p)
            for mode in ('narrow','rtl','gtk'):
                if mode=='narrow':
                    session.run(['wlr-randr','--output','HEADLESS-1','--custom-mode','400x600','--pos','400,0','--output','HEADLESS-2','--custom-mode','400x600','--pos','0,0'])
                many='\n'.join(f'Monitor: source {i} — long label אבג 日本語' for i in range(60)).encode()
                p=start(many,PEARL_CAPTURE_TEST_VIEW=mode)
                time.sleep(.8)
                session.run(['grim',str(session.output/(mode+'.png'))])
                session.run(['wlrctl','toplevel','focus','app_id:org.aqueous.Pearl.CapturePicker'])
                session.run(['wtype','-s','100','-k','Escape']);finish(p)
                if mode=='narrow':
                    session.run(['wlr-randr','--output','HEADLESS-1','--custom-mode','1280x720','--pos','1280,0','--output','HEADLESS-2','--custom-mode','1280x720','--pos','0,0'])
            # Production ignores test controls; user action is still necessary.
            p = start(b'Monitor: single\n', binary=PRODUCTION, PEARL_CAPTURE_TEST_SELECT='0', PEARL_CAPTURE_TEST_ACTION='share')
            time.sleep(.8); assert p.poll() is None
            session.run(['wlrctl', 'toplevel', 'focus', 'app_id:org.aqueous.Pearl.CapturePicker']); session.run(['wtype', '-s', '100', '-k', 'Escape']); finish(p)
            first = start(b'first\n', PEARL_CAPTURE_TEST_SELECT='0', PEARL_CAPTURE_TEST_ACTION='share')
            second = start(b'second\n', PEARL_CAPTURE_TEST_SELECT='0', PEARL_CAPTURE_TEST_ACTION='share')
            finish(first, b'first\n'); finish(second, b'second\n')
            p = start(data); time.sleep(.5); p.terminate()
            out, _ = p.communicate(timeout=5); assert not out
            # A dead reader must dismiss the dialog, without waiting for user input.
            p = start(data); p.stdout.close(); p.stdout = None
            assert p.wait(timeout=5) == 2
            print('PASS exact selections, cancellation, no implicit approval, dark/light rendering, concurrent requests, signals and lost reader')
        finally:
            for p in processes:
                if p.poll() is None: p.kill()
                p.wait()
if __name__ == '__main__': run()
