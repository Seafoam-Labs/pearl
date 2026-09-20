#!/usr/bin/env python3
"""Native context menus, target identities and operations in an isolated session."""
import argparse, hashlib, json, os, sys, time
from pathlib import Path
PROJECT = Path(__file__).resolve().parents[1]
PEARL = PROJECT.parents[1]
sys.path[:0] = [str(PEARL / 'scripts'), str(PEARL / 'tests/integration')]
from pearl_session import PrivateSession, wait_for
from test_surfaces import IPC

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--output', type=Path, default=PROJECT / 'artifacts/context-menus/native')
    args = p.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {'status': 'running', 'checks': [], 'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest()}
    try:
        with PrivateSession(output / 'session', tool_prefix=PEARL / '.cache/aqueous-activity-production') as s:
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
            dest = home / 'Destination'
            source.mkdir()
            dest.mkdir()
            (source / 'one.txt').write_text('original bytes\n')
            (source / 'two.txt').write_text('second\n')
            (source / 'Folder').mkdir()
            (source / 'Folder/nested.txt').write_text('recursive\n')
            (source / 'Folder/loop').symlink_to('.')
            rules = Path(s.env['XDG_CONFIG_HOME']) / 'aqueous/rules.toml'
            rules.write_text('[[window]]\napp_id = "org.aqueous.Phyto"\nfloating = true\nwidth = 1180\nheight = 760\n')
            ipc.call('command', action='session.reload', fields={})
            templates = home / 'Templates'
            templates.mkdir()
            (templates / 'Letter.txt').write_text('Template content')
            (Path(s.env['XDG_CONFIG_HOME']) / 'user-dirs.dirs').write_text('XDG_TEMPLATES_DIR="$HOME/Templates"\n')
            providers = Path(s.env['XDG_DATA_HOME']) / 'phyto/actions'
            providers.mkdir(parents=True)
            record = home / 'provider-argv.json'
            script = home / 'record.py'
            script.write_text('import json,sys\nfrom pathlib import Path\nPath(' + repr(str(record)) + ').write_text(json.dumps(sys.argv[1:]))\n')
            (providers / 'record.action').write_text('[Phyto Action]\nName=Record arguments\nExec=/usr/bin/python3 "' + str(script) + '" %F\nSelection=single\n')
            (providers / 'unavailable.action').write_text('[Phyto Action]\nName=Unavailable provider\nExec=phyto-test-missing-executable %F\nSelection=single\n')
            app = s.child('phyto-context', [args.binary.resolve(), source], G_DEBUG='fatal-warnings')

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
                return settled()

            def click(label, kind='file', button='left', menu=False):
                v = probe()
                row = next((x for x in v['widgets'] if x['label'] == label and (x['menu'] if menu else x['kind'] == kind and (not x['menu']))))
                rect = windows()[0]['geometry']
                s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
                s.run(['wlrctl', 'pointer', 'move', str(round(rect['x'] + row['x'] + row['width'] / 2)), str(round(rect['y'] + row['y'] + row['height'] / 2))])
                s.run(['wlrctl', 'pointer', 'click', button])
                time.sleep(0.15)

            def capture(name):
                rect = windows()[0]['geometry']
                s.run(['grim', '-g', f"{rect['x']},{rect['y']} {rect['width']}x{rect['height']}", output / (name + '.png')])

            def passed(label):
                report['checks'].append(label)
                print('PASS', label, flush=True)
            settled()
            click('one.txt')
            key('c', 'ctrl')
            wait_for(lambda: probe()['clipboard_count'] == 1)
            navigate(dest)
            key('v', 'ctrl')
            time.sleep(0.5)
            wait_for(lambda: (dest / 'one.txt').exists())
            wait_for(lambda: not probe()['busy'])
            assert (dest / 'one.txt').read_bytes() == (source / 'one.txt').read_bytes()
            passed('System clipboard and explicit-destination copy')
            key('z', 'ctrl')
            wait_for(lambda: not (dest / 'one.txt').exists())
            key('z', 'ctrl', 'shift')
            wait_for(lambda: (dest / 'one.txt').exists())
            passed('Copy undo and redo')
            navigate(source)
            click('one.txt', button='right')
            v = probe()
            assert v['context_open'] and v['context_count'] == 1
            capture('file-menu-dark')
            key('Escape')
            assert not probe()['context_open']
            key('F10', 'shift')
            assert probe()['context_open']
            key('Escape')
            passed('Secondary-click and keyboard context menu')
            click('one.txt')
            key('a', 'ctrl')
            v = probe()
            assert v['selected'] == 3
            click('two.txt', button='right')
            v = probe()
            assert v['context_count'] == 3
            capture('multiple-selection')
            key('Escape')
            key('c', 'ctrl')
            wait_for(lambda: probe()['clipboard_count'] == 3)
            navigate(dest)
            key('v', 'ctrl')
            time.sleep(0.5)
            wait_for(lambda: any((w.get('title') == 'A file with this name already exists' for w in ipc.state())))
            key('Return')
            wait_for(lambda: (dest / 'Folder/nested.txt').exists() and (dest / 'two.txt').exists())
            wait_for(lambda: not probe()['busy'])
            assert (dest / 'Folder/loop').is_symlink()
            passed('Preserved multi-selection, recursive batch copy and collision Skip')
            navigate(source)
            key('2', 'ctrl')
            click('two.txt', button='right')
            assert probe()['context_count'] == 1
            capture('list-menu')
            key('Escape')
            click('two.txt')
            key('x', 'ctrl')
            wait_for(lambda: probe()['clipboard_cut'])
            target = home / 'Moved'
            target.mkdir()
            navigate(target)
            key('v', 'ctrl')
            wait_for(lambda: (target / 'two.txt').exists() and (not (source / 'two.txt').exists()))
            wait_for(lambda: not probe()['busy'])
            passed('Cut/paste moves sources only after successful transfer')
            key('z', 'ctrl')
            wait_for(lambda: (source / 'two.txt').exists() and (not (target / 'two.txt').exists()))
            passed('Move undo restores the original path')
            navigate(source)
            key('1', 'ctrl')
            click('Folder', button='right')
            capture('folder-menu')
            key('Escape')
            click('two.txt')
            key('c', 'ctrl')
            wait_for(lambda: probe()['clipboard_count'] == 1)
            click('Folder', button='right')
            click('Paste into folder', menu=True)
            wait_for(lambda: (source / 'Folder/two.txt').exists())
            wait_for(lambda: not probe()['busy'])
            passed('Paste into folder uses the clicked destination')
            rect = windows()[0]['geometry']
            s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
            s.run(['wlrctl', 'pointer', 'move', str(rect['x'] + 700), str(rect['y'] + 620)])
            s.run(['wlrctl', 'pointer', 'click', 'right'])
            v = probe()
            assert v['context_kind'] == 'background' and v['selected'] == 0
            capture('background-menu')
            click('New folder…', menu=True)
            text('Created from menu')
            key('Return')
            wait_for(lambda: (source / 'Created from menu').is_dir())
            wait_for(lambda: not probe()['busy'])
            passed('Background menu clears selection and creates a folder')
            navigate(source / 'Created from menu')
            rect = windows()[0]['geometry']
            s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
            s.run(['wlrctl', 'pointer', 'move', str(rect['x'] + 700), str(rect['y'] + 620)])
            s.run(['wlrctl', 'pointer', 'click', 'right'])
            click('New document', menu=True)
            click('Letter.txt', menu=True)
            wait_for(lambda: (source / 'Created from menu/Letter.txt').exists())
            wait_for(lambda: not probe()['busy'])
            assert (source / 'Created from menu/Letter.txt').read_text() == 'Template content'
            passed('New document template uses the captured destination and preserves content')
            navigate(source)
            click('Folder', button='right')
            click('Add bookmark', menu=True)
            config = Path(s.env['XDG_CONFIG_HOME']) / 'phyto/preferences.ini'
            wait_for(lambda: config.exists() and (source / 'Folder').as_uri() in config.read_text())
            passed('Folder bookmark is persisted')
            interop = home / 'External files'
            interop.mkdir()
            odd = interop / "spaces ü ' $(not-a-command).txt"
            odd.write_text('clipboard interop')
            clipboard = s.child('clipboard', ['wl-copy', '--foreground', '--type', 'x-special/gnome-copied-files'], input_pipe=True)
            clipboard.proc.stdin.write('copy\n' + odd.as_uri() + '\n')
            clipboard.proc.stdin.close()
            wait_for(lambda: odd.as_uri() in s.run(['wl-paste', '--type', 'x-special/gnome-copied-files']).stdout)
            external = home / 'External destination'
            external.mkdir()
            navigate(external)
            wait_for(lambda: probe()['clipboard_count'] == 1)
            key('v', 'ctrl')
            wait_for(lambda: (external / odd.name).exists())
            wait_for(lambda: not probe()['busy'])
            assert (external / odd.name).read_bytes() == odd.read_bytes()
            click(odd.name)
            key('x', 'ctrl')
            wait_for(lambda: probe()['clipboard_cut'])
            from urllib.parse import unquote, urlsplit
            payload = s.run(['wl-paste', '--type', 'x-special/gnome-copied-files']).stdout.splitlines()
            assert payload[0] == 'cut' and unquote(urlsplit(payload[1]).path) == str(external / odd.name)
            report['clipboard_formats'] = s.run(['wl-paste', '--list-types']).stdout.splitlines()
            passed('Cross-process clipboard copy and exported Cut intent preserve quoted Unicode filenames')
            navigate(external)
            click(odd.name, button='right')
            assert not any((w['label'] == 'Unavailable provider' for w in probe()['widgets']))
            click('Record arguments', menu=True)
            wait_for(record.exists)
            assert json.loads(record.read_text()) == [str(external / odd.name)]
            passed('Installed custom provider receives literal Unicode and shell-metacharacter arguments')
            navigate(source)
            trash_file = source / 'Trash fixture.txt'
            trash_file.write_text('recover me')
            wait_for(lambda: any((w['label'] == trash_file.name for w in probe()['widgets'])))
            click(trash_file.name, button='right')
            click('Move to Trash…', menu=True)
            key('Return')
            assert trash_file.exists()
            click(trash_file.name, button='right')
            click('Move to Trash…', menu=True)
            key('Tab')
            key('Return')
            wait_for(lambda: not trash_file.exists())
            wait_for(lambda: not probe()['busy'])
            key('l', 'ctrl')
            text('trash:///')
            key('Return')
            wait_for(lambda: not probe()['loading'])
            wait_for(lambda: any((w['label'] == trash_file.name for w in probe()['widgets'])))
            click(trash_file.name, button='right')
            capture('trash-menu')
            click('Restore', menu=True)
            wait_for(trash_file.exists)
            wait_for(lambda: not probe()['busy'])
            assert trash_file.read_text() == 'recover me'
            passed('Trash confirmation defaults to Cancel; Restore recovers original path and bytes')
            navigate(source)
            click('one.txt', button='right')
            (source / 'one.txt').unlink()
            wait_for(lambda: not probe()['context_open'])
            passed('Directory monitor invalidates stale menu targets')
            key('w', 'ctrl')
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
