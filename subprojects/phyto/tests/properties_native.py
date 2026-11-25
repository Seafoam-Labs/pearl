#!/usr/bin/env python3
"""Properties dialog layout and live permission editing in an isolated session."""
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
    p.add_argument('--output', type=Path, default=PROJECT / 'artifacts/properties/native')
    args = p.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {'status': 'running', 'checks': [], 'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest()}
    try:
        with PrivateSession(output / 'session', tool_prefix=fixture_prefix()) as s:
            s.env['GSETTINGS_BACKEND'] = 'memory'
            ipc = IPC(s)
            display = next(iter(ipc.outputs().values()))
            s.run(['wlr-randr', '--output', display['name'], '--custom-mode', '1600x1100@60Hz'])
            home = Path(s.env['HOME'])
            source = home / 'Source'
            source.mkdir()
            notes = source / 'notes.txt'
            notes.write_text('properties fixture\n')
            notes.chmod(0o644)
            album = source / 'Album'
            album.mkdir()
            (album / 'photo.txt').write_text('album bytes\n')
            rules = Path(s.env['XDG_CONFIG_HOME']) / 'aqueous/rules.toml'
            rules.write_text('[[window]]\napp_id = "org.aqueous.Phyto"\nfloating = true\nwidth = 1180\nheight = 760\n')
            ipc.call('command', action='session.reload', fields={})
            app = s.child('phyto-properties', [args.binary.resolve(), source], G_DEBUG='fatal-warnings')

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

            def probe():
                assert app.proc.poll() is None, app.lines[-10:]
                start = len(app.lines)
                key('F12')
                return json.loads(wait_for(lambda: next((x.removeprefix('PHYTO_PROBE ') for x in app.lines[start:] if x.startswith('PHYTO_PROBE ')), None), timeout=5))

            def settled():
                return wait_for(lambda: v if not (v := probe())['loading'] else False)

            def pointer(x, y, button='left'):
                s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
                s.run(['wlrctl', 'pointer', 'move', str(round(x)), str(round(y))])
                s.run(['wlrctl', 'pointer', 'click', button])
                time.sleep(0.15)

            def click(label, kind='file'):
                v = probe()
                row = next(x for x in v['widgets'] if x['label'] == label and x['kind'] == kind and not x['menu'])
                rect = windows()[0]['geometry']
                pointer(rect['x'] + row['x'] + row['width'] / 2, rect['y'] + row['y'] + row['height'] / 2)

            def capture(name):
                rect = next(w['geometry'] for w in ipc.state() if w['kind'] == 'window' and w.get('title') == 'Properties')
                s.run(['grim', '-g', f"{rect['x']},{rect['y']} {rect['width']}x{rect['height']}", output / (name + '.png')])

            def dialog_labels():
                return [w['label'] for w in probe()['properties_dialog_widgets']]

            def dialog_click(label, row=0):
                rows = sorted((w for w in probe()['properties_dialog_widgets'] if w['label'] == label), key=lambda w: w['y'])
                rect = next(w['geometry'] for w in ipc.state() if w['kind'] == 'window' and w.get('title') == 'Properties')
                widget = rows[row]
                pointer(rect['x'] + widget['x'] + widget['width'] / 2, rect['y'] + widget['y'] + widget['height'] / 2)

            def dialog_open():
                return wait_for(lambda: next((w for w in ipc.state() if w['kind'] == 'window' and w.get('title') == 'Properties'), None))

            def dialog_closed():
                return wait_for(lambda: not any(w.get('title') == 'Properties' for w in ipc.state() if w['kind'] == 'window'))

            def mode(path):
                return os.stat(path).st_mode & 0o7777

            def passed(label):
                report['checks'].append(label)
                print('PASS', label, flush=True)

            settled()
            click('notes.txt')
            assert probe()['selected'] == 1
            key('Return', 'alt')
            dialog_open()
            labels = dialog_labels()
            for expected in ['notes.txt', 'Type', 'Size', 'Location', 'Modified', 'Owner', 'Group', 'Permissions', 'Read', 'Write', 'Execute', 'Mode: 0644', 'Close']:
                assert expected in labels, (expected, labels)
            assert str(source) in labels
            capture('properties-file')
            passed('Single-file Properties shows a laid-out detail grid and permission controls')

            dialog_click('Execute', row=0)
            wait_for(lambda: mode(notes) == 0o744)
            assert 'Mode: 0744' in dialog_labels()
            dialog_click('Execute', row=0)
            wait_for(lambda: mode(notes) == 0o644)
            assert 'Mode: 0644' in dialog_labels()
            passed('Owner execute toggles apply to the file immediately and revert cleanly')

            dialog_click('Write', row=1)
            wait_for(lambda: mode(notes) == 0o664)
            dialog_click('Write', row=1)
            wait_for(lambda: mode(notes) == 0o644)
            dialog_click('Read', row=2)
            wait_for(lambda: mode(notes) == 0o640)
            dialog_click('Read', row=2)
            wait_for(lambda: mode(notes) == 0o644)
            passed('Group and other rows edit their own bits only')

            dialog_click('Close')
            dialog_closed()
            assert probe()['properties_dialog_widgets'] == []
            passed('Close dismisses the dialog')

            click('Album')
            key('Return', 'alt')
            dialog_open()
            labels = dialog_labels()
            assert 'Folder' in labels and 'Permissions' in labels
            assert any(l.startswith('Mode: 07') for l in labels), labels
            capture('properties-folder')
            key('Escape')
            dialog_closed()
            passed('Folder Properties reports the measured size and permissions; Escape closes')

            key('a', 'ctrl')
            wait_for(lambda: probe()['selected'] == 2)
            key('Return', 'alt')
            wait_for(lambda: probe()['message_dialog_widgets'])
            summary = ' '.join(w['label'] for w in probe()['message_dialog_widgets'])
            assert '2 selected' in summary and '1 folders' in summary, summary
            key('Escape')
            wait_for(lambda: not probe()['message_dialog_widgets'])
            passed('Multi-selection keeps the aggregate summary dialog')

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
