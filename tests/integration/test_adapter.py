#!/usr/bin/env python3
"""Real GIO sockets against a scripted IPC peer, then an isolated nested Aqueous."""
import argparse
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from contextlib import contextmanager

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
FIXTURES = ROOT / 'tests/fixtures/aqueous'
HELLO = json.loads((FIXTURES / 'hello-response.json').read_text())['result']
SNAPSHOT = json.loads((FIXTURES / 'desktop-event.json').read_text())
WINDOW = '18446744073709551615'
ICON = dict(id=WINDOW, revision=WINDOW, size=1, scale=1)


class Peer:
    def __init__(self, sock):
        self.sock, self.buffer = sock, b''
        self.requests = []

    def recv(self, timeout=3):
        deadline = time.monotonic() + timeout
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([self.sock], [], [], remaining)[0], 'no request received'
            data = self.sock.recv(65536)
            assert data, 'unexpected EOF'
            self.buffer += data
        line, self.buffer = self.buffer.split(b'\n', 1)
        value = json.loads(line)
        assert isinstance(value['id'], str)
        if self.requests:
            assert int(value['id']) > int(self.requests[-1]['id'])
        self.requests.append(value)
        return value

    def send(self, value, fragment=0):
        data = json.dumps(value, separators=(',', ':')).encode() + b'\n'
        for offset in range(0, len(data), fragment or len(data)):
            self.sock.sendall(data[offset:offset + (fragment or len(data))])

    def reply(self, request, result, **kw):
        self.send(dict(ipc=1, id=request['id'], ok=True, result=result), **kw)

    def quiet(self, duration=.15):
        assert not self.buffer and not select.select([self.sock], [], [], duration)[0], 'unexpected periodic/pipelined traffic'

    def close(self):
        self.sock.close()


class Probe:
    def __init__(self, binary, env, log):
        self.lines, self.log = [], log
        self.proc = subprocess.Popen([str(binary)], env={**env, 'G_DEBUG': 'fatal-warnings'}, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        def read():
            for line in self.proc.stdout:
                self.lines.append(line.rstrip())
        self.thread = threading.Thread(target=read, daemon=True)
        self.thread.start()

    def send(self, **value):
        self.proc.stdin.write(json.dumps(value) + '\n')
        self.proc.stdin.flush()

    def expect(self, text, count=1, timeout=4):
        try:
            wait_for(lambda: sum(text in line for line in self.lines) >= count or self.proc.poll() is not None, timeout)
            assert sum(text in line for line in self.lines) >= count
        except (AssertionError, TimeoutError):
            raise AssertionError(f'waiting for {text!r} #{count}:\n' + '\n'.join(self.lines))

    def close(self):
        try:
            if self.proc.poll() is None:
                self.send(quit=True)
            assert self.proc.wait(timeout=4) == 0, self.lines
            self.thread.join(1)
            assert not any(x in line for line in self.lines for x in ('CRITICAL', 'WARNING', 'panic:', 'leaked')), self.lines
        finally:
            if self.proc.poll() is None:
                self.proc.kill()
                self.proc.wait()
            self.log.parent.mkdir(parents=True, exist_ok=True)
            self.log.write_text('\n'.join(self.lines) + '\n')
            self.proc.stdin.close()
            self.proc.stdout.close()


class Server:
    def __init__(self, binary, root, log, **env):
        self.path = root / 'aqueous/test/ipc.sock'
        self.path.parent.mkdir(parents=True)
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(self.path))
        self.listener.listen(8)
        self.listener.settimeout(4)
        self.peers = []
        self.probe = Probe(binary, {**os.environ, 'XDG_RUNTIME_DIR': str(root), 'AQUEOUS_SOCKET': str(self.path), **env}, log)

    def pair(self, hello=None, mismatch=False, fragment=0):
        peers = [Peer(self.listener.accept()[0]) for _ in range(2)]
        self.peers.extend(peers)
        for i, peer in enumerate(peers):
            req = peer.recv()
            assert req['op'] == 'hello' and req['params'] == {}
            h = copy.deepcopy(hello or HELLO)
            if mismatch and i == 1:
                h['session'] = 'a' * 32
            peer.reply(req, h, fragment=fragment)
        if mismatch:
            return peers
        readable = select.select([p.sock for p in peers], [], [], 3)[0]
        assert len(readable) == 1, 'expected exactly one subscribe'
        self.ev = next(p for p in peers if p.sock == readable[0])
        self.req = next(p for p in peers if p != self.ev)
        request = self.ev.recv()
        assert request['op'] == 'subscribe' and request['session'] == (hello or HELLO)['session']
        return request

    def ready(self, snapshot=None, hello=None, fragment=0):
        subscribe = self.pair(hello=hello, fragment=fragment)
        self.ev.reply(subscribe, dict(subscribed=True), fragment=fragment)
        state = copy.deepcopy(snapshot or SNAPSHOT)
        state['batch']['session'] = (hello or HELLO)['session']
        self.ev.send(state, fragment=fragment)
        ack = self.ev.recv()
        assert ack['op'] == 'ack' and ack['params'] == {'delivery': '1'}
        self.ev.reply(ack, dict(acked='1'), fragment=fragment)
        self.probe.expect('availability=ready')

    def delta(self, upsert=(), removed=(), base='1', sequence='2', delivery='2'):
        value = copy.deepcopy(SNAPSHOT)
        value['delivery'] = delivery
        value['batch'].update(type='delta', base_sequence=base, sequence=sequence, upsert=list(upsert), removed=list(removed))
        self.ev.send(value)

    def ack(self, delivery='2'):
        ack = self.ev.recv()
        assert ack['op'] == 'ack' and ack['params']['delivery'] == delivery
        self.ev.reply(ack, dict(acked=delivery))

    def close(self):
        self.probe.close()
        for p in self.peers:
            p.close()
        self.listener.close()


def entity(kind):
    return copy.deepcopy(next(e for e in SNAPSHOT['batch']['upsert'] if e['kind'] == kind))


def png(edge=1, extra=b''):
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    rgba = bytes((i * 73 + i // 4) % 256 for i in range(edge * edge * 4))
    def paeth(a, b, c):
        p = a + b - c
        return min((a, b, c), key=lambda n: abs(p - n))
    filtered = bytearray()
    for y in range(edge):
        f = y % 5
        filtered.append(f)
        for x in range(edge * 4):
            left = rgba[y * edge * 4 + x - 4] if x >= 4 else 0
            up = rgba[(y - 1) * edge * 4 + x] if y else 0
            corner = rgba[(y - 1) * edge * 4 + x - 4] if y and x >= 4 else 0
            predictor = (0, left, up, (left + up) // 2, paeth(left, up, corner))[f]
            filtered.append((rgba[y * edge * 4 + x] - predictor) % 256)
    data = zlib.compress(filtered + extra)
    image = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', edge, edge, 8, 6, 0, 0, 0))
    # libpng's simplified encoder writes sRGB; metadata is never expanded by Pearl.
    image += chunk(b'sRGB', b'\0')
    image += chunk(b'IDAT', data[:len(data)//2]) + chunk(b'IDAT', data[len(data)//2:]) + chunk(b'IEND', b'')
    return image, rgba


def fake_tests(binary, output, checks):
    @contextmanager
    def case(name, **env):
        with tempfile.TemporaryDirectory(prefix='pearl-ipc-') as tmp:
            server = Server(binary, Path(tmp), output / f'{name}.log', **env)
            try:
                yield server
                checks[name] = True
                print('PASS', name, flush=True)
            finally:
                server.close()

    with case('fragmentation-idle-priority', PEARL_PROBE_WRITE_CHUNK='3') as s:
        s.ready(fragment=7)
        s.req.quiet(1)
        s.ev.quiet(1)
        s.probe.send(metrics=True)
        s.probe.expect('metrics=timer:false,queued:0,cache:0,ready:true')
        # Queue icon and mutation in the same input callback; mutation must win.
        s.probe.send(icon=ICON, action={'workspace_rename': {'id': '1', 'name': 'Desk 🐟'}})
        request = s.req.recv()
        assert request['op'] == 'command' and request['params'] == dict(action='workspace.rename', fields=dict(id='1', name='Desk 🐟'))
        s.req.quiet()
        s.req.reply(request, dict(status='applied', sequence='9'))
        s.probe.expect('completion=1:applied::9')
        assert not any('state=9:' in x for x in s.probe.lines), 'optimistic model mutation'
        request = s.req.recv()
        assert request['op'] == 'window.icon' and request['params'] == ICON
        s.req.reply(request, dict(revision=WINDOW, width=1, height=1, format='png', data=base64.b64encode(png()[0]).decode()))
        s.probe.expect('icons')
        s.probe.send(icon=ICON)
        s.probe.expect('icon-hit=true')
        s.req.quiet()
        s.probe.send(action={'window_close': {'id': WINDOW}})
        request = s.req.recv()
        s.req.reply(request, dict(status='accepted', sequence='9'))
        s.probe.expect('completion=2:accepted::9')

    with case('png-filters-bounds-and-negative-cache') as s:
        s.ready()
        key = {**ICON, 'size': 5}
        s.probe.send(icon=key)
        req = s.req.recv()
        image, rgba = png(5)
        s.req.reply(req, dict(revision=WINDOW, width=5, height=5, format='png', data=base64.b64encode(image).decode()))
        s.probe.expect('icons')
        s.probe.send(icon=key)
        s.probe.expect(f'pixel-crc={zlib.crc32(rgba):x}')
        key = {**ICON, 'size': 6}
        s.probe.send(icon=key)
        req = s.req.recv()
        image, _ = png(6, b'x' * 1000000)
        s.req.reply(req, dict(revision=WINDOW, width=6, height=6, format='png', data=base64.b64encode(image).decode()))
        s.probe.expect('icons', count=2)
        s.probe.send(icon=key)
        s.probe.expect('icon-hit=false', count=3)
        s.req.quiet()

    with case('server-rejections-and-negotiated-request-limit') as s:
        hello = copy.deepcopy(HELLO)
        hello['max_request_bytes'] = 160
        s.ready(hello=hello)
        s.probe.send(icon=ICON)
        s.probe.expect('icons')
        s.req.quiet()
        s.probe.send(action={'workspace_rename': {'id': '1', 'name': 'x' * 512}})
        s.probe.expect('completion=1:rejected:RequestTooLarge')
        s.probe.send(action={'workspace_activate': {'id': '1'}}, count=2)
        req = s.req.recv()
        s.req.send(dict(ipc=1, id=req['id'], ok=False, error=dict(code='busy', message='Try later')))
        s.probe.expect('completion=2:rejected:busy')
        req = s.req.recv()
        s.req.send(dict(ipc=1, id=req['id'], ok=False, error=dict(code='stale_session', message='Session changed')))
        s.probe.expect('completion=3:rejected:stale_session')
        s.probe.expect('fault=SessionChanged')
        assert not any(':unknown:' in line for line in s.probe.lines)

    with case('bounded-queue-unknown-restart') as s:
        s.ready()
        s.probe.send(action={'workspace_activate': {'id': '1'}}, count=40)
        first = s.req.recv()
        assert first['op'] == 'command'
        s.probe.expect('enqueue-error=QueueFull', count=8)
        s.req.quiet()
        s.req.close()
        s.probe.expect('completion=1:unknown')
        s.probe.expect('completion=32:dropped')
        s.probe.expect('availability=reconnecting')
        hello = copy.deepcopy(HELLO)
        hello['session'] = 'b' * 32
        s.ready(hello=hello)
        s.probe.expect('availability=ready', count=2)
        s.req.quiet(.5)
        s.ev.quiet(.5)
        assert sum('completion=' in x for x in s.probe.lines) == 32

    with case('invalid-ack') as s:
        sub = s.pair()
        s.ev.reply(sub, dict(subscribed=True))
        s.ev.send(SNAPSHOT)
        ack = s.ev.recv()
        s.ev.reply(ack, dict(acked='01'))
        s.probe.expect('fault=InvalidAck')
        assert 'availability=ready' not in s.probe.lines

    with case('invalid-sequence') as s:
        s.ready()
        s.delta(base='999')
        s.probe.expect('fault=SequenceGap')
        assert not any('state=2:' in x for x in s.probe.lines)

    with case('session-mismatch') as s:
        s.pair(mismatch=True)
        s.probe.expect('fault=SessionChanged')

    with case('reply-id-mismatch') as s:
        s.ready()
        s.probe.send(action={'session_exit': {}})
        req = s.req.recv()
        req['id'] = '999'
        s.req.reply(req, dict(status='accepted', sequence='1'))
        s.probe.expect('fault=ResponseId')
        s.probe.expect('completion=1:unknown')

    with case('invalid-accepted') as s:
        s.ready()
        s.probe.send(action={'workspace_activate': {'id': '1'}})
        req = s.req.recv()
        s.req.reply(req, dict(status='accepted', sequence='1'))
        s.probe.expect('fault=InvalidCompletion')
        s.probe.expect('completion=1:unknown')

    with case('subscribe-order') as s:
        s.pair()
        s.ev.send(SNAPSHOT)
        s.probe.expect('fault=UnexpectedEvent')

    with case('command-timeout', PEARL_PROBE_DEADLINE_MS='250') as s:
        s.ready()
        s.probe.send(action={'workspace_activate': {'id': '1'}})
        s.req.recv()
        s.probe.expect('fault=RequestTimeout')
        s.probe.expect('completion=1:unknown')

    with case('socket-backpressure', PEARL_PROBE_DEADLINE_MS='500', PEARL_PROBE_WRITE_CHUNK='128', PEARL_PROBE_SEND_BUFFER='1024') as s:
        s.ready()
        s.probe.send(action={'workspace_rename': {'id': '1', 'name': '\x01' * 1024}})
        # Leave the request unread: the small kernel send buffer must fill.
        s.probe.expect('completion=1:unknown:RequestTimeout')
        partial = b''
        while True:
            part = s.req.sock.recv(8192)
            if not part:
                break
            partial += part
        assert 0 < len(partial) < 6144 and b'\n' not in partial, len(partial)

    with case('subscription-timeout', PEARL_PROBE_DEADLINE_MS='500', PEARL_PROBE_SUBSCRIPTION_MS='250') as s:
        sub = s.pair()
        s.ev.reply(sub, dict(subscribed=True))
        s.probe.expect('fault=SubscriptionTimeout')

    with case('hello-timeout', PEARL_PROBE_DEADLINE_MS='250') as s:
        peer = Peer(s.listener.accept()[0])
        s.peers.append(peer)
        assert peer.recv()['op'] == 'hello'
        s.probe.expect('fault=RequestTimeout')

    with case('locked-revalidation') as s:
        s.ready()
        s.probe.send(action={'workspace_activate': {'id': '1'}}, count=2)
        req = s.req.recv()
        session = entity('session')
        session['locked'] = True
        s.delta(upsert=[session])
        s.ack()
        s.probe.expect('state=2:')
        s.req.reply(req, dict(status='applied', sequence='1'))
        s.probe.expect('completion=2:rejected:Locked')
        s.probe.send(action={'session_exit': {}})
        s.probe.send(icon=ICON)
        s.probe.expect('enqueue-error=Locked')
        s.probe.expect('icon-error=Locked')
        s.req.quiet()

    with case('restricted-capabilities') as s:
        hello = copy.deepcopy(HELLO)
        hello['capabilities']['commands'] = False
        s.ready(hello=hello)
        s.probe.send(action={'workspace_activate': {'id': '1'}})
        s.probe.expect('enqueue-error=Unsupported')
        s.req.quiet()

    with case('ambiguous-seat') as s:
        state = copy.deepcopy(SNAPSHOT)
        second = entity('seat')
        second.update(id='second', window=None, keyboard=None, focus_kind='none')
        state['batch']['upsert'].append(second)
        next(e for e in state['batch']['upsert'] if e['kind'] == 'session')['default_seat'] = None
        s.ready(snapshot=state)
        s.probe.send(action={'workspace_activate': {'id': '1'}})
        s.probe.expect('enqueue-error=AmbiguousSeat')
        s.probe.send(action={'workspace_activate': {'id': '1', 'seat': 'second'}})
        req = s.req.recv()
        assert req['params']['fields']['seat'] == 'second'
        s.req.reply(req, dict(status='applied', sequence='1'))
        s.probe.expect('completion=1:applied')

    with case('target-disappearance') as s:
        s.ready()
        s.probe.send(action={'window_close': {'id': WINDOW}}, count=2)
        req = s.req.recv()
        seat = entity('seat')
        seat.update(window=None, focus_kind='none')
        s.delta(upsert=[seat], removed=['window:' + WINDOW])
        s.ack()
        s.probe.expect('state=2:24')
        s.req.reply(req, dict(status='accepted', sequence='1'))
        s.probe.expect('completion=2:rejected:NotFound')
        s.req.quiet()

    with case('stale-icon') as s:
        s.ready()
        s.probe.send(icon=ICON)
        req = s.req.recv()
        window = entity('window')
        window['icon']['revision'] = '2'
        s.delta(upsert=[window])
        s.ack()
        s.probe.expect('state=2:')
        s.req.reply(req, dict(revision=WINDOW, width=1, height=1, format='png', data=base64.b64encode(png()[0]).decode()))
        s.probe.send(icon=ICON)
        s.probe.expect('icon-error=StaleIcon')
        s.req.quiet()


def real_tests(binary, output, checks):
    with PrivateSession(output / 'parent') as parent:
        with PrivateSession(output / 'nested', backend='nested', parent_display=parent.display_path, inherited=parent.env) as session:
            probe = Probe(binary, session.env, output / 'real-nested.log')
            try:
                probe.expect('availability=ready')
                # Query IDs only through the private endpoint; repeated workspace numbers
                # across the two outputs are deliberately not treated as identity.
                sock = socket.socket(socket.AF_UNIX)
                sock.connect(session.env['AQUEOUS_SOCKET'])
                peer = Peer(sock)
                peer.send(dict(ipc=1, id='1', op='hello', params={}))
                hello = peer.recv()['result']
                peer.send(dict(ipc=1, id='2', session=hello['session'], op='snapshot', params={}))
                snapshot = peer.recv()['result']['batch']
                workspace = next(e for e in snapshot['upsert'] if e['kind'] == 'workspace')
                probe.send(action={'workspace_rename': {'id': workspace['id'], 'name': 'Pearl T04 🐟'}})
                probe.expect('completion=1:applied:')
                probe.send(action={'workspace_activate': {'id': workspace['id']}})
                probe.expect('completion=2:applied:')
                probe.send(action={'session_reload': {}})
                probe.expect('completion=3:applied:')
                time.sleep(.5)
                probe.send(metrics=True)
                probe.expect('metrics=timer:false,queued:0,cache:0,ready:true')
                peer.send(dict(ipc=1, id='3', session=hello['session'], op='snapshot', params={}))
                updated = peer.recv()['result']['batch']
                assert next(e for e in updated['upsert'] if e['kind'] == 'workspace' and e['id'] == workspace['id'])['name'] == 'Pearl T04 🐟'
                peer.close()
                checks['real-nested-commands-and-idle'] = True
                print('PASS real-nested-commands-and-idle', flush=True)
                probe.send(action={'session_exit': {}})
                probe.expect('completion=4:accepted:')
                probe.expect('availability=reconnecting')
                assert session.compositor.wait() == 0
                # A replacement compositor advertises a new endpoint. The old adapter
                # must keep its inherited endpoint and require relaunch, never scan.
                with PrivateSession(output / 'replacement', backend='nested', parent_display=parent.display_path, inherited=parent.env) as replacement:
                    assert replacement.env['AQUEOUS_SOCKET'] != session.env['AQUEOUS_SOCKET']
                    time.sleep(1)
                    assert sum('availability=ready' == line for line in probe.lines) == 1
                    probe.send(metrics=True)
                    probe.expect('ready:false')
                checks['real-exit-and-new-endpoint-isolation'] = True
                print('PASS real-exit-and-new-endpoint-isolation', flush=True)
            finally:
                probe.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/t04/latest')
    parser.add_argument('--fake-only', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    result = dict(status='running', executable_sha256=hashlib.sha256(args.probe.read_bytes()).hexdigest(), checks=checks)
    try:
        fake_tests(args.probe.resolve(), args.output, checks)
        if not args.fake_only:
            real_tests(args.probe.resolve(), args.output, checks)
        result['status'] = 'passed'
    finally:
        (args.output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
