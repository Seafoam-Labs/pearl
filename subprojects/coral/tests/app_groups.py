#!/usr/bin/env python3
"""Native app/group/excerpt/history acceptance; does not change the test roots.
Run after zig build -Dtest-hooks=true:
  python3 tests/app_groups.py --binary zig-out/bin/coral
"""
import argparse
import json
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
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-app-groups')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    checks = []
    with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
        session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8')
        ipc = IPC(session)
        fixtures = Path(session.env['XDG_CONFIG_HOME']) / 'app-group-fixtures'
        fixtures.mkdir()
        sample = fixtures / 'unicode.txt'
        original = 'α one\nβ two\nγ three\n' + ''.join(f'Line {i}\n' for i in range(150))
        sample.write_text(original)
        command_path = fixtures / 'command.ini'
        session.env['CORAL_TEST_COMMAND'] = str(command_path)
        app = session.child('coral-groups', [args.binary.resolve(), sample], G_DEBUG='fatal-criticals')
        window = wait_for(lambda: next((w for w in ipc.state() if w['kind'] == 'window' and w.get('app_id') == 'org.aqueous.Coral'), None))
        ipc.call('command', action='window.activate', fields={'id': window['id']})

        def key(name, *mods):
            cmd = ['wtype', '-s', '40']
            for mod in mods:
                cmd += ['-M', mod]
            cmd += ['-k', name]
            for mod in reversed(mods):
                cmd += ['-m', mod]
            # Keep the virtual keyboard alive while the app handles the action;
            # destroying it immediately can drop queued events during transactions.
            session.run(cmd + ['-s', '100'])

        def command(action, value=None, **fields):
            start = len(app.lines)
            content = '[Test]\naction=' + action + '\n'
            if value is not None:
                content += 'value=' + value + '\n'
            content += ''.join(f'{k}={v}\n' for k, v in fields.items())
            command_path.write_text(content)
            key('F11')
            try:
                wait_for(lambda: any('CORAL_COMMAND_DONE' in line for line in app.lines[start:]))
            except TimeoutError:
                print('Command timeout:', action, 'process:', app.proc.poll(), flush=True)
                if app.proc.poll() is None:
                    print('wait channel:', Path(f'/proc/{app.proc.pid}/wchan').read_text(), flush=True)
                    print('process stat:', Path(f'/proc/{app.proc.pid}/stat').read_text(), flush=True)
                print('window state:', ipc.state(), flush=True)
                print('recent log:', '\n'.join(app.lines[-5:])[-2000:], flush=True)
                raise
            return app.lines[start:]

        def probe():
            assert app.proc.poll() is None, app.lines[-40:]
            lines = command('workspace-probe')
            return json.loads(next(line.removeprefix('CORAL_WORKSPACE ') for line in lines if line.startswith('CORAL_WORKSPACE ')))

        def active(state):
            return next(v for v in state['views'] if v['active'])

        def passed(label):
            assert not any('CRITICAL' in line or 'panic:' in line for line in app.lines), app.lines[-40:]
            checks.append(label)
            print('PASS', label, flush=True)

        wait_for(lambda: probe()['documents'][0]['text'] == original)
        command('observe-checkpoints')
        command('select', start=1, end=5)
        command('scroll', y=240)
        command('split-group')
        state = probe()
        assert len(state['groups']) == 2 and len(state['views']) == 2 and len(state['documents']) == 1, state
        command('select', start=8, end=6)
        state = probe()
        assert (state['views'][0]['insertion'], state['views'][0]['bound']) == (1, 5), state
        assert (state['views'][1]['insertion'], state['views'][1]['bound']) == (8, 6), state
        assert state['views'][0]['scroll_y'] >= 200 and state['views'][1]['scroll_y'] == 0, state
        command('focus-group', index=0)
        assert active(probe())['insertion'] == 1
        command('focus-group', index=1)
        assert active(probe())['insertion'] == 8
        passed('Split groups share one canonical document and preserve independent directed selections through focus')

        command('select', start=8, end=8)
        session.run(['wtype', '-s', '40', '--', 'Ω'])
        state = probe()
        edited = original[:8] + 'Ω' + original[8:]
        assert state['documents'][0]['text'] == edited, state
        assert state['views'][0]['insertion'] == 1, state
        revision = state['documents'][0]['revision']
        key('z', 'ctrl')
        state = probe()
        assert state['documents'][0]['text'] == original and state['documents'][0]['revision'] > revision, state
        key('z', 'ctrl', 'shift')
        assert probe()['documents'][0]['text'] == edited
        passed('Real pane typing forwards to canonical native undo/redo without disturbing the other pane cursor')

        command('close-group')
        state = probe()
        assert len(state['groups']) == 1 and len(state['views']) == 1 and not state['dialog'], state
        assert state['documents'][0]['text'] == edited and state['documents'][0]['dirty'], state
        passed('Closing a duplicate dirty view/group neither prompts nor destroys the canonical document')

        command('select', start=2, end=5)
        command('excerpt')
        state = probe()
        assert len(state['views']) == 2 and active(state)['excerpt_start'] is not None, state
        command('select', start=1, end=1)
        wait_for(lambda: probe()['editor_focused'])
        session.run(['wtype', '-s', '40', '--', '!'])
        state = probe()
        excerpt_edited = edited[:3] + '!' + edited[3:]
        assert state['documents'][0]['text'] == excerpt_edited, state
        assert state['history_cursor'] == 1, state
        revision = state['documents'][0]['revision']
        key('z', 'ctrl')
        state = probe()
        assert state['documents'][0]['text'] == edited and state['documents'][0]['revision'] > revision, state
        key('z', 'ctrl', 'shift')
        assert probe()['documents'][0]['text'] == excerpt_edited
        passed('Real editable excerpt maps Unicode display offsets into canonical grouped history with fresh replay revisions')

        command('focus-view', index=0)
        command('close')
        state = probe()
        assert len(state['views']) == 1 and active(state)['excerpt_start'] is not None and not state['dialog'], state
        command('settings', theme=1, font=16)
        command('find')
        session.run(['wtype', '-s', '40', '--', 'o!ne'])
        time.sleep(.3)  # GtkSearchEntry debounces search-changed.
        key('F3')
        state = probe()
        assert sorted((active(state)['insertion'], active(state)['bound'])) == [0, 4], state
        key('Escape')
        passed('Excerpt-only document survives source tab closure, theme changes and presentation-buffer search navigation')

        command('restore-copy')
        state = probe()
        assert len(state['documents']) == 2 and len(state['groups']) == 2, state
        assert all(d['text'] == excerpt_edited and d['dirty'] for d in state['documents']), state
        assert active(state)['excerpt_start'] is not None, state
        assert sorted((active(state)['insertion'], active(state)['bound'])) == [0, 4], state
        passed('Public snapshot and restore APIs recreate unsaved canonical copies and editable excerpt selections')

        command('grouped-append', '!batch')
        state = probe()
        assert all(d['text'] == excerpt_edited + '!batch' for d in state['documents']), state
        revisions = [d['revision'] for d in state['documents']]
        command('grouped-undo')
        state = probe()
        assert all(d['text'] == excerpt_edited for d in state['documents']), state
        assert all(d['revision'] > r for d, r in zip(state['documents'], revisions)), state
        command('grouped-redo')
        state = probe()
        assert all(d['text'] == excerpt_edited + '!batch' for d in state['documents']), state
        command('checkpoint')
        assert probe()['checkpoints'] > 0
        passed('Grouped multi-document replay is atomic, advances revisions, and checkpoints only coherent projections')

        command('split-group')
        command('select', start=0, end=0)
        command('insert', '?')
        before = probe()
        command('grouped-undo')
        after = probe()
        assert after['documents'] == before['documents'], (before, after)
        command('undo')
        assert all(d['text'] == excerpt_edited + '!batch' for d in probe()['documents'])
        baseline = probe()['documents']
        command('undo')
        assert probe()['documents'] == baseline, 'Native undo must not unwrap one participant of a grouped edit'
        command('redo')
        assert probe()['documents'][-1]['text'].startswith('?')
        command('undo')
        passed('Stale grouped undo rejects the entire batch; typing undo/redo stays native and cannot cross a grouped boundary')

        command('scroll', y=500)
        state = probe()
        assert active(state)['scroll_y'] >= 490, state
        command('restore-copy')
        state = probe()
        restored_id = state['documents'][-1]['id']
        restored_view = next(i for i, v in enumerate(state['views']) if v['document_id'] == restored_id and v['excerpt_start'] is None)
        command('focus-view', index=restored_view)
        time.sleep(.15)
        state = probe()
        assert active(state)['scroll_y'] >= 490, state
        passed('Restored full views retain scroll after notebook mapping/allocation, alongside excerpt copies')

        for inverse in (False, True):
            # Use fresh full views and real GTK typing immediately adjacent to a
            # group operation. end_user_action alone used to merge X + y.
            pair = []
            for name in ('a', 'b'):
                path = fixtures / f'boundary-{inverse}-{name}.txt'
                path.write_text('base')
                command('open', str(path))
                wait_for(lambda: probe()['documents'][-1]['text'] == 'base')
                pair.append(probe()['documents'][-1]['id'])
            command('grouped-append', 'X')
            state = probe()
            full_index = next(i for i, v in enumerate(state['views'])
                              if v['document_id'] == pair[0] and v['excerpt_start'] is None)
            command('focus-view', index=full_index)
            if inverse:
                command('select', start=4, end=5)
                command('excerpt')
                command('select', start=0, end=1)
                wait_for(lambda: probe()['editor_focused'])
                key('BackSpace')
                assert next(d for d in probe()['documents'] if d['id'] == pair[0])['text'] == 'base'
                command('grouped-undo')
                command('focus-view', index=full_index)
            command('select', start=5, end=5)
            wait_for(lambda: probe()['editor_focused'])
            others = [d for d in probe()['documents'] if d['id'] != pair[0]]
            session.run(['wtype', '-s', '40', '--', 'y'])
            assert next(d for d in probe()['documents'] if d['id'] == pair[0])['text'] == 'baseXy'
            key('z', 'ctrl')
            state = probe()
            assert next(d for d in state['documents'] if d['id'] == pair[0])['text'] == 'baseX', state
            assert [d for d in state['documents'] if d['id'] != pair[0]] == others, state
            baseline = state['documents']
            key('z', 'ctrl')
            assert probe()['documents'] == baseline, 'Protected group action must not enter native undo'
            key('z', 'ctrl', 'shift')
            assert next(d for d in probe()['documents'] if d['id'] == pair[0])['text'] == 'baseXy'
            key('z', 'ctrl')
            assert [d for d in probe()['documents'] if d['id'] != pair[0]] == others
            passed(('Inverse grouped deletion replay' if inverse else 'Grouped append') +
                   ' is isolated from adjacent real typing undo/redo; other document text/revision/dirty state is unchanged')

        checkpoint_paths = []
        checkpoint_ids = []
        for name in ('a', 'b'):
            path = fixtures / f'checkpoint-{name}.txt'
            path.write_text('base')
            command('open', str(path))
            wait_for(lambda: probe()['documents'][-1]['text'] == 'base')
            checkpoint_paths.append(path)
            checkpoint_ids.append(probe()['documents'][-1]['id'])
        state = probe()
        full_index = next(i for i, v in enumerate(state['views'])
                          if v['document_id'] == checkpoint_ids[0] and v['excerpt_start'] is None)
        command('focus-view', index=full_index)

        def checkpoint_document():
            return next(d for d in probe()['documents'] if d['id'] == checkpoint_ids[0])

        def save_checkpoint(text):
            key('s', 'ctrl')
            wait_for(lambda: checkpoint_paths[0].read_text() == text)
            wait_for(lambda: not checkpoint_document()['dirty'])

        command('grouped-append', 'X')
        command('select', start=5, end=5)
        wait_for(lambda: probe()['editor_focused'])
        session.run(['wtype', '-s', '40', '--', 'y'])
        assert checkpoint_document()['text'] == 'baseXy'
        save_checkpoint('baseXy')
        command('grouped-append', 'Q')
        save_checkpoint('baseXyQ')
        command('grouped-undo')
        assert checkpoint_document()['text'] == 'baseXy'
        others = [d for d in probe()['documents'] if d['id'] != checkpoint_ids[0]]
        command('select', start=6, end=6)
        wait_for(lambda: probe()['editor_focused'])
        session.run(['wtype', '-s', '40', '--', 'z'])
        key('z', 'ctrl')
        state = probe()
        current = next(d for d in state['documents'] if d['id'] == checkpoint_ids[0])
        assert current['text'] == 'baseX' and current['dirty'], state
        assert checkpoint_paths[0].read_text() == 'baseXyQ'
        assert checkpoint_paths[1].read_text() == 'base'
        assert [d for d in state['documents'] if d['id'] != checkpoint_ids[0]] == others, state
        key('z', 'ctrl', 'shift')
        assert checkpoint_document()['text'] == 'baseXyz' and checkpoint_document()['dirty']
        # A new explicit save may authorize this interval again, including redo
        # back to its actual disk checkpoint. It must not disable native history.
        save_checkpoint('baseXyz')
        key('z', 'ctrl')
        assert checkpoint_document()['text'] == 'baseX' and checkpoint_document()['dirty']
        key('z', 'ctrl', 'shift')
        assert checkpoint_document()['text'] == 'baseXyz' and not checkpoint_document()['dirty']
        key('z', 'ctrl')  # Leave all documents dirty for the quit prompt checks.
        assert checkpoint_document()['dirty']
        assert [d for d in probe()['documents'] if d['id'] != checkpoint_ids[0]] == others
        passed('Two saves across grouped epochs cannot reuse an obsolete native clean marker; new saves restore clean redo and other documents stay untouched')

        huge = fixtures / 'huge-line.c'
        huge_original = '/*' + 'aé🌱' * 20000 + '*/'
        huge.write_text(huge_original)
        command('open', str(huge))
        wait_for(lambda: any('CORAL_GUARD' in line for line in app.lines))
        # Loading replaces the focused text-input widget. Let Wayland process its
        # leave/enter before injecting the next virtual keyboard event.
        time.sleep(.15)
        wait_for(lambda: probe()['documents'][-1]['text'] == huge_original)
        state = probe()
        assert state['layout_blocked'] and state['syntax_limited'], state
        # Focus the actual fallback button; activate it through native keyboard.
        command('guard-offset', offset=12345)
        key('Return')
        wait_for(lambda: active(probe())['excerpt_start'] is not None)
        state = probe()
        assert not state['layout_blocked'] and state['editable'], state
        assert active(state)['excerpt_start'] == len(huge_original[:12345].encode()), state
        assert active(state)['excerpt_end'] == len(huge_original[:12345 + 2048].encode()), state
        command('select', start=1, end=1)
        wait_for(lambda: probe()['editor_focused'])
        session.run(['wtype', '-s', '40', '--', '!'])
        state = probe()
        assert state['documents'][-1]['text'] == huge_original[:12346] + '!' + huge_original[12346:], state
        revision = state['documents'][-1]['revision']
        key('z', 'ctrl')
        state = probe()
        assert state['documents'][-1]['text'] == huge_original and state['documents'][-1]['revision'] > revision, state
        key('z', 'ctrl', 'shift')
        assert probe()['documents'][-1]['text'][12346] == '!'
        assert huge.read_text() == huge_original
        passed('Late giant-line load exposes a real bounded Unicode excerpt action, editable with grouped undo/redo and intact source')

        before_quit = probe()
        key('q', 'ctrl')
        state = probe()
        assert state['dialog'], state
        command('respond', response=0)
        state = probe()
        assert not state['dialog'] and len(state['documents']) == len(before_quit['documents']) and len(state['views']) == len(before_quit['views']), state
        key('q', 'ctrl')
        assert probe()['dialog']
        for remaining in range(len(before_quit['documents']) - 1, 0, -1):
            command('respond', response=1)
            state = probe()
            assert state['dialog'] and len(state['documents']) == remaining, state
        command('respond', response=1)
        assert app.wait(timeout=10) == 0, app.lines[-40:]
        assert sample.read_text() == original
        passed('Quit cancellation preserves every view; discard prompts once per canonical document and never writes source files')

    (output / 'results.json').write_text(json.dumps({'status': 'passed', 'checks': checks}, indent=2) + '\n')
    print(f'Passed {len(checks)} application integration check groups.')


if __name__ == '__main__':
    main()
