#!/usr/bin/env python3
"""Password pre-entry against fake greetd and native GTK in private Aqueous."""
import argparse
import hashlib
import json
from pathlib import Path
import select
import socket
import subprocess
import sys
import threading
import time
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from t00 import Session as T00Session
from test_surfaces import IPC, capture
from test_greeter_ipc import receive, send


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--greeter', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/greeter-login/native')
    args = parser.parse_args()
    (args.output / 'report.json').unlink(missing_ok=True)
    report = {'evidence': 'private native GTK and fake greetd; no real PAM',
              'binary_sha256': hashlib.sha256(args.greeter.read_bytes()).hexdigest(),
              'checks': [], 'screenshots': []}
    with PrivateSession(args.output / 'session') as session:
        session.args = SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous')
        T00Session.input_fixture(session)
        ipc = IPC(session)
        outputs = list(ipc.outputs().values())
        primary, secondary = outputs[0]['name'], outputs[1]['name']
        root = session.base / 'sessions'
        root.mkdir()
        entry = root / 'pearl.desktop'
        (root / 'other.desktop').write_text('[Desktop Entry]\nType=Application\nName=Other desktop\nExec=/usr/bin/true\n')
        config = session.base / 'greeter.json'
        passwd = session.base / 'passwd'
        passwd.write_text('root:x:0:0::/root:/bin/sh\nfixture-user:x:1001:1001::/home/fixture:/bin/sh\nanother-user:x:1002:1002::/home/another:/bin/sh\n')
        empty = session.base / 'empty-passwd'
        empty.write_text('')

        def key(*keys):
            # Thousands of GTK edits take longer than the usual fixture command deadline.
            subprocess.run(['wtype', '-s', '80', *keys, '-s', '80'], env=session.env,
                           cwd=session.base, check=True, capture_output=True, text=True,
                           timeout=60 if any(len(value) > 1024 for value in keys) else 10)
        def back(): key('-M', 'shift', '-k', 'ISO_Left_Tab', '-m', 'shift')
        def snapshot(name):
            capture(session, name, primary)
            report['screenshots'].append('session/' + name + '.png')

        for mode in ('password', 'button', 'repeat-enter', 'remembered', 'remembered-switch', 'remembered-manual', 'remembered-override', 'refresh-user',
                     'switch', 'other', 'empty', 'disabled', 'fingerprint',
                     'blank', 'otp', 'visible', 'refresh', 'desktop-change', 'cancel', 'failure', 'failure-manual', 'stale',
                     'oversize', 'oversize-utf8', 'policy-change', 'changed-before-begin', 'catalog-failure', 'timeout'):
            entry.write_text('[Desktop Entry]\nType=Application\nName=Pearl (Aqueous)\nExec=/usr/bin/true\nDesktopNames=Aqueous;\n')
            value = {'roots': [{'path': str(root), 'type': 'wayland'}], 'power': False,
                     'accounts': mode not in ('disabled', 'remembered-manual', 'failure-manual'),
                     'remember_session': mode.startswith('remembered') or mode == 'refresh-user',
                     'preferred_output': primary,
                     'auth_timeout_seconds': 30,
                     'default_session': 'wayland:pearl.desktop'}
            config.write_text(json.dumps(value))
            state = session.base / 'selections.json'
            state.write_text(json.dumps([{'username': 'another-user' if mode in ('remembered-switch', 'refresh-user') else 'fixture-user',
                                          'session': 'wayland:other.desktop'}]))
            state.chmod(0o600)
            expected_user = 'another-user' if mode in ('switch', 'remembered-switch', 'refresh-user') else 'fixture-user'
            expected_desktop = 'other' if (mode.startswith('remembered') and mode != 'remembered-override') or mode in ('desktop-change', 'refresh-user') else 'pearl'
            server = socket.socket(socket.AF_UNIX)
            path = str(session.base / ('greetd-' + mode + '.sock'))
            server.bind(path); server.listen(); server.settimeout(40 if mode == 'timeout' else 10)
            errors, requests = [], []
            passive_ready, continue_auth, input_ready, second_ready, result_ready, release_result = [threading.Event() for _ in range(6)]

            def daemon(retry=False):
                try:
                    conn, _ = server.accept()
                    with conn:
                        conn.settimeout(10)
                        create = receive(conn); requests.append(create)
                        assert create == {'type': 'create_session', 'username': expected_user}, create
                        for kind in ('info', 'error'):
                            send(conn, {'type': 'auth_message', 'auth_message_type': kind, 'auth_message': 'Touch the reader'})
                            assert receive(conn) == {'type': 'post_auth_message_response', 'response': None}
                        passive_ready.set()
                        assert continue_auth.wait(10)
                        if mode in ('cancel', 'timeout'):
                            cancel, _ = server.accept()
                            with cancel:
                                assert receive(cancel) == {'type': 'cancel_session'}
                                send(cancel, {'type': 'success'})
                            return
                        if mode != 'fingerprint':
                            kind = 'visible' if mode == 'visible' else 'secret'
                            send(conn, {'type': 'auth_message', 'auth_message_type': kind, 'auth_message': 'Fixture response:'})
                            if mode in ('blank', 'visible'):
                                assert not select.select([conn], [], [], .35)[0], 'queued input answered the wrong question'
                                input_ready.set()
                            answer = receive(conn)
                            expected = '' if mode == 'blank' else 'fixture-visible' if mode == 'visible' else 'fixture-secret'
                            assert answer == {'type': 'post_auth_message_response', 'response': expected}, (mode, answer)
                            if mode in ('otp', 'visible'):
                                send(conn, {'type': 'auth_message', 'auth_message_type': 'secret', 'auth_message': 'Verification code:'})
                                assert not select.select([conn], [], [], .35)[0], 'password replayed into another secret question'
                                second_ready.set()
                                assert receive(conn) == {'type': 'post_auth_message_response', 'response': 'fresh-code'}
                        if mode.startswith('failure') and not retry:
                            send(conn, {'type': 'error', 'error_type': 'auth_error', 'description': 'Denied'})
                            cancel, _ = server.accept()
                            with cancel:
                                assert receive(cancel) == {'type': 'cancel_session'}
                                send(cancel, {'type': 'success'})
                            result_ready.set()
                            daemon(retry=True)
                            return
                        send(conn, {'type': 'auth_message', 'auth_message_type': 'info', 'auth_message': 'Authentication complete'})
                        assert receive(conn) == {'type': 'post_auth_message_response', 'response': None}
                        result_ready.set()
                        assert release_result.wait(10)
                        send(conn, {'type': 'success'})
                        if mode == 'stale':
                            cancel, _ = server.accept()
                            with cancel:
                                assert receive(cancel) == {'type': 'cancel_session'}
                                send(cancel, {'type': 'success'})
                            return
                        start = receive(conn); requests.append(start)
                        assert start['type'] == 'start_session' and start['cmd'] == ['/usr/lib/pearl/pearl-greeter-session']
                        assert f'PEARL_SESSION_ID=wayland:{expected_desktop}.desktop' in start['env']
                        send(conn, {'type': 'success'})
                except Exception as error:
                    errors.append(repr(error))

            thread = threading.Thread(target=daemon, daemon=True)
            child = session.child('login-' + mode, [args.greeter.resolve()], GREETD_SOCK=path,
                                  PEARL_TEST_GREETER_CONFIG=str(config),
                                  PEARL_TEST_GREETER_PASSWD=str(empty if mode == 'empty' else passwd),
                                  PEARL_TEST_GREETER_STATE=str(session.base / 'selections.json'),
                                  GTK_A11Y='test', G_DEBUG='fatal-warnings')
            try:
                child.expect('event=greeter-ready')
                if mode in ('oversize', 'oversize-utf8', 'policy-change', 'changed-before-begin', 'catalog-failure'):
                    if mode == 'policy-change':
                        value['password_first'] = False
                        config.write_text(json.dumps(value))
                    if mode == 'changed-before-begin':
                        with entry.open('a') as f: f.write('Comment=changed before authentication\n')
                    if mode == 'catalog-failure': config.write_text('{invalid json')
                    key('a' * 4097 if mode == 'oversize' else 'é' * 2049 if mode == 'oversize-utf8' else 'fixture-secret', '-k', 'Return')
                    # Give catalog revalidation time to finish; no create_session may be sent.
                    assert not select.select([server], [], [], 1)[0], mode
                    assert child.proc.poll() is None, child.lines[-20:]
                    assert not any('event=greeter-state state=connecting' in line for line in child.lines)
                    snapshot('login-' + mode)
                    report['checks'].append(mode)
                    continue
                thread.start()
                if mode in ('switch', 'other', 'remembered-switch'):
                    key('discard-on-user-change'); back(); key('-k', 'space')
                    snapshot('login-' + mode + '-menu')
                    key('-k', 'Down', *(['-k', 'Down'] if mode == 'other' else []), '-k', 'Return')
                    child.expect('selected=' + ('2 manual=true' if mode == 'other' else '1 manual=false'))
                    if mode == 'other': snapshot('login-other-user')
                if mode in ('other', 'empty', 'disabled', 'remembered-manual', 'failure-manual'):
                    assert [line for line in child.lines if 'event=greeter-form' in line][-1].endswith('ready=false')
                    key('fixture-user', '-k', 'Tab')
                    wait_for(lambda: [line for line in child.lines if 'event=greeter-form' in line][-1].endswith('ready=true'))
                if mode.startswith('remembered'):
                    # Verify the displayed selection BEFORE submission, not just the launch.
                    wait_for(lambda: [line for line in child.lines if 'event=greeter-selection' in line][-1].endswith('desktop=wayland:other.desktop'))
                    snapshot('login-' + mode)
                if mode == 'remembered-override':
                    key('-k', 'Tab', '-k', 'space', '-k', 'End', '-k', 'Return')
                    back()
                    assert [line for line in child.lines if 'event=greeter-selection' in line][-1].endswith('desktop=wayland:pearl.desktop')
                if mode == 'refresh-user':
                    # Explicit selection belongs to the old account. Removing it
                    # during refresh must apply the replacement user's preference.
                    key('-k', 'Tab', '-k', 'space', '-k', 'Home', '-k', 'Return')
                    key('-k', 'space', '-k', 'End', '-k', 'Return')
                    passwd.write_text('another-user:x:1002:1002::/home/another:/bin/sh\n')
                    key('-k', 'Tab', '-k', 'space')
                    wait_for(lambda: sum('event=greeter-ready' in line for line in child.lines) == 2)
                    assert [line for line in child.lines if 'event=greeter-selection' in line][-1].endswith('desktop=wayland:other.desktop')
                    passwd.write_text('fixture-user:x:1001:1001::/home/fixture:/bin/sh\nanother-user:x:1002:1002::/home/another:/bin/sh\n')
                if mode == 'refresh':
                    key('discard-on-refresh', '-k', 'Tab', '-k', 'Tab', '-k', 'space')
                    wait_for(lambda: sum('event=greeter-ready' in line for line in child.lines) == 2)
                if mode == 'desktop-change':
                    # Choose a different desktop after typing; the password must survive.
                    key('fixture-secret', '-k', 'Tab', '-k', 'space', '-k', 'Home', '-k', 'Return')
                    back()
                if mode == 'password': snapshot('login-initial')
                if mode not in ('blank', 'desktop-change'): key('fixture-secret')
                # One Enter creates the session and later supplies the first secret answer.
                if mode == 'button':
                    key('-k', 'Tab', '-k', 'Tab', '-k', 'Tab', '-k', 'space')
                else:
                    key('-k', 'Return')
                assert passive_ready.wait(5), (mode, errors, child.lines[-12:])
                if mode == 'repeat-enter':
                    key('-k', 'Return', '-k', 'Return', '-k', 'Return')
                    assert not select.select([server], [], [], .2)[0], 'duplicate attempt'
                if mode == 'password':
                    # A pending password survives moving the single card between outputs.
                    session.run(['wlr-randr', '--output', primary, '--off'])
                    session.run(['wlr-randr', '--output', primary, '--on'])
                    time.sleep(.2)
                if mode in ('cancel', 'timeout'):
                    if mode == 'cancel': key('-k', 'Escape')
                    continue_auth.set()
                    assert child.wait(timeout=40) != 0
                else:
                    continue_auth.set()
                    if mode in ('blank', 'visible'):
                        assert input_ready.wait(5), (mode, errors)
                        key(*(['fixture-visible'] if mode == 'visible' else []), '-k', 'Return')
                    if mode in ('otp', 'visible'):
                        assert second_ready.wait(5), (mode, errors)
                        snapshot('login-' + mode + '-additional-prompt')
                        key('fresh-code', '-k', 'Return')
                    assert result_ready.wait(5), (mode, errors, child.lines[-12:])
                    if mode.startswith('failure'):
                        child.expect('event=greeter-state state=idle')
                        snapshot('login-' + mode)
                        result_ready.clear()
                        key('fixture-secret', '-k', 'Return')
                        assert result_ready.wait(5), (mode, errors, child.lines[-12:])
                        release_result.set()
                        assert child.wait() == 0, child.lines[-20:]
                    else:
                        if mode == 'stale':
                            with entry.open('a') as f: f.write('Comment=changed after authentication\n')
                        release_result.set()
                        if mode == 'stale':
                            child.expect('event=greeter-state state=idle'); child.stop()
                        else: assert child.wait() == 0, child.lines[-20:]
                thread.join(3)
                assert not thread.is_alive() and not errors, (mode, errors)
                assert len(requests) == (3 if mode.startswith('failure') else 1 if mode in ('cancel', 'timeout', 'stale') else 2), requests
                assert not any(secret in line for line in child.lines for secret in ('fixture-secret', 'fresh-code', 'discard-on-'))
                report['checks'].append(mode)
            finally:
                continue_auth.set(); release_result.set()
                child.stop(); server.close()
        ipc.close()
    args.output.mkdir(parents=True, exist_ok=True)
    report['status'] = 'passed'
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
