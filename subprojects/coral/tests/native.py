#!/usr/bin/env python3
"""Exercise real Coral widgets, GIO files and Enchant in a private Wayland session."""
import argparse
import hashlib
import json
import os
import shutil
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
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=PROJECT / 'artifacts/native')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {'status': 'running', 'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(), 'checks': [], 'captures': []}
    def passed(name):
        report['checks'].append(name)
        print('PASS', name, flush=True)
    try:
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env['GSETTINGS_BACKEND'] = 'memory'
            session.env['LANG'] = 'en_US.UTF-8'
            session.env['LC_ALL'] = 'en_US.UTF-8'
            session.env['LANGUAGE'] = 'en_US'
            ipc = IPC(session)
            display = next(iter(ipc.outputs().values()))
            session.run(['wlr-randr', '--output', display['name'], '--custom-mode', '1600x1100@60Hz'])
            config = Path(session.env['XDG_CONFIG_HOME'])
            fixtures = config / 'coral-fixtures'
            fixtures.mkdir()
            enchant = config / 'enchant'
            (enchant / 'hunspell').mkdir(parents=True)
            for name in ['en_US.aff', 'en_US.dic']:
                shutil.copyfile(PROJECT / 'tests/fixtures' / name, enchant / 'hunspell' / name)
            (enchant / 'enchant.ordering').write_text('*:hunspell\n')
            session.env['ENCHANT_CONFIG_DIR'] = str(enchant)
            command_path = fixtures / 'command.ini'
            session.env['CORAL_TEST_COMMAND'] = str(command_path)
            sample = fixtures / 'notes.md'
            sample.write_text('# A small document\n\nHello world.\nA little curiousity.\n\nLocal spelling, offline.\n')
            rules = config / 'aqueous/rules.toml'
            app = None
            serial = 0
            def windows():
                return [w for w in ipc.state() if w['kind'] == 'window' and w.get('app_id') == 'org.aqueous.Coral']
            def key(name, *modifiers):
                cmd = ['wtype', '-s', '40']
                for mod in modifiers:
                    cmd += ['-M', mod]
                cmd += ['-k', name]
                for mod in reversed(modifiers):
                    cmd += ['-m', mod]
                session.run(cmd)
            def text(value):
                session.run(['wtype', '-s', '40', '--', str(value)])
            def probe():
                assert app.proc.poll() is None, app.lines[-30:]
                start = len(app.lines)
                key('F12')
                last_sent = time.monotonic()
                def response():
                    nonlocal last_sent
                    assert app.proc.poll() is None, app.lines[-30:]
                    line = next((line for line in app.lines[start:] if line.startswith('CORAL_PROBE ')), None)
                    # A newly mapped modal can temporarily have no keyboard
                    # focus. Retry only the read-only probe, never commands.
                    if line is None and time.monotonic() - last_sent > .25:
                        key('F12')
                        last_sent = time.monotonic()
                    return line
                line = wait_for(response)
                return json.loads(line.removeprefix('CORAL_PROBE '))
            def command(action, value=None, **fields):
                content = '[Test]\naction=' + action + '\n'
                if value is not None:
                    content += 'value=' + str(value) + '\n'
                content += ''.join(f'{k}={v}\n' for k, v in fields.items())
                command_path.write_text(content)
                start = len(app.lines)
                key('F11')
                try:
                    wait_for(lambda: any('CORAL_COMMAND_DONE' in line for line in app.lines[start:]))
                except TimeoutError as exc:
                    raise TimeoutError(f'Native command {action!r} did not complete; exit={app.proc.poll()}, log={app.lines[-10:]}') from exc
            def palette_window():
                return next((w for w in ipc.state() if w['kind'] == 'window' and w.get('title') == 'Command Palette…'), None)
            def palette(query, dispatch=True):
                key('p', 'ctrl', 'shift')
                wait_for(palette_window)
                text(query)
                if dispatch:
                    key('Return')
                    wait_for(lambda: not palette_window())
            def filesystem():
                snapshot = {}
                for path in fixtures.rglob('*'):
                    if path == command_path:
                        continue
                    info = path.lstat()
                    # Never read special files (in particular, the FIFO fixture).
                    content = path.read_bytes() if stat.S_ISREG(info.st_mode) else os.readlink(path) if stat.S_ISLNK(info.st_mode) else None
                    snapshot[str(path.relative_to(fixtures))] = (info.st_mode, info.st_ino, info.st_size, info.st_mtime_ns, content)
                return snapshot
            def settled():
                return wait_for(lambda: (p if (p := probe())['enumerated'] and not p['busy'] and not p['inflight'] and (not p['dictionary'] or not p['checking_enabled'] or p['check_from'] >= p['chars']) else False))
            def idle_state(state):
                return {field: state[field] for field in ('tabs', 'id', 'chars', 'dirty', 'external_changed', 'revision', 'dialog', 'search', 'busy')}
            def disk_state(changed):
                return wait_for(lambda: (p if (p := probe())['external_changed'] == changed and not p['busy'] else False))
            def disk_stays_clean():
                # Observe beyond GIO's event coalescing interval; an immediate
                # false flag alone could precede a delayed own-save notification.
                disk_state(False)
                for _ in range(4):
                    time.sleep(.15)
                    assert not probe()['external_changed']
            def capture(name):
                time.sleep(.15)
                rect = windows()[0]['geometry']
                session.run(['grim', '-g', f"{rect['x']},{rect['y']} {rect['width']}x{rect['height']}", output / f'{name}.png'])
                report['captures'].append({'file': f'{name}.png', 'geometry': rect, 'state': probe()})
            def launch(*paths, width=1000, height=740, flags=(), scale=1):
                nonlocal app, serial
                serial += 1
                rules.write_text(f'[[window]]\napp_id = "org.aqueous.Coral"\nfloating = true\nwidth = {width}\nheight = {height}\n')
                gtk = config / 'gtk-4.0'
                gtk.mkdir(exist_ok=True)
                (gtk / 'settings.ini').write_text(f'[Settings]\ngtk-font-name=Sans {11 * scale}\n')
                ipc.call('command', action='session.reload', fields={})
                app = session.child(f'coral-{serial}', [args.binary.resolve(), f'--width={width}', f'--height={height}', *flags, *paths], G_DEBUG='fatal-criticals')
                window = wait_for(lambda: next(iter(windows()), None))
                ipc.call('command', action='window.activate', fields={'id': window['id']})
                return settled()
            def close():
                key('q', 'ctrl')
                assert app.wait(timeout=10) == 0, app.lines[-40:]
                assert not any('CRITICAL' in line or 'panic:' in line for line in app.lines), app.lines[-40:]
                wait_for(lambda: not windows())

            initial = launch(sample, flags=['--dark'])
            assert initial['tabs'] == 1 and initial['dictionary'], initial
            capture('editor-dark')
            key('F7')
            wait_for(lambda: probe()['popover'])
            capture('spelling')
            key('Escape')
            passed('Native startup, local file argument, dictionary discovery and suggestions')

            palette('no-such-coral-command', dispatch=False)
            key('Return')
            assert palette_window(), 'An unmatched palette query must not dispatch'
            key('a', 'ctrl'); text('new document'); key('Return')
            wait_for(lambda: not palette_window())
            state = settled()
            scratch_id = state['id']
            assert state['tabs'] == 2 and scratch_id != initial['id'] and state['chars'] == 0, state
            text('palette typing')
            state = probe()
            assert state['dirty'] and state['chars'] == len('palette typing'), state
            passed('Ctrl+Shift+P opens a native palette; filtering and Enter create and focus a new document')
            palette('preferences', dispatch=False)
            key('Escape')
            wait_for(lambda: not palette_window())
            text(' restored')
            state = probe()
            assert state['id'] == scratch_id and state['tabs'] == 2 and state['dialog'] == -1, state
            assert state['chars'] == len('palette typing restored'), state
            palette_file = fixtures / 'palette-focus.txt'
            command('save-path', palette_file)
            wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
            assert palette_file.read_text() == 'palette typing restored'
            passed('Palette Escape cancels dispatch and restores editor typing focus')
            text(' saved')
            palette('save')
            wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
            assert palette_file.read_text() == 'palette typing restored saved'
            palette('find')
            text('restored')
            wait_for(lambda: probe()['search'] == 1)
            before_state = probe()
            palette('preferences', dispatch=False)
            key('Escape')
            wait_for(lambda: not palette_window())
            # Do not refocus Find: typing must return to the previously focused query entry.
            text(' no-match')
            wait_for(lambda: probe()['search'] == 0)
            state = probe()
            for field in ('tabs', 'id', 'chars', 'dirty', 'revision', 'dialog'):
                assert state[field] == before_state[field], ('palette cancel to Find', field, before_state, state)
            key('a', 'ctrl'); text('saved')
            wait_for(lambda: probe()['search'] == 1)
            state = probe()
            for field in ('tabs', 'id', 'chars', 'dirty', 'revision', 'dialog'):
                assert state[field] == before_state[field], ('typing in restored Find', field, before_state, state)
            assert palette_file.read_text() == 'palette typing restored saved'
            passed('Palette Escape restores Find / Replace query focus without modifying the document')
            key('Escape')
            state = probe()
            assert not state['dirty'] and state['chars'] == len('palette typing restored saved'), state
            palette('preferences')
            wait_for(lambda: probe()['dialog'] == 5)
            command('respond', response=0)
            wait_for(lambda: probe()['dialog'] == -1)
            key('w', 'ctrl')
            state = settled()
            assert state['tabs'] == 1 and state['id'] == initial['id'], state
            passed('Palette dispatches Save, Find / Replace and Preferences through native keyboard input')

            directory = fixtures / 'directory'
            directory.mkdir()
            (directory / 'keep.txt').write_text('keep this file')
            fifo = fixtures / 'named-pipe'
            os.mkfifo(fifo)
            for target in [fixtures / 'missing.txt', fixtures / 'missing-parent' / 'nested' / 'missing.txt', directory, fifo]:
                before_state = settled()
                before_files = filesystem()
                command('open', target)
                state = settled()
                for field in ('tabs', 'id', 'chars', 'dirty', 'revision', 'dialog'):
                    assert state[field] == before_state[field], (str(target), field, before_state, state)
                assert filesystem() == before_files, f'Opening {target} changed the filesystem'
            passed('Missing paths (including nested parents), directories and FIFOs leave documents and filesystem unchanged')

            reload_path = fixtures / 'reload-target.txt'
            original_reload_text = 'hello reload café 🌱'
            restored_reload_text = 'hello restored world café 🌱'
            reload_path.write_text(original_reload_text)
            command('open', reload_path)
            state = settled()
            assert state['tabs'] == initial['tabs'] + 1 and state['chars'] == len(original_reload_text) and not state['dirty'], state
            key('f', 'ctrl'); key('a', 'ctrl'); text(original_reload_text)
            wait_for(lambda: probe()['search'] == 1)
            before_state = disk_state(False)
            reload_path.unlink()
            os.mkfifo(reload_path)
            try:
                state = disk_state(True)
                assert idle_state(state) == idle_state(before_state | {'external_changed': True}), (before_state, state)
                before_state = state
                before_files = filesystem()
                # Reload directly: never enter save or etag-conflict handling on a FIFO.
                command('reload')
                state = settled()
                assert idle_state(state) == idle_state(before_state), ('FIFO reload', before_state, state)
                disk_state(True)
                assert stat.S_ISFIFO(reload_path.lstat().st_mode), 'Reload replaced the FIFO'
                assert filesystem() == before_files, 'Reloading a FIFO changed the filesystem'
            finally:
                reload_path.unlink()
                reload_path.write_text(restored_reload_text)
            passed('Reloading an opened file replaced by a FIFO completes without changing buffer, revision, tabs or filesystem')
            command('reload')
            state = settled()
            assert state['tabs'] == before_state['tabs'] and state['id'] == before_state['id'], state
            assert not state['dirty'] and state['revision'] > before_state['revision'] and state['chars'] == len(restored_reload_text), state
            key('f', 'ctrl'); key('a', 'ctrl'); text(restored_reload_text)
            wait_for(lambda: probe()['search'] == 1)
            assert reload_path.read_text() == restored_reload_text
            disk_state(False)
            key('Escape'); key('w', 'ctrl')
            state = settled()
            assert state['tabs'] == initial['tabs'] and state['id'] == initial['id'], state
            passed('Explicit reload recovers after FIFO rejection and loads the restored regular file contents')

            watched = fixtures / 'watched.txt'
            watched.write_text('original watched text')
            command('open', watched)
            settled()
            before_state = disk_state(False)
            watched.write_text('external write with different content')
            state = disk_state(True)
            assert idle_state(state) == idle_state(before_state | {'external_changed': True}), (before_state, state)
            palette('reload from disk')
            state = disk_state(False)
            assert not state['dirty'] and state['chars'] == len(watched.read_text()) and state['revision'] > before_state['revision'], state
            passed('Local monitor flags external writes without reloading; palette Reload from Disk explicitly reloads clean documents')

            key('a', 'ctrl'); text('unsaved local edits')
            before_state = probe()
            watched.write_text('disk version for confirmed reload')
            state = disk_state(True)
            assert idle_state(state) == idle_state(before_state | {'external_changed': True}), (before_state, state)
            palette('reload from disk')
            wait_for(lambda: probe()['dialog'] == 4)
            command('respond', response=0)
            assert idle_state(probe()) == idle_state(state), 'Cancelling reload changed the dirty buffer'
            # Search verifies the actual text, not just its length/revision.
            key('f', 'ctrl'); key('a', 'ctrl'); text('unsaved local edits')
            wait_for(lambda: probe()['search'] == 1)
            key('Escape')
            palette('reload from disk')
            wait_for(lambda: probe()['dialog'] == 4)
            command('respond', response=1)
            state = disk_state(False)
            assert not state['dirty'] and state['chars'] == len(watched.read_text()), state
            key('f', 'ctrl'); key('a', 'ctrl'); text(watched.read_text())
            wait_for(lambda: probe()['search'] == 1)
            key('Escape')
            passed('Dirty Reload cancellation preserves edits; Discard and reload replaces the buffer only after confirmation')

            before_state = probe()
            watched.unlink()
            state = disk_state(True)
            assert idle_state(state) == idle_state(before_state | {'external_changed': True}), (before_state, state)
            assert not watched.exists()
            watched.write_text('recreated disk file')
            command('reload')
            disk_state(False)
            before_state = probe()
            replacement_file = fixtures / 'atomic-replacement.txt'
            replacement_file.write_text('atomically replaced disk file')
            replacement_file.replace(watched)
            state = disk_state(True)
            assert idle_state(state) == idle_state(before_state | {'external_changed': True}), (before_state, state)
            command('reload')
            disk_state(False)
            passed('Deletion and atomic replacement flag external change without modifying the clean document')

            key('End', 'ctrl'); text(' own save')
            key('s', 'ctrl')
            wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
            disk_stays_clean()
            assert watched.read_text() == 'atomically replaced disk file own save'
            # Save race still leaves edits newer than the snapshot unsaved, but
            # the snapshot's own write must not look like an external writer.
            command('save-race')
            wait_for(lambda: not probe()['busy'])
            assert probe()['dirty']
            disk_stays_clean()
            key('s', 'ctrl')
            wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
            disk_stays_clean()
            passed('Own-save notifications settle without an external flag, including edits during an in-flight save')

            new_watched = fixtures / 'watched-save-as.txt'
            watched.write_text('old target changed before Save As')
            # Query and Save As start in the same GTK callback, guaranteeing
            # an outstanding old-generation operation at the transition.
            command('watch-save-as', new_watched)
            wait_for(lambda: not probe()['busy'])
            disk_stays_clean()
            saved_copy = new_watched.read_text()
            watched.write_text('old target changed after Save As')
            disk_stays_clean()
            assert new_watched.read_text() == saved_copy
            new_watched.write_text('new target change is still monitored')
            disk_state(True)
            command('reload')
            disk_state(False)
            passed('Save As rejects stale query results and old-path events while monitoring the new target')

            command('watch-close')
            state = settled()
            assert state['id'] == initial['id'] and state['tabs'] == initial['tabs'], state
            # Reopen with a different document ID before more notifications.
            command('open', new_watched)
            settled()
            command('watch-close')
            state = settled()
            assert state['id'] == initial['id'] and state['tabs'] == initial['tabs'], state
            passed('Closing tabs with outstanding metadata queries reaps callbacks without UAF or GTK criticals')

            alias = fixtures / 'notes-alias.md'
            alias.symlink_to(sample.name)
            key('n', 'ctrl')
            other_id = probe()['id']
            for target in [sample, directory / '..' / sample.name, alias]:
                before_files = filesystem()
                command('open', target)
                state = settled()
                assert state['tabs'] == 2 and state['id'] == initial['id'], (str(target), state)
                assert not state['dirty'] and state['chars'] == initial['chars'], state
                assert filesystem() == before_files, str(target)
                key('Tab', 'ctrl')
                assert probe()['id'] == other_id
            key('w', 'ctrl')
            assert probe()['tabs'] == 1 and probe()['id'] == initial['id']
            passed('Repeated, dot-dot and symlink opens activate the canonical document without duplicate tabs')

            key('a', 'ctrl'); text('hello wrld')
            state = probe()
            assert state['tabs'] == 1 and state['id'] == initial['id'], state
            assert state['dirty'] and state['revision'] > initial['revision'] and state['chars'] == len('hello wrld'), ('Typing after clean-tab close did not reach the remaining editor', state)
            passed('Closing a clean active tab immediately restores typing focus to the remaining editor')
            wait_for(lambda: settled()['spelling'] == 1)
            key('F7'); wait_for(lambda: probe()['popover'])
            command('correct')
            wait_for(lambda: settled()['spelling'] == 0)
            key('z', 'ctrl')
            wait_for(lambda: settled()['spelling'] == 1)
            key('z', 'ctrl', 'shift')
            wait_for(lambda: settled()['spelling'] == 0)
            key('s', 'ctrl')
            wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
            assert sample.read_text() == 'hello world', sample.read_text()
            passed('Real Enchant correction, single-step undo/redo and asynchronous save')
            key('a', 'ctrl'); text('hello hello café 🌱 مرحبا')
            key('f', 'ctrl'); key('a', 'ctrl'); text('hello')
            wait_for(lambda: probe()['search'] == 2)
            capture('search')
            command('replace-all', 'world')
            key('Escape'); key('s', 'ctrl'); wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
            assert sample.read_text() == 'world world café 🌱 مرحبا'
            key('z', 'ctrl'); key('s', 'ctrl'); wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
            assert sample.read_text() == 'hello hello café 🌱 مرحبا'
            passed('Unicode text, search counts, replace-all and one-step undo')
            source = 'café 🌱 | مرحبا | a\u0308\n' * 3
            key('a', 'ctrl'); text(source)
            key('s', 'ctrl'); wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
            assert sample.read_text() == source
            for needle, replacement in [('café 🌱', 'café 🌱 café 🌱'), ('مرحبا', '界'), ('a\u0308', '🪸')]:
                key('f', 'ctrl'); key('a', 'ctrl'); text(needle)
                wait_for(lambda: probe()['search'] == 3)
                before_state = probe()
                command('replace-all', needle)
                state = settled()
                assert state['revision'] == before_state['revision'] and not state['dirty'], (needle, before_state, state)
                command('replace-all', replacement)
                key('Escape'); key('s', 'ctrl')
                wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
                assert sample.read_text() == source.replace(needle, replacement), (needle, sample.read_text())
                # A no-op must neither loop nor insert an undo entry above the real transaction.
                key('f', 'ctrl'); key('a', 'ctrl'); text(replacement)
                wait_for(lambda: probe()['search'] == 3)
                before_state = probe()
                command('replace-all', replacement)
                state = settled()
                assert state['revision'] == before_state['revision'] and not state['dirty'], (replacement, before_state, state)
                key('Escape'); key('z', 'ctrl'); key('s', 'ctrl')
                wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
                assert sample.read_text() == source, (needle, 'one-step undo', sample.read_text())
            passed('Unicode multi-replace handles expanding/self-containing text and identical replacements without looping; each real transaction undoes in one step')
            key('n', 'ctrl'); text('unsaved notes')
            assert probe()['tabs'] == 2
            key('w', 'ctrl'); assert probe()['dialog'] == 0
            capture('unsaved')
            command('respond', response=0)
            assert probe()['tabs'] == 2
            key('w', 'ctrl'); command('respond', response=1)
            assert probe()['tabs'] == 1
            passed('Dirty-tab close prompts, cancellation and discard')
            key('a', 'ctrl'); text('my edits')
            sample.write_text('external changes')
            key('s', 'ctrl'); wait_for(lambda: probe()['dialog'] == 2)
            capture('file-conflict')
            assert sample.read_text() == 'external changes'
            command('respond', response=3)
            wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
            assert sample.read_text() == 'my edits'
            passed('External write detected by etag; explicit overwrite preserves current edits')
            key('a', 'ctrl'); text('hello wrld')
            wait_for(lambda: settled()['spelling'] == 1)
            key('F7'); wait_for(lambda: probe()['popover']); command('ignore')
            wait_for(lambda: settled()['spelling'] == 0)
            key('n', 'ctrl'); text('wrld')
            wait_for(lambda: settled()['spelling'] == 1)
            key('w', 'ctrl'); command('respond', response=1)
            assert settled()['spelling'] == 0
            key('a', 'ctrl'); text('coralword')
            wait_for(lambda: settled()['spelling'] == 1)
            key('F7'); wait_for(lambda: probe()['popover']); command('add')
            wait_for(lambda: settled()['spelling'] == 0)
            key('s', 'ctrl'); wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
            passed('Ignore is document-local; Enchant personal dictionary addition removes the underline')
            command('language', 'zz_XX')
            wait_for(lambda: not settled()['dictionary'])
            capture('missing-dictionary')
            key('End', 'ctrl'); text(' hello')
            assert probe()['dirty']
            command('language', 'en_US')
            wait_for(lambda: settled()['dictionary'])
            key('s', 'ctrl'); wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
            passed('Missing dictionaries clear spelling marks while keeping editing available')
            before = sample.read_text()
            command('save-race')
            wait_for(lambda: not probe()['busy'])
            assert probe()['dirty'] and sample.read_text() == before
            key('s', 'ctrl'); wait_for(lambda: not probe()['busy'] and not probe()['dirty'])
            assert sample.read_text() == before + ' plus'
            key('End', 'ctrl'); text(' more')
            command('save-cancel'); wait_for(lambda: not probe()['busy'])
            assert probe()['dirty'] and sample.read_text() == before + ' plus'
            command('save-path', fixtures / 'absent-parent' / 'cannot-save.txt')
            wait_for(lambda: not probe()['busy'])
            assert probe()['dirty'] and sample.read_text() == before + ' plus'
            key('s', 'ctrl'); wait_for(lambda: not probe()['busy'] and not probe()['dirty'])
            passed('Edits during save remain dirty; cancelled and failed saves preserve original content')
            sample.unlink()
            key('s', 'ctrl'); wait_for(lambda: probe()['dialog'] == 2)
            assert not sample.exists()
            command('respond', response=3)
            wait_for(lambda: not probe()['busy'])
            assert sample.exists()
            passed('Deleted files require an explicit overwrite decision before recreation')
            formats = fixtures / 'utf8-bom-crlf.txt'
            original_bytes = b'\xef\xbb\xbfhello\r\nworld'
            formats.write_bytes(original_bytes)
            command('open', formats)
            state = settled()
            assert state['bom'] and state['newline'] == 1
            key('s', 'ctrl'); wait_for(lambda: not probe()['busy'])
            assert formats.read_bytes() == original_bytes
            key('w', 'ctrl')
            mixed = fixtures / 'mixed.txt'
            mixed.write_bytes(b'hello\r\nworld\n')
            command('open', mixed); settled()
            key('s', 'ctrl'); wait_for(lambda: probe()['dialog'] == 1)
            command('respond', response=0)
            assert mixed.read_bytes() == b'hello\r\nworld\n'
            key('s', 'ctrl'); command('respond', response=1)
            wait_for(lambda: not probe()['busy'])
            assert mixed.read_bytes() == b'hello\nworld\n'
            key('w', 'ctrl')
            passed('Native BOM/CRLF/final-newline round trip and explicit mixed-line normalization')
            for filename, contents in [('binary.txt', b'a\x00b'), ('encoding.txt', b'\xff')]:
                invalid = fixtures / filename
                invalid.write_bytes(contents)
                command('open', invalid)
                state = settled()
                assert state['chars'] == 0 and not state['dirty']
                key('w', 'ctrl')
                assert invalid.read_bytes() == contents
            passed('Binary and invalid UTF-8 inputs are rejected without changing their files')
            command('settings', theme=1, font=18)
            command('preferences'); capture('preferences'); command('respond', response=0)
            close()
            passed('Clean shutdown with no GTK criticals')
            state = launch(sample)
            assert state['theme'] == 1 and state['font'] == 18
            key('a', 'ctrl'); text('coralword')
            assert settled()['spelling'] == 0
            key('s', 'ctrl'); wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
            close()
            passed('Preferences and personal dictionary survive restart')
            settings_file = config / 'coral/preferences.ini'
            settings_file.write_text(settings_file.read_text().replace('font=18', 'font=14'))
            sample.write_text('# A quieter workspace\n\nA small place to write.\n\n## Local spelling\n\nHello world. A little curiousity.\n\n## Keep writing\n\n- Open a document\n- Search and replace words\n- Save your changes\n')
            for name, flags, width, scale in [('editor-light',['--light'],1000,1), ('native-theme',['--native-theme'],1000,1), ('narrow',['--dark'],480,1), ('text-200-percent',['--light'],1000,2)]:
                launch(sample, flags=flags, width=width, scale=scale)
                capture(name)
                close()
            passed('Light/dark/native themes, narrow window and 200% interface text')
            launch()
            text('hello world')
            key('s', 'ctrl'); time.sleep(.4); key('Escape')
            assert probe()['dirty'] and not probe()['busy']
            chosen = fixtures / 'chosen-name.txt'
            key('s', 'ctrl'); time.sleep(.4); key('l', 'ctrl'); key('a', 'ctrl'); text(chosen); key('Return')
            wait_for(lambda: chosen.exists())
            wait_for(lambda: not probe()['busy'] and not probe()['dirty'])
            assert chosen.read_text() == 'hello world'
            close()
            passed('Native Save As picker cancellation and writing a chosen filename')
            launch(sample, formats)
            key('a', 'ctrl'); text('first unsaved')
            first_id = probe()['id']
            key('Tab', 'ctrl')
            assert probe()['id'] != first_id
            key('a', 'ctrl'); text('second unsaved')
            assert probe()['dirty']
            key('q', 'ctrl'); command('respond', response=0)
            assert probe()['tabs'] == 2
            key('q', 'ctrl'); command('respond', response=1)
            assert probe()['tabs'] == 1 and probe()['dialog'] == 0
            command('respond', response=1)
            assert app.wait(timeout=10) == 0
            wait_for(lambda: not windows())
            passed('Multi-document quit stops on cancellation and resolves every dirty tab')
            large = fixtures / 'large.txt'
            large.write_text('hello world\n' * 900000)
            # Large files stop at a modal gate before populating the GtkSourceBuffer.
            launch()
            command('open', large)
            wait_for(lambda: probe()['dialog'] == 3)
            capture('large-file')
            command('respond', response=1)
            state = settled()
            assert state['large'] and not state['checking_enabled'] and state['chars'] > 10 * 1024 * 1024
            close()
            passed('Files above 10 MiB require consent and disable automatic spelling/highlighting')
            launch()
            medium = fixtures / 'one-mib.txt'
            medium.write_text('hello world\n' * 87382)
            started = time.monotonic()
            command('open', medium)
            wait_for(lambda: not probe()['busy'])
            key('End', 'ctrl'); text('hello world')
            state = settled()
            elapsed = time.monotonic() - started
            assert state['spelling'] == 0 and state['dirty']
            report['one_mib'] = {'open_edit_check_seconds': round(elapsed, 3), 'max_main_thread_spelling_tick_us': state['max_spell_tick_us']}
            assert state['max_spell_tick_us'] < 50000, report['one_mib']
            key('s', 'ctrl'); wait_for(lambda: not probe()['busy'] and not probe()['dirty'])
            close()
            passed('1 MiB document remains editable during checking; stale batches are rejected and main-thread ticks stay below 50 ms')
            launch(sample)
            command('watch-close')
            assert app.wait(timeout=10) == 0, app.lines[-40:]
            assert not any('CRITICAL' in line or 'panic:' in line for line in app.lines), app.lines[-40:]
            wait_for(lambda: not windows())
            passed('Last-window close drains a cancelled watcher query and releases its application hold cleanly')

            race_path = fixtures / 'reload-edit-race.txt'
            race_text = 'local text before reload café 🌱'
            race_disk_text = 'different disk payload for reload'
            race_path.write_text(race_text)
            launch(race_path)
            key('End', 'ctrl')
            race_path.write_text(race_disk_text)
            before_state = disk_state(True)
            assert not before_state['dirty'], before_state
            # The hook inserts before the async callback can run, rather than
            # relying on file size or keyboard timing to produce the race.
            command('reload-race')
            state = settled()
            assert state['id'] == before_state['id'] and state['tabs'] == before_state['tabs'], state
            assert state['dirty'] and state['revision'] == before_state['revision'] + 1, (before_state, state)
            assert state['chars'] == len(race_text + ' plus') and state['dialog'] == -1, state
            disk_state(True)
            assert race_path.read_text() == race_disk_text, 'Reload race overwrote the disk file'
            race_copy = fixtures / 'reload-edit-race-preserved.txt'
            command('save-path', race_copy)
            wait_for(lambda: not probe()['busy'] and not probe()['dirty'])
            assert race_copy.read_text() == race_text + ' plus', 'Async reload discarded the newer local edit'
            assert race_path.read_text() == race_disk_text
            close()
            passed('Async reload rejects a stale revision and preserves exact newer local text without overwriting disk')

            large_payload = large.read_bytes()
            pending_path = fixtures / 'pending-reload-edit.txt'
            pending_text = 'small local buffer before large reload café'
            pending_path.write_text(pending_text)
            launch(pending_path)
            key('End', 'ctrl')
            pending_path.write_bytes(large_payload)
            before_state = disk_state(True)
            assert not before_state['dirty'] and not before_state['large'], before_state
            command('reload')
            wait_for(lambda: probe()['dialog'] == 3)
            command('edit-pending-load')
            edited_state = probe()
            assert edited_state['dialog'] == 3 and edited_state['dirty'], edited_state
            assert edited_state['revision'] == before_state['revision'] + 1, (before_state, edited_state)
            assert edited_state['chars'] == len(pending_text + ' plus'), edited_state
            for shortcut, modifiers in [('z', ('ctrl',)), ('z', ('ctrl', 'shift')), ('y', ('ctrl',))]:
                key(shortcut, *modifiers)
                assert idle_state(probe()) == idle_state(edited_state), 'Undo/redo modified a pending load'
            command('respond', response=1)
            state = settled()
            assert idle_state(state) == idle_state(edited_state | {'dialog': -1}), (edited_state, state)
            assert not state['large'] and state['checking_enabled'] == before_state['checking_enabled'], state
            assert state['bom'] == before_state['bom'] and state['newline'] == before_state['newline'], state
            disk_state(True)
            assert pending_path.read_bytes() == large_payload, 'Stale large-load acceptance changed disk'
            pending_copy = fixtures / 'pending-reload-edit-preserved.txt'
            command('save-path', pending_copy)
            wait_for(lambda: not probe()['busy'] and not probe()['dirty'])
            assert pending_copy.read_text() == pending_text + ' plus', 'Large-load acceptance discarded the newer edit'
            assert pending_path.read_bytes() == large_payload
            close()
            passed('Accepting a stale pending large reload preserves exact newer edits and buffer mode; pending undo/redo is blocked')

            for dirty_empty in (False, True):
                case = 'dirty' if dirty_empty else 'clean'
                empty_path = fixtures / f'empty-{case}-large-reload.txt'
                empty_path.write_text('saved text to delete' if dirty_empty else '')
                launch(empty_path)
                if dirty_empty:
                    key('a', 'ctrl'); key('BackSpace')
                settled()
                before_state = disk_state(False)
                assert before_state['chars'] == 0 and before_state['dirty'] == dirty_empty, before_state
                empty_path.write_bytes(large_payload)
                disk_state(True)
                command('reload')
                if dirty_empty:
                    wait_for(lambda: probe()['dialog'] == 4)
                    command('respond', response=1)
                wait_for(lambda: probe()['dialog'] == 3)
                command('respond', response=0)
                state = settled()
                assert idle_state(state) == idle_state(before_state | {'external_changed': True}), (case, before_state, state)
                assert empty_path.read_bytes() == large_payload, 'Cancelling large reload modified disk'
                restored_text = f'restored small {case} file café 🌱'
                empty_path.write_text(restored_text)
                # Do not reopen: only the retained path on this same document
                # can make this Reload find the restored, smaller disk file.
                command('reload')
                if dirty_empty:
                    wait_for(lambda: probe()['dialog'] == 4)
                    command('respond', response=1)
                disk_state(False)
                state = settled()
                assert state['id'] == before_state['id'] and state['tabs'] == before_state['tabs'], (case, before_state, state)
                assert not state['dirty'] and not state['large'] and state['dialog'] == -1, state
                assert state['revision'] > before_state['revision'] and state['chars'] == len(restored_text), state
                key('f', 'ctrl'); text(restored_text)
                wait_for(lambda: probe()['search'] == 1)
                assert empty_path.read_text() == restored_text
                key('Escape')
                close()
                passed(f'Cancelling large reload of a {case} empty buffer preserves path and identity for a subsequent explicit reload')
            report['status'] = 'passed'
    except Exception as exc:
        report['status'] = 'failed'
        report['error'] = repr(exc)
        raise
    finally:
        (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'Passed {len(report["checks"])} native check groups.', flush=True)

if __name__ == '__main__':
    main()
