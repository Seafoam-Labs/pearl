#!/usr/bin/env python3
"""S1: real Pearl backend / independent frontend transport, private Aqueous only."""
import argparse
import hashlib
import json
import socket
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from test_surfaces import IPC, status, clean


class Frontend:
    def __init__(self, endpoint, identity, display):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(7)
        self.sock.connect(str(endpoint))
        self.file = self.sock.makefile('rb')
        self.identity, self.display, self.serial = identity, display, 0

    def request(self, **overrides):
        self.serial += 1
        return dict(settings=1, id=str(self.serial), session=self.identity,
                    display=self.display, op='hello' if self.serial == 1 else 'ping') | overrides

    def call(self, **overrides):
        self.sock.sendall(json.dumps(self.request(**overrides)).encode() + b'\n')
        return json.loads(self.file.readline())

    def close(self):
        self.file.close()
        self.sock.close()

    def __enter__(self): return self
    def __exit__(self, *args): self.close()


def identity(s):
    ipc = IPC(s)
    token = ipc.session
    ipc.close()
    return token, str(Path(s.env['WAYLAND_DISPLAY']) if s.env['WAYLAND_DISPLAY'].startswith('/')
                      else s.runtime / s.env['WAYLAND_DISPLAY'])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('pearl', 'ctl'): p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--output', type=Path, default=ROOT / 'artifacts/settings-app/s1/boundary')
    args = p.parse_args()
    for name in ('pearl', 'ctl', 'output'): setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    result = dict(status='running', checks=checks,
                  pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest())
    try:
        with PrivateSession(args.output / 'first') as first, PrivateSession(args.output / 'second') as second:
            app = first.child('pearl', [args.pearl], G_DEBUG='fatal-warnings')
            other = second.child('pearl', [args.pearl], G_DEBUG='fatal-warnings')
            app.expect('event=control-ready'); other.expect('event=control-ready')
            token, display = identity(first)
            token2, display2 = identity(second)
            assert token != token2 and display != display2
            path = first.runtime / 'pearl' / token / 'settings.sock'
            path2 = second.runtime / 'pearl' / token2 / 'settings.sock'
            assert path.parent.stat().st_mode & 0o077 == 0
            with Frontend(path, token, display) as f, Frontend(path2, token2, display2) as g:
                hello = f.call(); hello2 = g.call()
                assert hello['ok'] and hello2['ok'], (hello, hello2)
                state = hello['result']; epoch = state['epoch']
                assert state['session'] == token and state['display'] == display
                assert epoch != hello2['result']['epoch']
                assert all(state['capabilities'][k] for k in ('handshake', 'committed_appearance', 'page_snapshots', 'pearl_draft', 'aqueous_draft', 'live_controls', 'prompts', 'display_preview'))
                assert not any(v for k, v in state['capabilities'].items() if k not in ('handshake', 'committed_appearance', 'page_snapshots', 'pearl_draft', 'aqueous_draft', 'live_controls', 'prompts', 'display_preview'))
                assert f.call()['result']['epoch'] == epoch
                assert g.call()['result']['session'] == token2
            checks['two-process-handshake-persistent-heartbeat-and-capability-gating'] = True
            for overrides, code in [({'session': token2}, 'StaleSession'),
                                    ({'display': display2}, 'DisplayMismatch'),
                                    ({'settings': 2}, 'Version'),
                                    ({'op': 'ping'}, 'HandshakeRequired'),
                                    ({'op': 'preferences_apply'}, 'InvalidRequest'),
                                    ({'extra': 'field'}, 'InvalidRequest')]:
                with Frontend(path, token, display) as f:
                    reply = f.call(**overrides)
                    assert not reply['ok'] and reply['err']['code'] == code, reply
                    assert f.file.read(1) == b''
            checks['cross-session-display-version-and-unimplemented-operation-denial'] = True
            with Frontend(path, token, display) as f:
                assert f.call()['ok']
                assert f.call(id='1')['err']['code'] == 'StaleRequest'
            checks['duplicate-id-denied'] = True
            with Frontend(path, token, display) as f:
                raw = json.dumps(f.request()).encode() + b'\n'
                for i in range(0, len(raw), 7): f.sock.sendall(raw[i:i+7])
                assert json.loads(f.file.readline())['ok']
            for raw in (b'x' * 8193, b'\xff\n', b'\n'):
                with Frontend(path, token, display) as f:
                    f.sock.sendall(raw)
                    assert f.file.read(1) == b''
            checks['fragmented-frames-oversize-invalid-utf8-empty-frame'] = True
            with Frontend(path, token, display) as f:
                start = time.monotonic()
                f.sock.sendall(b'{')
                assert f.file.read(1) == b''
                assert 4 < time.monotonic() - start < 7
            checks['partial-handshake-timeout'] = True
            clients = []
            try:
                for _ in range(8):
                    f = Frontend(path, token, display); clients.append(f)
                    assert f.call()['ok']
                with Frontend(path, token, display) as rejected:
                    assert rejected.file.read(1) == b''
            finally:
                for f in clients: f.close()
            time.sleep(.1)
            with Frontend(path, token, display) as f: assert f.call()['ok']
            checks['eight-client-bound-and-disconnect-slot-reuse'] = True
            before = status(first, args.ctl)
            assert before['popup'] is None
            assert status(second, args.ctl)['popup'] is None
            checks['handshake-does-not-create-popup-or-change-flyout-routing'] = True
            # A frontend connection survives only this backend incarnation.
            f = Frontend(path, token, display); assert f.call()['ok']
            app.proc.kill(); app.proc.wait(timeout=5)
            assert f.file.read(1) == b''; f.close()
            assert path.exists(), 'SIGKILL should leave a stale socket for recovery'
            restart = first.child('pearl-restarted', [args.pearl], G_DEBUG='fatal-warnings')
            restart.expect('event=control-ready')
            with Frontend(path, token, display) as f:
                assert f.call()['result']['epoch'] != epoch
            assert status(second, args.ctl)['popup'] is None
            checks['backend-crash-eof-stale-socket-recovery-new-epoch-session-isolation'] = True
            restart.stop(); other.stop()
            wait_for(lambda: not path.exists() and not path2.exists())
            clean(restart); clean(other)
            checks['graceful-endpoint-cleanup'] = True
        result['status'] = 'passed'
    finally:
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
