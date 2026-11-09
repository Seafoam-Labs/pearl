#!/usr/bin/env python3
"""Native M1 recovery acceptance. Build with zig build -Dtest-hooks=true.
Uses real GTK input and SIGKILL, never an in-process recovery simulation.
"""
import argparse
import base64
import fcntl
import hashlib
import json
import os
import signal
import sys
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
PEARL = PROJECT.parents[1]
sys.path[:0] = [str(PEARL / 'scripts'), str(PEARL / 'tests/integration')]
from pearl_session import PrivateSession, wait_for, fixture_prefix
from test_surfaces import IPC


def manifest(path):
    raw = path.read_bytes()
    magic, digest, body = raw.split(b'\n', 2)
    assert magic in (b'CORAL-RECOVERY 1', b'CORAL-RECOVERY 2')
    assert hashlib.sha256(body).hexdigest().encode() == digest
    return json.loads(body)


def locked(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-app-recovery')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    checks = []
    report = {'status': 'running', 'checks': checks, 'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest()}
    try:
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8')
            ipc = IPC(session)
            fixtures = Path(session.env['XDG_CONFIG_HOME']) / 'recovery-fixtures'
            fixtures.mkdir()
            state = Path(session.env['XDG_STATE_HOME'])
            root = state / 'coral/recovery'
            command_path = fixtures / 'command.ini'
            session.env['CORAL_TEST_COMMAND'] = str(command_path)
            app = None
            serial = 0

            def windows():
                return [w for w in ipc.state() if w['kind'] == 'window' and w.get('app_id') == 'org.aqueous.Coral']

            def key(name, *mods):
                cmd = ['wtype', '-s', '40']
                for mod in mods:
                    cmd += ['-M', mod]
                cmd += ['-k', name]
                for mod in reversed(mods):
                    cmd += ['-m', mod]
                session.run(cmd)

            def command(action, value=None, **fields):
                start = len(app.lines)
                content = '[Test]\naction=' + action + '\n'
                if value is not None:
                    content += 'value=' + str(value).replace('\\', '\\\\').replace('\n', '\\n') + '\n'
                content += ''.join(f'{k}={v}\n' for k, v in fields.items())
                command_path.write_text(content)
                key('F11')
                last_sent = time.monotonic()
                def completed():
                    nonlocal last_sent
                    if any('CORAL_COMMAND_DONE' in line for line in app.lines[start:]):
                        return True
                    assert app.proc.poll() is None, app.lines[-30:]
                    # A newly mapped modal briefly has no keyboard focus. Only
                    # retry read-only probes, never a mutating command.
                    if action == 'workspace-probe' and time.monotonic() - last_sent > .25:
                        key('F11')
                        last_sent = time.monotonic()
                    return False
                wait_for(completed)
                return app.lines[start:]

            def probe():
                assert app.proc.poll() is None, app.lines[-30:]
                lines = command('workspace-probe')
                return json.loads(next(line.removeprefix('CORAL_WORKSPACE ') for line in lines if line.startswith('CORAL_WORKSPACE ')))

            def launch(*paths, prompt=None, **env):
                nonlocal app, serial
                serial += 1
                existing = {w['id'] for w in windows()}
                app = session.child(f'coral-recovery-{serial}', [args.binary.resolve(), *paths], G_DEBUG='fatal-criticals', **env)
                window = wait_for(lambda: next((w for w in windows() if w['id'] not in existing), None))
                ipc.call('command', action='window.activate', fields={'id': window['id']})
                if prompt:
                    app.expect('CORAL_RECOVERY_PROMPT ' + prompt)
                    wait_for(lambda: any(w.get('title') in ('Recover interrupted session', 'Recovery copied safely') for w in windows()))
                else:
                    wait_for(lambda: len(probe()['documents']) > 0)
                return app

            def choose(key_name, after=None):
                # Hooks drive the actual GtkDialog response, not a second restore path.
                time.sleep(.15)
                key(key_name)
                if after:
                    app.expect('CORAL_RECOVERY_PROMPT ' + after)
                else:
                    wait_for(lambda: not any(w.get('title') in ('Recover interrupted session', 'Recovery copied safely') for w in windows()))
                    time.sleep(.1)

            def kill():
                app.signal(signal.SIGKILL)
                assert app.wait() == -signal.SIGKILL
                wait_for(lambda: not windows())

            def close():
                count = len(windows())
                before = probe()
                key('q', 'ctrl')
                for _ in range(sum(d['dirty'] for d in before['documents'])):
                    # Probe is read-only; the test hook is also installed on App dialogs.
                    wait_for(lambda: probe()['dialog'])
                    command('respond', response=1)
                assert app.wait(timeout=15) == 0, app.lines[-40:]
                assert not any('CRITICAL' in line or 'panic:' in line for line in app.lines), app.lines[-40:]
                wait_for(lambda: len(windows()) < count)

            def checkpoint(predicate=lambda value: True):
                def find():
                    for path in root.glob('*/manifest'):
                        try:
                            value = manifest(path)
                            if locked(path.parent) and predicate(value):
                                return path
                        except (FileNotFoundError, ValueError, AssertionError):
                            pass
                    return None
                return wait_for(find, timeout=20)

            def passed(label):
                checks.append(label)
                print('PASS', label, flush=True)

            missing = state / 'not-created'
            launch(XDG_STATE_HOME=str(missing))
            app.expect('CORAL_RECOVERY_ERROR MissingStateHome')
            assert not missing.exists()
            close()
            passed('Missing state home is surfaced, not silently created or bypassed')

            root.parent.mkdir(mode=0o700)
            root.mkdir(mode=0o700)
            empty_stale = root / ('s-' + '0' * 34)
            empty_stale.mkdir(mode=0o700)
            launch()
            assert not empty_stale.exists()
            assert not any('CORAL_RECOVERY_PROMPT' in line or 'NoCheckpoint' in line for line in app.lines)
            close()
            passed('An exclusively claimed empty stale session is cleaned without an unreadable-journal prompt')

            sample = fixtures / 'notes.txt'
            original = 'α first\nβ second\n' + ''.join(f'Line {n}\n' for n in range(180))
            sample.write_bytes(b'\xef\xbb\xbf' + original.replace('\n', '\r\n', 1).encode())
            launch(sample)
            wait_for(lambda: probe()['documents'][0]['text'] == original)
            command('select', start=2, end=2)
            command('insert', 'Ω dirty ')
            edited = original[:2] + 'Ω dirty ' + original[2:]
            command('split-group')
            command('select', start=9, end=3)
            command('scroll', y=400)
            key('n', 'ctrl')
            scratch = 'Untitled recovery α😀\nDo not lose me.'
            command('insert', scratch)
            command('select', start=5, end=2)
            command('focus-group', index=0)
            command('select', start=4, end=1)
            command('scroll', y=240)
            before = probe()
            old = checkpoint(lambda value: len(value['documents']) == 2 and len(value['views']) == 3 and any(base64.b64decode(d['text']).decode() == scratch for d in value['documents']))
            # Wait through trailing debounce so selection/scroll, not only text, is persisted.
            time.sleep(.7)
            saved = manifest(old)
            assert len(saved['groups']) == 2 and saved['active_group'] == 'root/0', saved
            assert any(v['scroll_line'] > 0 for v in saved['views']), saved
            assert locked(old.parent)
            assert saved['documents'][0]['bom'] and saved['documents'][0]['newline'] == 'mixed'
            assert old.stat().st_mode & 0o777 == 0o600
            assert old.parent.stat().st_mode & 0o777 == 0o700
            primary = app
            primary_window = windows()[0]['id']
            launch()
            time.sleep(.5)
            assert not any('CORAL_RECOVERY_PROMPT' in line for line in app.lines)
            assert len(list(root.iterdir())) == 2
            close()
            assert old.exists() and locked(old.parent)
            app = primary
            ipc.call('command', action='window.activate', fields={'id': primary_window})
            passed('Concurrent application instances use distinct journals and never offer an actively locked session for recovery')
            kill()
            assert not locked(old.parent)
            passed('Debounced durable checkpoint includes dirty/untitled Unicode text, groups, directed selections and scroll; SIGKILL releases lock')

            launch(prompt='restore')
            assert locked(old.parent), 'Chooser must retain authoritative claim lock'
            choose('F9')
            assert old.exists() and not locked(old.parent)
            close()
            assert old.exists()
            passed('Keep for later releases claim without deleting the stale journal; resolved exit removes only the new current journal')

            changed_disk = 'Changed externally after the crash.\n'
            sample.write_text(changed_disk)
            launch(prompt='restore')
            choose('F8', after='transferred')
            assert locked(old.parent)
            current = checkpoint(lambda value: len(value['documents']) == 2 and all(d['path'] is None for d in value['documents']))
            assert current != old
            assert manifest(current)['documents'][0]['bom'] and manifest(current)['documents'][0]['newline'] == 'mixed'
            choose('F10')
            wait_for(lambda: not old.parent.exists())
            restored = probe()
            assert sorted(d['text'] for d in restored['documents']) == sorted([edited, scratch]), restored
            assert all(d['dirty'] for d in restored['documents'])
            assert len(restored['groups']) == 2 and len(restored['views']) == 3, restored
            expected = [(v['page'], v['insertion'], v['bound'], v['selected'], v['active']) for v in before['views']]
            actual = [(v['page'], v['insertion'], v['bound'], v['selected'], v['active']) for v in restored['views']]
            assert actual == expected, (expected, actual)
            assert restored['views'][0]['scroll_y'] >= 200, restored
            command('focus-view', index=1)
            time.sleep(.15)
            assert probe()['views'][1]['scroll_y'] >= 350
            assert sample.read_text() == changed_disk
            passed('Restart restores canonical copies, duplicate views, tab selection, active group, directed Unicode selections and scroll without overwriting conflicting disk content')
            close()
            assert not list(root.iterdir()), list(root.iterdir())
            assert sample.read_text() == changed_disk
            passed('Explicitly resolved exit flushes asynchronously, releases application holds and removes only the resolved journal')

            large_fresh = fixtures / 'fresh-over-ten-mib.txt'
            large_fresh.write_bytes((b'x' * 63 + b'\n') * (10 * 1024 * 1024 // 64 + 1))
            launch(large_fresh)
            wait_for(lambda: probe()['dialog'])
            command('respond', response=1)
            app.expect('CORAL_RECOVERY_ERROR TooLarge', timeout=30)
            key('q', 'ctrl')
            assert app.wait(timeout=15) == 0, app.lines[-20:]
            wait_for(lambda: not windows())
            assert not list(root.iterdir()), 'An empty rejected session is not recovery data'
            launch()
            assert not any('CORAL_RECOVERY_PROMPT' in line or 'NoCheckpoint' in line for line in app.lines)
            close()
            passed('Fresh >10 MiB cap rejection followed by resolved exit and restart reaches readiness without a phantom recovery prompt')

            launch()
            command('insert', 'Corruption fixture')
            corrupt = checkpoint(lambda value: any(base64.b64decode(d['text']) == b'Corruption fixture' for d in value['documents']))
            kill()
            corrupt.write_bytes(b'CORAL-RECOVERY 1\nnot-a-valid-checksum\n{}')
            corrupt_bytes = corrupt.read_bytes()
            launch(prompt='unreadable')
            app.expect('CORAL_RECOVERY_ERROR CorruptManifest')
            choose('F9')
            close()
            assert corrupt.read_bytes() == corrupt_bytes
            # Empty current sessions are cleaned; any actual checkpoint from
            # this error-bearing launch remains conservatively retained.
            launch(prompt='unreadable')
            while any(w.get('title') == 'Recover interrupted session' for w in windows()):
                key('F10')
                time.sleep(.3)
            wait_for(lambda: not corrupt.parent.exists())
            close()
            passed('Corrupt journals are reported and kept byte-for-byte; deletion requires an explicit Discard response')

            # Give cap rejection an isolated state home: previous error journals
            # are intentionally retained, not cleaned as a side effect of testing.
            cap_home = state / 'cap-case'
            cap_home.mkdir(mode=0o700)
            root = cap_home / 'coral/recovery'
            launch(XDG_STATE_HOME=str(cap_home))
            command('insert', 'Last supported checkpoint')
            protected = checkpoint(lambda value: any(base64.b64decode(d['text']) == b'Last supported checkpoint' for d in value['documents']))
            baseline = protected.read_bytes()
            large = fixtures / 'over-cap.txt'
            large.write_text(('x' * 63 + '\n') * 65536 + 'x')
            command('open', large)
            app.expect('CORAL_RECOVERY_ERROR TooLarge', timeout=30)
            assert protected.read_bytes() == baseline, 'A capped document must not be silently omitted from a replacement checkpoint'
            kill()
            launch(prompt='restore', XDG_STATE_HOME=str(cap_home))
            choose('F8', after='transferred')
            choose('F10')
            assert probe()['documents'][0]['text'] == 'Last supported checkpoint'
            assert large.stat().st_size == 4 * 1024 * 1024 + 1
            close()
            passed('Over-cap UI rejection preserves the last valid checkpoint; SIGKILL/restart recovers it and never modifies the large source file')

            failure_home = state / 'write-failure'
            failure_home.mkdir(mode=0o700)
            root = failure_home / 'coral/recovery'
            launch(XDG_STATE_HOME=str(failure_home))
            command('insert', 'Durable before write failure')
            protected = checkpoint(lambda value: any(base64.b64decode(d['text']) == b'Durable before write failure' for d in value['documents']))
            baseline = protected.read_bytes()
            # Inject an actual filesystem error without modifying production store code.
            (protected.parent / 'pending').mkdir(mode=0o700)
            command('insert', ' newer unprotected edits')
            app.expect('CORAL_RECOVERY_ERROR Io')
            assert protected.read_bytes() == baseline
            close()
            assert protected.read_bytes() == baseline and not locked(protected.parent)
            assert any('CORAL_RECOVERY_CLOSED' in line for line in app.lines)
            passed('Async write failure is surfaced; even a subsequently resolved exit retains the last durable journal and releases its lock')

            view_home = state / 'excerpt-scroll'
            view_home.mkdir(mode=0o700)
            root = view_home / 'coral/recovery'
            preferences = Path(session.env['XDG_CONFIG_HOME']) / 'coral/preferences.ini'
            preferences.parent.mkdir(exist_ok=True)
            preferences.write_text('[Coral]\nwrap=false\nspelling=false\n')
            wide = fixtures / 'wide-unicode.txt'
            wide_text = ''.join(f'α😀 row {i:03d} ' + 'abcdefghij' * 30 + '\n' for i in range(100))
            wide.write_text(wide_text)
            launch(wide, XDG_STATE_HOME=str(view_home))
            wait_for(lambda: probe()['documents'][0]['text'] == wide_text)
            command('select', start=2, end=2)
            command('insert', '!')
            wide_edited = wide_text[:2] + '!' + wide_text[2:]
            command('split-group')
            command('select', start=7, end=len(wide_edited) - 20)
            command('excerpt')
            key('Home', 'ctrl')
            key('End')
            time.sleep(.2)
            command('select', start=600, end=299)
            command('scroll', y=300)
            excerpt_state = probe()
            excerpt = next(v for v in excerpt_state['views'] if v['excerpt_start'] is not None)
            assert excerpt['scroll_x'] > 0 and excerpt['scroll_y'] >= 250, excerpt
            # Independent full-document viewport in the other group.
            command('focus-view', index=0)
            key('Home', 'ctrl')
            key('End')
            time.sleep(.2)
            command('scroll', y=200)
            command('focus-view', index=2)
            before_views = probe()
            view_journal = checkpoint(lambda value: len(value['views']) == 3 and any(v['excerpt_start'] is not None and v['scroll_x'] > 0 for v in value['views']))
            time.sleep(.6)
            wire_before = manifest(view_journal)
            assert any(v['excerpt_start'] is None and v['scroll_x'] > 0 for v in wire_before['views'])
            kill()
            launch(prompt='restore', XDG_STATE_HOME=str(view_home))
            choose('F8', after='transferred')
            copied = checkpoint(lambda value: len(value['views']) == 3 and all(d['path'] is None for d in value['documents']))
            assert manifest(copied)['views'] == wire_before['views'] or [
                {k: v for k, v in item.items() if k not in ('id', 'document_id')}
                for item in manifest(copied)['views']
            ] == [{k: v for k, v in item.items() if k not in ('id', 'document_id')} for item in wire_before['views']]
            choose('F10')
            after_views = probe()
            assert len(after_views['documents']) == 1 and after_views['documents'][0]['text'] == wide_edited
            def view_identity(view):
                return (view['group_id'], view['page'], view['excerpt_start'], view['excerpt_end'], view['insertion'], view['bound'], view['selected'], view['active'])
            assert [view_identity(v) for v in after_views['views']] == [view_identity(v) for v in before_views['views']]
            for index in (0, 2):
                command('focus-view', index=index)
                time.sleep(.2)
                restored_view = probe()['views'][index]
                assert abs(restored_view['scroll_x'] - before_views['views'][index]['scroll_x']) < 2, restored_view
                assert restored_view['scroll_y'] >= before_views['views'][index]['scroll_y'] - 40, restored_view
            command('insert', 'EDIT')
            after_edit = probe()
            assert len(after_edit['documents']) == 1 and 'EDIT' in after_edit['documents'][0]['text']
            assert wide.read_text() == wide_text
            close()
            passed('Version 2 restores editable excerpts, canonical sharing, active tabs, excerpt-relative Unicode selections and independent full/excerpt horizontal and vertical viewports')

            save_home = state / 'interrupted-save'
            save_home.mkdir(mode=0o700)
            root = save_home / 'coral/recovery'
            target = fixtures / 'save-interrupted.txt'
            target.write_text('Original disk contents.\n')
            gate = fixtures / 'pause-checkpoint'
            launch(target, XDG_STATE_HOME=str(save_home), CORAL_TEST_RECOVERY_PAUSE=str(gate))
            wait_for(lambda: probe()['documents'][0]['text'] == target.read_text())
            command('select', start=0, end=0)
            command('insert', 'Durable edits α😀\n')
            durable_text = probe()['documents'][0]['text']
            protected = checkpoint(lambda value: base64.b64decode(value['documents'][0]['text']).decode() == durable_text)
            command('save-cancel')
            # Existing App hook cancels the real GIO save, not a simulated write.
            def file_probe():
                start = len(app.lines)
                key('F12')
                line = wait_for(lambda: next((line for line in app.lines[start:] if line.startswith('CORAL_PROBE ')), None))
                return json.loads(line.removeprefix('CORAL_PROBE '))
            wait_for(lambda: not file_probe()['busy'])
            assert file_probe()['dirty'] and target.read_text() == 'Original disk contents.\n'
            time.sleep(.6)
            baseline = protected.read_bytes()
            gate.touch()
            command('insert', 'Not committed to recovery yet')
            app.expect('CORAL_RECOVERY_BEFORE_COMMIT')
            uncommitted_text = probe()['documents'][0]['text']
            assert uncommitted_text != durable_text
            pending = manifest(protected.parent / 'pending')
            assert base64.b64decode(pending['documents'][0]['text']).decode() == uncommitted_text
            assert protected.read_bytes() == baseline
            kill()
            gate.unlink()
            assert protected.read_bytes() == baseline
            assert target.read_text() == 'Original disk contents.\n'
            launch(prompt='restore', XDG_STATE_HOME=str(save_home))
            choose('F8', after='transferred')
            choose('F10')
            assert probe()['documents'][0]['text'] == durable_text
            assert target.read_text() == 'Original disk contents.\n'
            close()
            passed('Cancelled real GIO save and SIGKILL during a file-fsynced but unrenamed recovery save preserve the last durable checkpoint and original disk contents')

        report['status'] = 'passed'
    finally:
        (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'Passed {len(checks)} native recovery acceptance groups.')


if __name__ == '__main__':
    main()
