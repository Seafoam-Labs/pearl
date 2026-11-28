#!/usr/bin/env python3
"""Empty Trash toolbar button in an isolated session with a scratch Trash."""
import argparse, hashlib, json, os, sys, time
from pathlib import Path
PROJECT = Path(__file__).resolve().parents[1]
PEARL = PROJECT.parents[1]
sys.path[:0] = [str(PEARL / 'scripts'), str(PEARL / 'tests/integration')]
from pearl_session import PrivateSession, wait_for, fixture_prefix
from test_surfaces import IPC

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--output', type=Path, default=PROJECT / 'artifacts/trash/native')
    args = p.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {'status': 'running', 'checks': [], 'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest()}
    try:
        with PrivateSession(output / 'session', tool_prefix=fixture_prefix()) as s:
            s.env['GSETTINGS_BACKEND'] = 'memory'
            s.env['GVFS_REMOTE_VOLUME_MONITOR_IGNORE'] = '1'
            s.child('gvfs', ['/usr/lib/gvfsd', '--no-fuse'])
            s.child('gvfs-metadata', ['/usr/lib/gvfsd-metadata'])
            wait_for(lambda: 'true' in s.run(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus', '--object-path', '/org/freedesktop/DBus', '--method', 'org.freedesktop.DBus.NameHasOwner', 'org.gtk.vfs.Daemon']).stdout)
            wait_for(lambda: 'true' in s.run(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus', '--object-path', '/org/freedesktop/DBus', '--method', 'org.freedesktop.DBus.NameHasOwner', 'org.gtk.vfs.Metadata']).stdout)
            ipc = IPC(s)
            display = next(iter(ipc.outputs().values()))
            s.run(['wlr-randr', '--output', display['name'], '--custom-mode', '1600x1100@60Hz'])
            home = Path(s.env['HOME'])
            source = home / 'Source'
            source.mkdir()
            (source / 'alpha.txt').write_text('alpha bytes\n')
            (source / 'beta.txt').write_text('beta bytes\n')
            outside = home / 'Outside'
            outside.mkdir()
            sentinel = outside / 'sentinel.txt'
            sentinel.write_text('never touch me\n')
            sentinel_hash = hashlib.sha256(sentinel.read_bytes()).hexdigest()
            trash_root = Path(s.env['XDG_DATA_HOME']) / 'Trash'
            rules = Path(s.env['XDG_CONFIG_HOME']) / 'aqueous/rules.toml'
            rules.write_text('[[window]]\napp_id = "org.aqueous.Phyto"\nfloating = true\nwidth = 1180\nheight = 760\n')
            ipc.call('command', action='session.reload', fields={})
            app = s.child('phyto-trash', [args.binary.resolve(), source], G_DEBUG='fatal-warnings')

            def windows():
                return [w for w in ipc.state() if w['kind'] == 'window' and w.get('app_id') == 'org.aqueous.Phyto']
            win = wait_for(lambda: next(iter(windows()), None))
            ipc.call('command', action='window.activate', fields={'id': win['id']})

            def key(k, *mods):
                cmd = ['wtype', '-s', '80']
                for m in mods:
                    cmd += ['-M', m]
                cmd += ['-k', k]
                for m in reversed(mods):
                    cmd += ['-m', m]
                s.run(cmd)

            def text(t):
                s.run(['wtype', '-s', '100', '--', str(t)])

            def probe():
                assert app.proc.poll() is None, app.lines[-10:]
                start = len(app.lines)
                key('F12')
                return json.loads(wait_for(lambda: next((x.removeprefix('PHYTO_PROBE ') for x in app.lines[start:] if x.startswith('PHYTO_PROBE ')), None), timeout=5))

            def settled():
                return wait_for(lambda: v if not (v := probe())['loading'] and v['write_capable'] else False)

            def navigate(path):
                key('l', 'ctrl')
                text(path)
                key('Return')
                return wait_for(lambda: v if not (v := probe())['loading'] else False)

            def pointer(x, y, button='left'):
                s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
                s.run(['wlrctl', 'pointer', 'move', str(round(x)), str(round(y))])
                s.run(['wlrctl', 'pointer', 'click', button])
                time.sleep(0.15)

            def click(label, kind='file', button='left', menu=False):
                v = probe()
                row = next((x for x in v['widgets'] if x['label'] == label and (x['menu'] if menu else x['kind'] == kind and (not x['menu']))))
                rect = windows()[0]['geometry']
                pointer(rect['x'] + row['x'] + row['width'] / 2, rect['y'] + row['y'] + row['height'] / 2, button)

            def capture(name):
                rect = windows()[0]['geometry']
                s.run(['grim', '-g', f"{rect['x']},{rect['y']} {rect['width']}x{rect['height']}", output / (name + '.png')])

            def dialog_click(title, label):
                row = next(x for x in probe()['operation_dialog_widgets'] if x['label'] == label)
                rect = next(w['geometry'] for w in ipc.state() if w['kind'] == 'window' and w.get('title') == title)
                pointer(rect['x'] + row['x'] + row['width'] / 2, rect['y'] + row['y'] + row['height'] / 2)

            def dialog_open(title):
                return wait_for(lambda: next((w for w in ipc.state() if w['kind'] == 'window' and w.get('title') == title), None))

            def dialog_closed(title):
                return wait_for(lambda: not any(w.get('title') == title for w in ipc.state() if w['kind'] == 'window'))

            def trash_button():
                return next((w for w in probe()['widgets'] if w['label'] == 'Empty Trash…' and not w['menu']), None)

            def background_menu():
                rect = windows()[0]['geometry']
                pointer(rect['x'] + 700, rect['y'] + 620, 'right')
                wait_for(lambda: probe()['context_kind'] == 'background' and probe()['context_open'])

            def menu_item(label):
                return next((w for w in probe()['widgets'] if w['label'] == label and w['menu']), None)

            def trash_snapshot():
                if not trash_root.exists():
                    return {}
                return {str(p.relative_to(trash_root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in trash_root.rglob('*') if p.is_file()}

            def passed(label):
                report['checks'].append(label)
                print('PASS', label, flush=True)

            settled()
            assert trash_button() is None
            passed('Empty Trash button hidden in an ordinary folder')

            click('alpha.txt')
            key('a', 'ctrl')
            key('Delete')
            dialog_open('Move to Trash?')
            key('Tab')
            key('Return')
            wait_for(lambda: not (source / 'alpha.txt').exists() and not (source / 'beta.txt').exists())
            wait_for(lambda: not probe()['busy'])
            navigate('trash:///')
            wait_for(lambda: probe()['count'] == 2)
            button = trash_button()
            assert button and button['sensitive']
            assert probe()['selected'] == 0
            capture('trash-root')
            passed('Button visible and enabled at the Trash root with no selection')

            background_menu()
            item = menu_item('Empty Trash…')
            assert item and item['sensitive']
            key('Escape')
            passed('Background menu keeps its enabled Empty Trash command')

            click('alpha.txt', button='right')
            labels = [w['label'] for w in probe()['widgets'] if w['menu']]
            assert 'Restore' in labels and 'Delete permanently…' in labels
            assert 'Empty Trash…' not in labels
            key('Escape')
            passed('Per-item Trash actions are unchanged')

            for _ in range(80):
                if probe()['focus_name'] == 'Empty Trash':
                    break
                key('Tab')
            else:
                raise AssertionError('Empty Trash button is not keyboard reachable')
            key('Return')
            dialog_open('Empty Trash?')
            labels = [w['label'] for w in probe()['operation_dialog_widgets']]
            assert 'Cancel' in labels and 'Delete permanently' in labels
            before = trash_snapshot()
            assert before
            key('Return')
            dialog_closed('Empty Trash?')
            assert probe()['count'] == 2
            assert trash_snapshot() == before
            passed('Keyboard activation opens the confirmation; default Cancel leaves every entry intact')

            files_dir = trash_root / 'files'
            info_dir = trash_root / 'info'
            files_dir.chmod(0o555)
            info_dir.chmod(0o555)
            try:
                click('Empty Trash…', kind='label')
                dialog_open('Empty Trash?')
                dialog_click('Empty Trash?', 'Delete permanently')
                wait_for(lambda: not probe()['busy'])
                assert 'Some items failed' in probe()['operation_result']
                dialog_open('Some items did not complete')
                key('Escape')
                dialog_closed('Some items did not complete')
                assert probe()['count'] == 2
                assert trash_snapshot() == before
                assert trash_button()['sensitive']
                passed('A failed empty reports the error and keeps showing what remains')
            finally:
                files_dir.chmod(0o755)
                info_dir.chmod(0o755)

            click('alpha.txt')
            assert probe()['selected'] == 1
            click('Empty Trash…', kind='label')
            dialog_open('Empty Trash?')
            dialog_click('Empty Trash?', 'Delete permanently')
            wait_for(lambda: probe()['count'] == 0 and not probe()['busy'])
            assert not any(files_dir.iterdir())
            assert not any((trash_root / 'info').iterdir())
            assert hashlib.sha256(sentinel.read_bytes()).hexdigest() == sentinel_hash
            button = trash_button()
            assert button and not button['sensitive']
            capture('trash-emptied')
            passed('Confirmed empty deletes the whole Trash regardless of selection, never outside files, and refreshes the view')

            background_menu()
            item = menu_item('Empty Trash…')
            assert item and not item['sensitive']
            key('Escape')
            passed('Button and background command disabled while Trash is empty')

            key('t', 'ctrl')
            wait_for(lambda: not probe()['loading'])
            assert trash_button() and trash_button()['sensitive'] is False
            navigate(source)
            assert trash_button() is None
            key('w', 'ctrl')
            wait_for(lambda: not probe()['loading'] and probe()['uri'].startswith('trash:'))
            assert trash_button() is not None
            passed('Visibility follows the selected tab')

            key('F3')
            wait_for(lambda: probe()['split'])
            assert trash_button() is not None
            key('F6')
            wait_for(lambda: probe()['active'] == 1)
            assert trash_button() is None
            key('F6')
            wait_for(lambda: probe()['active'] == 0)
            assert trash_button() is not None
            passed('Visibility follows the active pane in split view')

            for _ in range(4):
                if app.proc.poll() is not None:
                    break
                key('w', 'ctrl')
                time.sleep(0.2)
            assert app.wait(timeout=10) == 0, app.lines[-20:]
            assert not any(('CRITICAL' in x or 'WARNING' in x or 'panic:' in x for x in app.lines))
            passed('Clean native teardown with fatal GTK warnings')
            ipc.close()
        report['status'] = 'passed'
    except Exception as e:
        report.update(status='failed', error=str(e))
        raise
    finally:
        (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
if __name__ == '__main__':
    main()
