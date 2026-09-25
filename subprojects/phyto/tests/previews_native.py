#!/usr/bin/env python3
"""Preview UI, lifetime and virtualization checks in a private native session."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time
from urllib.parse import unquote

from previews_helper import check as helper_checks, png

PROJECT = Path(__file__).resolve().parents[1]
PEARL = PROJECT.parents[1]
sys.path[:0] = [str(PEARL / 'scripts'), str(PEARL / 'tests/integration')]
from pearl_session import PrivateSession, wait_for
from test_surfaces import IPC


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=PROJECT / 'artifacts/previews')
    args = parser.parse_args()
    binary, output = args.binary.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {'status': 'running', 'checks': [], 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
    try:
        helper_checks(binary)
        report['checks'].append('Isolated helper/cache checks')
        with PrivateSession(output / 'session', tool_prefix=PEARL / '.cache/aqueous-activity-production') as s:
            s.env['GSETTINGS_BACKEND'] = 'memory'
            ipc = IPC(s)
            display = next(iter(ipc.outputs().values()))
            s.run(['wlr-randr', '--output', display['name'], '--custom-mode', '1600x1100@60Hz'])
            home = Path(s.env['HOME'])
            source = home / 'Previews'
            source.mkdir()
            png(source / '01 landscape.png')
            png(source / '02 portrait.png', 120, 320, (30, 160, 90, 255))
            (source / '03 notes.txt').write_text('Hello preview\n<script>source only</script>\n')
            (source / '04 corrupt.png').write_bytes(b'\x89PNG\r\n\x1a\ncorrupt')
            (source / '05 unknown.bin').write_bytes(b'\0binary')
            (source / '06 link.png').symlink_to(source / '01 landscape.png')
            many = home / 'Many'
            many.mkdir()
            for i in range(10000):
                if i % 2:
                    (many / f'{i:05}.txt').write_text('text')
                else:
                    png(many / f'{i:05}.png', 24, 18, (i % 255, 60, 180, 255))
            rules = Path(s.env['XDG_CONFIG_HOME']) / 'aqueous/rules.toml'
            rules.write_text('[[window]]\napp_id = "org.aqueous.Phyto"\nfloating = true\nwidth = 1180\nheight = 760\n')
            ipc.call('command', action='session.reload', fields={})
            app = s.child('phyto-previews', [binary, source], G_DEBUG='fatal-warnings')

            def windows():
                return [w for w in ipc.state() if w['kind'] == 'window' and w.get('app_id') == 'org.aqueous.Phyto']

            win = wait_for(lambda: next(iter(windows()), None))
            ipc.call('command', action='window.activate', fields={'id': win['id']})

            def key(k, *mods):
                argv = ['wtype', '-s', '50']
                for mod in mods:
                    argv += ['-M', mod]
                argv += ['-k', k]
                for mod in reversed(mods):
                    argv += ['-m', mod]
                s.run(argv)

            def probe():
                assert app.proc.poll() is None, app.lines[-20:]
                start = len(app.lines)
                key('F12')
                return json.loads(wait_for(lambda: next((line[12:] for line in app.lines[start:] if line.startswith('PHYTO_PROBE ')), None), timeout=5))

            def settled():
                return wait_for(lambda: v if not (v := probe())['loading'] else False)

            def click(label, kind='file', button='left', menu=False):
                state = probe()
                row = next(x for x in state['widgets'] if x['label'] == label and (x['menu'] if menu else x['kind'] == kind and not x['menu']))
                rect = win['geometry']
                s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
                s.run(['wlrctl', 'pointer', 'move', str(round(rect['x'] + row['x'] + row['width'] / 2)), str(round(rect['y'] + row['y'] + row['height'] / 2))])
                s.run(['wlrctl', 'pointer', 'click', button])
                time.sleep(.1)

            def navigate(path):
                key('l', 'ctrl')
                s.run(['wtype', '-s', '100', '--', str(path)])
                key('Return')
                return settled()

            def capture(name):
                probe()
                time.sleep(.2)  # allow the queued GTK frame to reach the compositor
                rect = win['geometry']
                path = output / f'{name}.png'
                def frame():
                    s.run(['grim', '-g', f"{rect['x']},{rect['y']} {rect['width']}x{rect['height']}", path])
                    if name not in ('quick-image', 'quick-text'):
                        return True
                    # Readiness alone is insufficient: verify the synthetic
                    # magenta image actually reached the compositor's frame.
                    from PIL import Image
                    with Image.open(path) as image:
                        if name == 'quick-text':
                            region = image.convert('RGB').crop((400, 250, 800, 450))
                            return sum(count for count, color in region.getcolors(region.width * region.height) if color == (33, 31, 38)) > 75000
                        return sum(count for count, (r, g, b) in image.convert('RGB').getcolors(image.width * image.height) if r > 80 and g < 90 and b > 40 and r > 1.5 * g) > 150000
                wait_for(frame, timeout=4)

            def passed(label):
                report['checks'].append(label)
                print('PASS', label, flush=True)

            def correct_rows():
                state = probe()
                for row in state['widgets']:
                    if row['thumbnail_uri']:
                        assert unquote(row['thumbnail_uri']).endswith('/' + row['label']), row
                assert state['preview_memory'] <= 64 * 1024 * 1024
                assert state['preview_jobs'] <= 2
                return state

            settled()
            wait_for(lambda: probe()['thumbnail_slots_ready'] >= 2, timeout=15)
            click('01 landscape.png')
            wait_for(lambda: probe()['thumbnail_slots_ready'] >= 3)
            capture('grid-details-dark')
            correct_rows()
            key('a', 'ctrl')
            assert probe()['selected'] == 6
            key('space')
            assert not probe()['quick_preview']
            click('01 landscape.png')
            key('space')
            wait_for(lambda: probe()['quick_kind'] == 'image', timeout=10)
            capture('quick-image')
            assert probe()['quick_surface'] == 'image'
            key('Escape')
            assert not probe()['quick_preview']
            click('03 notes.txt')
            key('space')
            wait_for(lambda: probe()['quick_kind'] == 'text')
            assert probe()['quick_surface'] == 'text'
            capture('quick-text')
            key('Escape')
            click('04 corrupt.png')
            key('space')
            wait_for(lambda: probe()['quick_kind'] == 'unavailable')
            key('Escape')
            passed('Image/text quick preview, corruption fallback, Escape and focus restoration')

            click('01 landscape.png', button='right')
            click('Preview', kind='label', menu=True)
            wait_for(lambda: probe()['quick_kind'] == 'image')
            png(source / '01 landscape.png', 180, 180, (50, 60, 220, 255))
            wait_for(lambda: probe()['quick_kind'] == 'image')
            (source / '01 landscape.png').unlink()
            wait_for(lambda: probe()['quick_kind'] == 'pending')
            key('Escape')
            png(source / '01 landscape.png')
            key('F5')
            settled()
            key('2', 'ctrl')
            wait_for(lambda: probe()['thumbnail_slots_ready'] >= 2)
            correct_rows()
            capture('list')
            key('1', 'ctrl')
            key('F3')
            assert not probe()['details']
            click('02 portrait.png')
            key('space')
            wait_for(lambda: probe()['quick_kind'] == 'image')
            key('Escape')
            key('F3')
            passed('Context Preview, monitored replacement/removal, list view and split preview')

            # Background menu toggles persist and clear existing subscriptions.
            def toggle(label):
                time.sleep(.3)  # allow the previous native popover to finish closing
                rect = win['geometry']
                s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
                s.run(['wlrctl', 'pointer', 'move', str(rect['x'] + 650), str(rect['y'] + 650)])
                s.run(['wlrctl', 'pointer', 'click', 'right'])
                wait_for(lambda: probe()['context_open'])
                click(label, kind='label', menu=True)
            toggle('Show thumbnails')
            toggle('Preview in details')
            wait_for(lambda: probe()['thumbnail_slots_ready'] == 0)
            assert not probe()['thumbnails_enabled'] and not probe()['details_preview_enabled']
            click('01 landscape.png')
            key('space')
            wait_for(lambda: probe()['quick_kind'] == 'image')
            key('Escape')
            toggle('Show thumbnails')
            toggle('Preview in details')
            wait_for(lambda: probe()['thumbnail_slots_ready'] >= 2)
            passed('Persisted automatic-preview toggles; explicit Preview remains available')

            start = time.monotonic()
            navigate(many)
            wait_for(lambda: probe()['thumbnail_slots_ready'] > 0, timeout=15)
            cold = correct_rows()
            # Visiting 10,000 files must not schedule 10,000 decodes.
            assert cold['preview_started'] < 300, cold['preview_started']
            key('End')
            key('Home')
            key('End')
            wait_for(lambda: probe()['preview_jobs'] == 0, timeout=15)
            correct_rows()
            key('2', 'ctrl')
            key('Home')
            wait_for(lambda: probe()['preview_jobs'] == 0, timeout=15)
            state = correct_rows()
            report['large_directory'] = {'entries': 10000, 'elapsed_seconds': round(time.monotonic() - start, 3), 'jobs_started': state['preview_started'], 'texture_bytes': state['preview_memory'], 'cache_hits': state['preview_cache_hits'], 'max_main_loop_gap_us_during_jobs': state['preview_max_main_loop_gap_us']}
            passed('10,000 mixed files: viewport scheduling, recycling and resource budgets')

            navigate(source)
            key('1', 'ctrl')
            key('t', 'ctrl')
            navigate(many)
            key('w', 'ctrl')
            assert probe()['title'] == 'Previews'
            key('n', 'ctrl')
            wait_for(lambda: len(windows()) == 2)
            key('w', 'ctrl')
            wait_for(lambda: len(windows()) == 1)
            ipc.call('command', action='window.activate', fields={'id': win['id']})
            navigate(many)
            key('w', 'ctrl')
            assert app.wait(timeout=15) == 0, app.lines[-20:]
            assert not any(word in line for line in app.lines for word in ['WARNING', 'CRITICAL', 'panic:']), app.lines[-20:]
            passed('Tab/window changes and shutdown during outstanding decode work')
            wait_for(lambda: not windows())
            for label, flags, width, scale in [
                ('light', ['--light'], 1180, 1),
                ('compact', ['--compact'], 1180, 1),
                ('native-theme', ['--native-theme'], 1180, 1),
                ('narrow', [], 560, 1),
                ('scale-2', [], 1180, 2),
            ]:
                s.run(['wlr-randr', '--output', display['name'], '--custom-mode', '2400x1600@60Hz', '--scale', str(scale)])
                rules.write_text(f'[[window]]\napp_id = "org.aqueous.Phyto"\nfloating = true\nwidth = {width}\nheight = 760\n')
                ipc.call('command', action='session.reload', fields={})
                app = s.child('phyto-preview-' + label, [binary, f'--width={width}', *flags, source], G_DEBUG='fatal-warnings')
                win = wait_for(lambda: next(iter(windows()), None))
                ipc.call('command', action='window.activate', fields={'id': win['id']})
                settled()
                wait_for(lambda: probe()['thumbnail_slots_ready'] >= 2, timeout=15)
                assert probe()['thumbnails_enabled'] and probe()['details_preview_enabled']
                correct_rows()
                capture(label)
                click('01 landscape.png')
                key('space')
                wait_for(lambda: probe()['quick_kind'] == 'image')
                key('Escape')
                if width < 1000:
                    assert not probe()['details']
                key('w', 'ctrl')
                assert app.wait(timeout=15) == 0, app.lines[-20:]
                wait_for(lambda: not windows())
            passed('Light/native themes, compact/narrow layouts, 2× scale and persisted preferences')
            slow = home / 'Slow'
            slow.mkdir()
            png(slow / 'slow.png')
            app = s.child('phyto-cancel-preview', [binary, slow], G_DEBUG='fatal-warnings', PHYTO_TEST_PREVIEW_DELAY_MS='3000')
            win = wait_for(lambda: next(iter(windows()), None))
            ipc.call('command', action='window.activate', fields={'id': win['id']})
            wait_for(lambda: probe()['preview_jobs'] == 1)
            started_close = time.monotonic()
            key('w', 'ctrl')
            assert app.wait(timeout=3) == 0, app.lines[-20:]
            assert time.monotonic() - started_close < 2
            wait_for(lambda: not windows())
            app = s.child('phyto-timeout-preview', [binary, slow], G_DEBUG='fatal-warnings', PHYTO_TEST_PREVIEW_DELAY_MS='6000')
            win = wait_for(lambda: next(iter(windows()), None))
            ipc.call('command', action='window.activate', fields={'id': win['id']})
            wait_for(lambda: probe()['preview_jobs'] == 1)
            wait_for(lambda: probe()['preview_jobs'] == 0, timeout=8)
            assert probe()['thumbnail_slots_ready'] == 0
            key('w', 'ctrl')
            assert app.wait(timeout=3) == 0, app.lines[-20:]
            passed('Deterministic in-flight cancellation and decoder timeout preserve responsive UI')
            ipc.close()
        report['status'] = 'passed'
    except Exception as error:
        report['status'] = 'failed'
        report['error'] = str(error)
        raise
    finally:
        (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
