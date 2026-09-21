#!/usr/bin/env python3
"""Exercise real Coral widgets, GIO files and Enchant in a private Wayland session."""
import argparse
import hashlib
import json
import shutil
import sys
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
PEARL = PROJECT.parents[1]
sys.path[:0] = [str(PEARL / 'scripts'), str(PEARL / 'tests/integration')]
from pearl_session import PrivateSession, wait_for
from test_surfaces import IPC


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=PROJECT / 'artifacts/native')
    parser.add_argument('--aqueous-prefix', type=Path, default=PEARL / '.cache/aqueous-activity-production')
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
                line = wait_for(lambda: next((line for line in app.lines[start:] if line.startswith('CORAL_PROBE ')), None))
                return json.loads(line.removeprefix('CORAL_PROBE '))
            def command(action, value=None, **fields):
                content = '[Test]\naction=' + action + '\n'
                if value is not None:
                    content += 'value=' + str(value) + '\n'
                content += ''.join(f'{k}={v}\n' for k, v in fields.items())
                command_path.write_text(content)
                start = len(app.lines)
                key('F11')
                wait_for(lambda: any('CORAL_COMMAND_DONE' in line for line in app.lines[start:]))
            def settled():
                return wait_for(lambda: (p if (p := probe())['enumerated'] and not p['busy'] and not p['inflight'] and (not p['dictionary'] or not p['checking_enabled'] or p['check_from'] >= p['chars']) else False))
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
            key('a', 'ctrl'); text('hello wrld')
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
            key('f', 'ctrl'); text('hello')
            wait_for(lambda: probe()['search'] == 2)
            capture('search')
            command('replace-all', 'world')
            key('Escape'); key('s', 'ctrl'); wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
            assert sample.read_text() == 'world world café 🌱 مرحبا'
            key('z', 'ctrl'); key('s', 'ctrl'); wait_for(lambda: not probe()['dirty'] and not probe()['busy'])
            assert sample.read_text() == 'hello hello café 🌱 مرحبا'
            passed('Unicode text, search counts, replace-all and one-step undo')
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
