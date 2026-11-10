#!/usr/bin/env python3
"""M2 native acceptance: restricted, paged virtualized workspace explorer.
Uses a private Wayland session, the real chooser/palette, GTK row activation,
real typing and the production GTask paths. No checked-in evidence is overwritten.
"""
import argparse
import json
import os
import stat
import sys
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
PEARL = PROJECT.parents[1]
sys.path[:0] = [str(PEARL / 'scripts'), str(PEARL / 'tests/integration')]
from pearl_session import PrivateSession, wait_for, fixture_prefix
from test_surfaces import IPC


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-workspaces')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    checks = []
    with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
        session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
        ipc = IPC(session)
        fixtures = Path(session.env['XDG_CONFIG_HOME']) / 'workspace-fixtures'
        fixtures.mkdir()
        left, right = fixtures / 'left' / 'same', fixtures / 'right' / 'same'
        for root in (left, right):
            root.mkdir(parents=True)
        (left / 'same.txt').write_text('LEFT α\n')
        (left / 'stale.txt').write_text('must not appear after workspace closes\n')
        (right / 'same.txt').write_text('RIGHT β\n')
        (left / 'nested').mkdir()
        (left / 'nested' / 'child.txt').write_text('nested only\n')
        (left / 'escape').symlink_to(right, target_is_directory=True)
        (left / 'alias.txt').symlink_to(right / 'same.txt')
        os.mkfifo(left / 'pipe')
        many = fixtures / 'many'
        many.mkdir()
        for index in range(510):
            (many / f'entry-{index:04}.txt').write_text('bounded\n')
        permission_parent = fixtures / 'execute-only-parent'
        permission_root = permission_parent / 'readable-root'
        permission_middle = permission_root / 'search-only'
        permission_leaf = permission_middle / 'readable-leaf'
        for directory in (permission_parent, permission_root, permission_middle, permission_leaf):
            directory.mkdir(mode=0o700)
        (permission_leaf / 'known.txt').write_text('readable below search-only ancestors\n')
        marker = fixtures / 'must-not-launch'
        script = left / 'autorun.sh'
        script.write_text(f'#!/bin/sh\ntouch "{marker}"\n')
        script.chmod(0o755)
        (left / '.coral').mkdir()
        (left / '.coral' / 'tasks.json').write_text(json.dumps({'command': str(script)}))
        manifest = fixtures / 'pair.coral-workspace'
        manifest.write_text(json.dumps({'version': 1, 'roots': [
            {'path': 'left/same', 'name': 'same'},
            {'path': 'right/same', 'name': 'same'},
            {'path': 'offline', 'name': 'Unavailable'}], 'settings': {}}))
        malformed = fixtures / 'malformed.coral-workspace'
        malformed.write_text('{')
        dangerous = fixtures / 'settings.coral-workspace'
        dangerous.write_text(json.dumps({'version': 1, 'roots': [], 'settings': {'command': str(script)}}))
        fifo = fixtures / 'fifo.coral-workspace'
        os.mkfifo(fifo)
        empty = fixtures / 'empty.coral-workspace'
        empty.write_text('{"version":1,"roots":[]}')
        command_path = fixtures / 'command.ini'
        session.env['CORAL_TEST_COMMAND'] = str(command_path)
        app = None
        serial = 0

        def windows():
            # Palette/shared chooser transients need not advertise an app_id.
            return [w for w in ipc.state() if w['kind'] == 'window']

        def key(name, *mods):
            cmd = ['wtype', '-s', '40']
            for mod in mods:
                cmd += ['-M', mod]
            cmd += ['-k', name]
            for mod in reversed(mods):
                cmd += ['-m', mod]
            session.run(cmd + ['-s', '100'])

        def text(value):
            session.run(['wtype', '-s', '40', '--', str(value)])

        def command(action, value=None, **fields):
            start = len(app.lines)
            content = '[Test]\naction=' + action + '\n'
            if value is not None:
                content += 'value=' + str(value) + '\n'
            content += ''.join(f'{k}={v}\n' for k, v in fields.items())
            command_path.write_text(content)
            key('F11')
            wait_for(lambda: any('CORAL_COMMAND_DONE' in line for line in app.lines[start:]))
            return app.lines[start:]

        def probe(browser=False):
            assert app.proc.poll() is None, app.lines[-30:]
            prefix = 'CORAL_BROWSER ' if browser else 'CORAL_WORKSPACE '
            lines = command('browser-probe' if browser else 'workspace-probe')
            return json.loads(next(line[len(prefix):] for line in lines if line.startswith(prefix)))

        def settled():
            return wait_for(lambda: p if not (p := probe(True))['pending'] and not p['choosing'] and not p['loading'] and not p['scanning'] else None)

        def launch(*options):
            nonlocal app, serial
            serial += 1
            app = session.child(f'coral-workspaces-{serial}', [args.binary.resolve(), *options], G_DEBUG='fatal-criticals')
            window = wait_for(lambda: next(iter(windows()), None))
            ipc.call('command', action='window.activate', fields={'id': window['id']})
            wait_for(lambda: probe()['documents'])
            return settled()

        def close():
            dirty = sum(d['dirty'] for d in probe()['documents'])
            key('q', 'ctrl')
            for _ in range(dirty):
                wait_for(lambda: probe()['dialog'])
                command('respond', response=1)
            assert app.wait(timeout=15) == 0, app.lines[-30:]
            wait_for(lambda: not windows())
            assert not any('CRITICAL' in line or 'panic:' in line for line in app.lines), app.lines[-30:]

        def passed(label):
            assert not marker.exists(), 'Workspace content executed a process'
            assert not any('CRITICAL' in line or 'panic:' in line for line in app.lines), app.lines[-30:]
            checks.append(label)
            print('PASS', label, flush=True)

        def activate(index):
            command('browser-activate', index=index)
            return settled()

        def entry(name):
            state = settled()
            index = next(i for i, e in enumerate(state['entries']) if e['name'] == name)
            return activate(index)

        def palette(query):
            key('p', 'ctrl', 'shift')
            wait_for(lambda: any(w.get('title') == 'Command Palette…' for w in windows()))
            text(query)
            key('Return')
            wait_for(lambda: not any(w.get('title') == 'Command Palette…' for w in windows()))

        def chooser_path(path, folder=False):
            wait_for(lambda: len(windows()) > 1)
            key('l', 'ctrl')
            key('a', 'ctrl')
            text(path)
            key('Return')
            if folder:
                # Location Enter navigates; Ctrl+Enter explicitly accepts a folder.
                time.sleep(.3)
                key('Return', 'ctrl')
            wait_for(lambda: len(windows()) == 1)
            return settled()

        def filesystem():
            result = {}
            for path in fixtures.rglob('*'):
                if path == command_path:
                    continue
                info = path.lstat()
                content = path.read_bytes().hex() if stat.S_ISREG(info.st_mode) else os.readlink(path) if stat.S_ISLNK(info.st_mode) else None
                result[str(path.relative_to(fixtures))] = (info.st_mode, info.st_size, content)
            return result

        baseline = filesystem()
        state = launch('--workspace', manifest)
        assert state['restricted'] and len(state['roots']) == 3, state
        assert len({r['id'] for r in state['roots']}) == 3
        assert state['roots'][2]['availability'] == 'missing' and not (fixtures / 'offline').exists()
        assert state['selected'] is None and not state['entries'], 'Workspace load must not enumerate roots'
        initial_roots = state['roots']
        state = activate(0)
        assert not any(e['name'] == 'child.txt' for e in state['entries'])
        for name in ('escape', 'alias.txt', 'pipe'):
            assert next(e for e in state['entries'] if e['name'] == name)['kind'] == 'blocked'
        entry('same.txt')
        wait_for(lambda: any(d['text'] == 'LEFT α\n' for d in probe()['documents']))
        key('End', 'ctrl')
        text('left edit')
        command('workspace-roots')
        activate(1)
        entry('same.txt')
        wait_for(lambda: any(d['text'] == 'RIGHT β\n' for d in probe()['documents']))
        key('End', 'ctrl')
        text('right edit')
        state = probe()
        docs = [d for d in state['documents'] if d['path']]
        assert len(docs) == 2 and all(d['dirty'] for d in docs), state
        assert {d['path'] for d in docs} == {str(left / 'same.txt'), str(right / 'same.txt')}
        for root in initial_roots[:2]:
            assert any(label.startswith(f"#{root['id']} same · same.txt") for label in state['tab_labels']), state
        session.run(['grim', output / 'two-roots-dirty.png'])
        passed('Native two-root same-basename open and real typing use distinct canonical documents and root-qualified labels')

        command('open-folder', many)
        assert settled()['roots'][0]['canonical'] == str(many)
        assert [d for d in probe()['documents'] if d['path']] == docs
        command('open-workspace', manifest)
        settled()
        assert [d for d in probe()['documents'] if d['path']] == docs
        passed('Switching folder/manifest preserves dirty document identities, paths, revisions and exact text')

        previous = settled()['roots']
        for path, expected in ((malformed, 'InvalidSchema'), (dangerous, 'UnsupportedSettings'), (fifo, 'NotRegularFile')):
            command('open-workspace', path)
            state = settled()
            assert state['error_name'] == expected and state['roots'] == previous, state
            assert [d for d in probe()['documents'] if d['path']] == docs
        passed('Malformed and executable-settings manifests and FIFO fail closed without losing previous workspace/documents or hanging')

        command('workspace-roots')
        activate(0)
        entry('nested')
        assert settled()['relative'] == 'nested'
        assert [e['name'] for e in settled()['entries']] == ['child.txt']
        command('workspace-back')
        assert settled()['relative'] == ''
        command('workspace-rescan')
        assert settled()['selected'] == previous[0]['id']
        command('browser-open-path', left / 'alias.txt')
        settled()
        assert 'Browser open rejected' in probe()['notice'] or 'regular file' in probe()['notice']
        command('browser-open-path', right / 'same.txt')
        settled()
        assert 'outside' in probe()['notice']
        assert [d for d in probe()['documents'] if d['path']] == docs
        passed('Lazy direct-child expand, Back and Rescan work; symlink files, symlink directories, FIFO and root escapes cannot open through browser')

        # Replace an already-listed directory/file to exercise worker checks, not
        # just insensitive rows based on the original stat snapshot.
        (left / 'nested').rename(left / 'nested-real')
        (left / 'nested').symlink_to(right, target_is_directory=True)
        state = entry('nested')
        assert state['error_name'] == 'UnavailableOrSymlink' and state['relative'] == '', state
        (left / 'nested').unlink()
        (left / 'nested-real').rename(left / 'nested')
        (left / 'stale.txt').rename(left / 'stale-real.txt')
        (left / 'stale.txt').symlink_to(right / 'same.txt')
        entry('stale.txt')
        assert [d for d in probe()['documents'] if d['path']] == docs
        (left / 'stale.txt').unlink()
        (left / 'stale-real.txt').rename(left / 'stale.txt')
        (left / 'new-child.txt').write_text('rescan only')
        wait_for(lambda: any(e['name'] == 'new-child.txt' for e in settled()['entries']))
        command('workspace-rescan')
        assert any(e['name'] == 'new-child.txt' for e in settled()['entries'])
        (left / 'new-child.txt').unlink()
        passed('Replaced symlink entries remain blocked; live create and explicit Rescan both update children')

        command('open-folder', many)
        settled()
        state = activate(0)
        assert not state['complete'] and len(state['entries']) == 256, state
        names = [e['name'] for e in state['entries']]
        while not state['complete']:
            command('browser-more')
            state = settled()
            assert len(state['entries']) <= 256
            names.extend(e['name'] for e in state['entries'])
        assert len(names) == len(set(names)) == 510
        assert set(names) == {f'entry-{i:04}.txt' for i in range(510)}
        session.run(['grim', output / 'paged-explorer.png'])
        passed('All 510 stable entries are reachable exactly once through bounded native page windows')

        command('workspace-race', manifest)
        state = settled()
        assert state['manifest'] == str(manifest) and len(state['roots']) == 3, state
        command('browser-swap-race', empty)
        state = settled()
        assert state['manifest'] == str(empty) and not state['entries'] and not state['roots'], state
        command('open-workspace', manifest)
        settled()
        command('browser-close-race')
        state = settled()
        assert not state['roots'] and not state['entries'] and state['manifest'] is None
        assert [d for d in probe()['documents'] if d['path']] == docs
        command('open-workspace', manifest)
        settled()
        command('browser-file-close-race', left / 'stale.txt')
        state = settled()
        assert not state['roots'] and [d for d in probe()['documents'] if d['path']] == docs
        passed('Last workspace request wins; delayed model/scan/file completions are reaped after model swap and explicit close')

        palette('Open Folder')
        state = chooser_path(left, folder=True)
        assert state['roots'][0]['canonical'] == str(left), state
        palette('Open Workspace')
        state = chooser_path(manifest)
        assert len(state['roots']) == 3, state
        previous = state['roots']
        palette('Open Workspace')
        wait_for(lambda: len(windows()) > 1)
        key('Escape')
        wait_for(lambda: len(windows()) == 1)
        assert settled()['roots'] == previous
        passed('Native command palette invokes shared folder/workspace choosers; accept and cancel retain correct workspace')
        assert filesystem() == baseline, 'Opening/browsing/typing must not mutate fixture files'
        close()
        passed('Restricted workspace content never auto-launches; close drains holds with no GTK criticals and no file changes')

        # Only isolated owned fixtures have their permissions changed. Explicitly
        # prove this host cannot list the ancestor (UID/capability bypass is not a pass).
        assert os.geteuid() != 0, 'Execute-only native acceptance requires an unprivileged host'
        assert permission_parent.stat().st_uid == os.geteuid()
        permission_parent.chmod(0o111)
        permission_middle.chmod(0o111)
        try:
            try:
                denied = os.open(permission_parent, os.O_RDONLY | os.O_DIRECTORY)
            except PermissionError:
                pass
            else:
                os.close(denied)
                raise AssertionError('Host bypassed directory read permissions')
            state = launch('--folder', permission_root)
            assert state['roots'][0]['availability'] == 'available', state
            state = activate(0)
            assert [e['name'] for e in state['entries']] == ['search-only'], state
            command('browser-browse-relative', 'search-only/readable-leaf')
            state = settled()
            assert [e['name'] for e in state['entries']] == ['known.txt'], state
            entry('known.txt')
            wait_for(lambda: any(d['text'] == 'readable below search-only ancestors\n' for d in probe()['documents']))
            command('browser-browse-relative', 'search-only')
            assert settled()['error_name'] == 'UnavailableOrSymlink'
            close()
        finally:
            permission_middle.chmod(0o700)
            permission_parent.chmod(0o700)
        passed('Unprivileged UID traverses owned 0111 ancestors and opens readable descendants; final unreadable directory still cannot be scanned')

        launch('--workspace', manifest)

        def burst(action, value):
            lines = command(action, value)
            browser = json.loads(next(line.removeprefix('CORAL_BROWSER ') for line in lines if line.startswith('CORAL_BROWSER ')))
            docs = json.loads(next(line.removeprefix('CORAL_WORKSPACE ') for line in lines if line.startswith('CORAL_WORKSPACE ')))
            assert browser['operation_limit'] == 8 and browser['request_byte_limit'] == 128 * 1024, browser
            assert browser['in_flight'] <= 8 and browser['request_bytes'] <= 128 * 1024, browser
            return browser, docs

        state, doc_state = burst('budget-load', manifest)
        assert state['pending'] == state['in_flight'] == 8 and state['loading'], state
        assert state['error_name'] == 'RequestBudgetExceeded' and 'last accepted request wins' in doc_state['notice']
        state = settled()
        assert state['manifest'] == str(manifest) and len(state['roots']) == 3, state
        assert state['request_bytes'] == state['in_flight'] == 0
        passed('64 delayed model requests retain only 8 workers/holds; rejected requests do not cancel the last accepted manifest')

        state, doc_state = burst('budget-scan', manifest)
        assert state['pending'] == 8 and state['scanning'] and state['error_name'] == 'RequestBudgetExceeded', state
        state = settled()
        assert state['relative'] == 'nested' and [e['name'] for e in state['entries']] == ['child.txt'], state
        assert state['request_bytes'] == 0
        passed('64 distinct delayed scans retain only 8 workers; over-budget navigation leaves the last accepted scan valid')

        state, _ = burst('budget-files', many)
        assert state['pending'] == state['in_flight'] == 8 and state['error_name'] == 'RequestBudgetExceeded', state
        settled()
        expected_paths = {str(many / f'entry-{i:04}.txt') for i in range(8)}
        wait_for(lambda: {d['path'] for d in probe()['documents'] if d['text'] == 'bounded\n'} == expected_paths)
        assert {d['path'] for d in probe()['documents'] if d['path']} == expected_paths
        passed('64 distinct delayed file requests open exactly the 8 accepted files, without a hidden retry queue')

        state, _ = burst('budget-dedup', left / 'same.txt')
        assert state['pending'] == state['in_flight'] == 2, state
        assert state['request_bytes'] == 2 * (len(str(left / 'same.txt').encode()) + 1) + len(str(left).encode()) + 1
        settled()
        wait_for(lambda: any(d['text'] == 'LEFT α\n' for d in probe()['documents']))
        assert len([d for d in probe()['documents'] if d['path'] == str(left / 'same.txt')]) == 1
        passed('Exact pending file paths deduplicate per root/scope token; unrestricted and root-bound opens remain distinct requests')

        state, doc_state = burst('budget-bytes', manifest)
        assert state['pending'] == 1 and state['request_bytes'] == 64 * 1024 + 1, state
        assert state['error_name'] == 'RequestBudgetExceeded' and '128 KiB' in doc_state['notice']
        assert settled()['request_bytes'] == 0
        passed('128 KiB retained-input budget includes terminators; long distinct paths reject before the operation cap and release bytes after reaping')

        state, doc_state = burst('budget-chooser', manifest)
        assert state['pending'] == 0 and state['in_flight'] == 1 and state['choosing'], state
        assert state['error_name'] == 'ChooserPending' and 'already open' in doc_state['notice']
        wait_for(lambda: len(windows()) == 2)
        state = chooser_path(left, folder=True)
        assert state['roots'][0]['canonical'] == str(left), state
        command('open-workspace', manifest)
        settled()
        state, _ = burst('budget-mixed', manifest)
        assert state['pending'] == 7 and state['in_flight'] == 8 and state['choosing'], state
        assert state['error_name'] == 'RequestBudgetExceeded'
        wait_for(lambda: len(windows()) == 2)
        key('Escape')
        wait_for(lambda: len(windows()) == 1)
        state = settled()
        assert state['in_flight'] == state['request_bytes'] == 0 and not state['choosing'], state
        assert state['manifest'] == str(manifest), state
        close()
        passed('Only one workspace chooser can be pending; its reserved slot shares the 8-operation budget with mixed model/scan/file work')

        # Relative CLI paths are native cwd-relative, not normalized across symlinks.
        relative = os.path.relpath(left, Path.cwd())
        state = launch('--folder', relative)
        assert state['roots'][0]['canonical'] == str(left), state
        close()
        state = launch('--folder', left, '--workspace', manifest)
        assert state['manifest'] == str(manifest), state
        close()
        state = launch(left)
        assert not state['roots'] and len(probe()['documents']) == 1
        assert probe()['documents'][0]['path'] is None
        close()
        state = launch('/' + 'x' * (64 * 1024))
        assert state['pending'] == state['request_bytes'] == 0 and state['error_name'] == 'RequestTooLarge', state
        assert len(probe()['documents']) == 1 and probe()['documents'][0]['path'] is None
        close()
        passed('Explicit relative --folder and last-option --workspace work; bare directories and oversized file arguments reject without filesystem mutation')
        launch('--workspace', manifest)
        before = probe()
        command('workspace-quit-race', manifest)
        refused = probe()
        assert refused['notice'] == 'Quit All could not freeze project sessions: Loading. All windows kept open.', refused
        assert refused['documents'] == before['documents'] and not refused['dialog'], refused
        assert app.proc.poll() is None and windows()
        state = settled()
        assert state['in_flight'] == state['request_bytes'] == 0, state
        close()
        passed('Pending model work refuses snapshot close without destroying documents; retry drains all holds before App destruction')
        assert filesystem() == baseline
    (output / 'results.json').write_text(json.dumps({'slice': 'M2 workspace compatibility with paged explorer', 'checks': checks, 'limitations': [
        '256-entry windows; 64 directory states, 8 resident pages/1 MiB page arenas; explicit Load more reaches later windows',
        'Shared limit: 8 controller operations including one possible chooser, 128 KiB retained request paths including terminators; no unbounded request queue; one coalesced reload flag per directory; last accepted model request wins',
        'Cancellation cannot interrupt blocked kernel I/O: cancelled workers keep their slots, bytes and holds until callbacks finish',
        'Root availability field is the original model snapshot; live root row errors/entries reflect current availability',
        'Browser rejects symlinks; existing path-based document loader is not a race-proof sandbox',
        'No workspace-root recovery persistence, trusted mode, task execution or destructive filesystem actions'
    ]}, indent=2) + '\n')
    print(f'Passed {len(checks)} M2 workspace compatibility check groups.', flush=True)


if __name__ == '__main__':
    main()
