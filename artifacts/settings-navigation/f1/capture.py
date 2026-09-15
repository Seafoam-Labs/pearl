#!/usr/bin/env python3
"""F1 review evidence: current flyout baseline and live route rejection.

Run with the F1 ReleaseSafe --pearl and --ctl artifacts. This intentionally
captures the pre-F2 combined form, not the later compact page design.
"""
import argparse
import hashlib
import json
from pathlib import Path
import socket
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / 'scripts'), str(ROOT / 'tests/integration')]
from pearl_session import PrivateSession
from test_surfaces import IPC, capture, clean, ctl, eventually_status, status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, required=True)
    parser.add_argument('--ctl', type=Path, required=True)
    args = parser.parse_args()
    pearl, binary = args.pearl.resolve(), args.ctl.resolve()
    checks = {}
    result = dict(status='running', checks=checks,
                  pearl_sha256=hashlib.sha256(pearl.read_bytes()).hexdigest(),
                  ctl_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
    output = Path(__file__).resolve().parent / 'baseline'
    try:
        with PrivateSession(output) as s:
            ipc = IPC(s)
            app = s.child('pearl', [pearl], G_DEBUG='fatal-warnings')
            app.expect('event=control-ready')
            live = eventually_status(s, binary, lambda v: len(v['outputs']) == 2)
            target, other = live['outputs']
            tid = target['id']
            ctl(s, binary, 'control-center', 'show', '--output', tid)
            before = eventually_status(s, binary, lambda v: v['popup'] and v['popup']['pane'] == 'control')['popup']
            ctl(s, binary, 'control-center', 'toggle', '--page', 'overview', '--output', tid)
            eventually_status(s, binary, lambda v: v['popup'] is None)
            ctl(s, binary, 'control-center', 'show', '--page', 'overview', '--output', tid)
            eventually_status(s, binary, lambda v: v['popup'] == before)
            checks['legacy-default-and-explicit-overview-toggle'] = True

            for page in ('invalid', 'appearance', 'Sound'):
                rejected = s.run([binary, 'control-center', 'toggle', '--page', page], check=False)
                assert rejected.returncode == 2, rejected
                assert status(s, binary)['popup'] == before
            # Exercise server validation directly, bypassing pearlctl's parser.
            endpoint = s.runtime / 'pearl' / ipc.session / 'control.sock'
            for page in ('invalid', 'appearance', None, 42):
                with socket.socket(socket.AF_UNIX) as wire:
                    wire.settimeout(4)
                    wire.connect(str(endpoint))
                    request = dict(pearl=1, id='1', session=ipc.session,
                                   display=str(s.display_path), op='control_toggle',
                                   output=tid, page=page)
                    wire.sendall(json.dumps(request).encode() + b'\n')
                    reply = json.loads(wire.makefile('r').readline())
                    assert not reply['ok'], reply
                assert status(s, binary)['popup'] == before
            checks['invalid-cli-and-wire-routes-preserve-popup'] = True

            for page in ('sound', 'network', 'bluetooth', 'power'):
                reply = ctl(s, binary, 'control-center', 'toggle', '--page', page,
                            '--output', tid, code=4)
                assert reply['err']['code'] == 'Unsupported', reply
                assert status(s, binary)['popup'] == before
            checks['unconnected-f1-pages-fail-without-changing-popup'] = True
            ctl(s, binary, 'control-center', 'toggle', '--page', 'overview',
                '--output', 'missing-output', code=4)
            assert status(s, binary)['popup'] == before
            checks['invalid-output-preserves-popup'] = True

            for edge, name in (('top', 'horizontal'), ('left', 'vertical')):
                ctl(s, binary, 'popup', 'hide')
                ctl(s, binary, 'bar', 'set', '--output', tid, '--edge', edge, '--size', '48')
                ctl(s, binary, 'control-center', 'show', '--output', tid)
                eventually_status(s, binary, lambda v: v['popup'] and v['popup']['pane'] == 'control')
                time.sleep(.3)
                capture(s, name, target['connector'])
            checks['horizontal-and-vertical-baseline-captured'] = True
            ctl(s, binary, 'control-center', 'show', '--page', 'overview', '--output', other['id'])
            eventually_status(s, binary, lambda v: v['popup'] and v['popup']['output'] == other['id'])
            # Status reports creation before Wayland has mapped/focused it.
            s.run(['wtype', '-s', '200', '-k', 'Escape', '-s', '100'])
            eventually_status(s, binary, lambda v: v['popup'] is None)
            checks['output-replacement-and-escape'] = True
            ctl(s, binary, 'quit')
            clean(app)
            ipc.close()
            result['status'] = 'passed'
    finally:
        output.mkdir(parents=True, exist_ok=True)
        (output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
