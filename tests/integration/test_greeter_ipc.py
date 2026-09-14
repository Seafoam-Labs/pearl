#!/usr/bin/env python3
"""Adversarial private greetd sockets. No PAM, seat or real login access."""
import argparse
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]


def receive(s):
    def exact(n):
        data = b''
        while len(data) < n:
            part = s.recv(n-len(data))
            if not part:
                raise EOFError()
            data += part
        return data
    n = struct.unpack('=I', exact(4))[0]
    assert 0 < n <= 65536
    return json.loads(exact(n))


def send(s, value, fragmented=False):
    body = json.dumps(value).encode()
    frame = struct.pack('=I', len(body)) + body
    if fragmented:
        for byte in frame:
            s.sendall(bytes([byte]))
    else:
        s.sendall(frame)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--greeter', type=Path, required=True)
    args = parser.parse_args()
    checks = []
    for mode in ('conversation', 'cancel', 'denied', 'huge', 'truncated', 'duplicate', 'alias', 'bad_utf8', 'unsolicited', 'lost_start', 'blocked', 'cancel_blocked'):
        with tempfile.TemporaryDirectory(prefix='pearl-greetd-') as tmp:
            server = socket.socket(socket.AF_UNIX)
            server.bind(tmp+'/greetd.sock'); server.listen(); server.settimeout(10)
            errors = []
            starts = []
            def daemon():
                try:
                    conn, _ = server.accept()
                    with conn:
                        conn.settimeout(10)
                        assert receive(conn) == {'type':'create_session', 'username':'fixture-user'}
                        if mode == 'huge': conn.sendall(struct.pack('=I', 65537)); return
                        if mode == 'truncated': conn.sendall(struct.pack('=I', 20)+b'{'); return
                        if mode in ('duplicate', 'bad_utf8'):
                            body = b'{"type":"success","type":"success"}' if mode == 'duplicate' else b'\xff'
                            conn.sendall(struct.pack('=I',len(body))+body); return
                        if mode == 'alias':
                            send(conn, {'type':'auth_message','message_type':'secret','message':'Password'}); return
                        if mode in ('blocked', 'cancel_blocked'):
                            second, _ = server.accept()
                            with second:
                                assert receive(second) == {'type':'cancel_session'}
                                if mode == 'blocked': send(second, {'type':'success'})
                                else:
                                    # A second socket must not extend cancellation indefinitely.
                                    assert second.recv(1) == b''
                            return
                        if mode == 'denied':
                            send(conn, {'type':'error','error_type':'auth_error','description':'Denied'})
                        else:
                            for kind, response in [('visible','fixture-user'),('secret','fixture-secret'),('info',None),('error',None)]:
                                send(conn, {'type':'auth_message','auth_message_type':kind,'auth_message':'Fixture prompt'}, fragmented=True)
                                if mode == 'cancel': break
                                assert receive(conn) == {'type':'post_auth_message_response','response':response}
                        if mode in ('denied','cancel'):
                            second, _ = server.accept()
                            with second:
                                assert receive(second) == {'type':'cancel_session'}
                                send(second, {'type':'success'})
                            return
                        send(conn, {'type':'success'})
                        start = receive(conn); starts.append(start)
                        assert start['cmd'] == ['/usr/lib/pearl/pearl-greeter-session'] and start['type'] == 'start_session'
                        if mode == 'unsolicited': send(conn, {'type':'auth_message','auth_message_type':'secret','auth_message':'Late prompt'})
                        elif mode != 'lost_start': send(conn, {'type':'success'})
                except Exception as e:
                    errors.append(e)
            thread = threading.Thread(target=daemon, daemon=True); thread.start()
            env = dict(os.environ, GREETD_SOCK=tmp+'/greetd.sock')
            if mode == 'cancel': env['PEARL_TEST_GREETER_CANCEL']='1'
            child = subprocess.run([str(args.greeter.resolve()), '--probe'], env=env, capture_output=True, text=True, timeout=12)
            thread.join(11); server.close()
            assert not thread.is_alive(), mode
            assert not errors, (mode, errors, child.stderr)
            success = mode in ('conversation','cancel','lost_start','unsolicited')
            assert (child.returncode == 0) == success, (mode, child.returncode, child.stderr)
            if mode in ('blocked','cancel_blocked'):assert 'state=unavailable' in child.stderr and 'state=idle' not in child.stderr
            assert len(starts) <= 1
            assert 'fixture-secret' not in child.stdout + child.stderr
            checks.append(mode)
    print(json.dumps({'status':'passed', 'evidence':'private mock daemon only', 'checks':checks}))


if __name__ == '__main__': main()
