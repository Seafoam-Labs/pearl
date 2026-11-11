#!/usr/bin/env python3
"""M2 visual acceptance of real GTK widgets, never mockup/HTML panels.

  zig build visual -Doptimize=safe -j1
  zig build visual -Doptimize=safe -j1 -- --case dark-390

Requires the existing private Aqueous fixture, grim, wtype, PyGObject/Atspi,
Pillow and the installed org.a11y.Bus service. Accessibility runs on the PRIVATE
bus only, to locate actual controls for Wayland pointer input (no guessed pixels).
Each case has disposable HOME/XDG, real files and a headless Wayland compositor.
Cached binaries receive exact shipped source schemes in their private cwd.
Screenshots, hashes, geometry, accessibility trees and partial failures survive
in --output; no golden-image equality is claimed across GTK/font versions.
Follow Pearl without a running backend tests its documented fallback, NOT live
snapshot delivery. Live backend coverage is explicitly reported as unsupported.
"""
import argparse
import ast
import configparser
import hashlib
import json
import math
import shlex
import shutil
import signal
import sys
import time
import traceback
from pathlib import Path

from search import Harness, PROJECT, PEARL
from pearl_session import PrivateSession, fixture_prefix, wait_for
from test_surfaces import IPC
from wayland_test_input import pointer_move, pointer_click

WIDTHS = (1440, 1024, 700, 390)
HEIGHT = 900
MODES = {'dark': ('--dark', 0), 'light': ('--light', 1),
         'native': ('--native-theme', 2), 'follow': ('--follow-pearl', 3)}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def accessible_tree(pid):
    # This subprocess inherits ONLY PrivateSession.env, never the host a11y bus.
    import gi
    gi.require_version('Atspi', '2.0')
    from gi.repository import Atspi
    Atspi.set_timeout(1500, 3000)
    desktop = Atspi.get_desktop(0)
    app = wait_for(lambda: next((desktop.get_child_at_index(i)
                               for i in range(desktop.get_child_count())
                               if desktop.get_child_at_index(i).get_process_id() == pid), None), 5)
    rows = []

    def visit(node, depth=0, parent=None):
        if depth > 32 or len(rows) >= 4096:
            raise AssertionError('Unbounded accessibility tree')
        states = node.get_state_set()
        row = dict(name=node.get_name(), role=node.get_role_name(), parent=parent,
                   showing=states.contains(Atspi.StateType.SHOWING),
                   sensitive=states.contains(Atspi.StateType.SENSITIVE))
        component = node.get_component_iface()
        if component:
            r = component.get_extents(Atspi.CoordType.WINDOW)
            row['bounds'] = dict(x=r.x, y=r.y, width=r.width, height=r.height)
        index = len(rows)
        rows.append(row)
        for i in range(node.get_child_count()):
            child = node.get_child_at_index(i)
            if child:
                visit(child, depth + 1, index)
    visit(app)
    print(json.dumps(rows))


def contained(inner, outer):
    assert all(math.isfinite(inner[k]) for k in ('x', 'y', 'width', 'height')), inner
    assert inner['width'] > 0 and inner['height'] > 0, inner
    assert inner['x'] >= outer['x'] - 1 and inner['y'] >= outer['y'] - 1, (inner, outer)
    assert inner['x'] + inner['width'] <= outer['x'] + outer['width'] + 1, (inner, outer)
    assert inner['y'] + inner['height'] <= outer['y'] + outer['height'] + 1, (inner, outer)


class VisualHarness(Harness):
    def __init__(self, session, args, case, report):
        self.session, self.output, self.evidence = session, args.output, report
        self.case, self.name = case, case['name']
        self.ipc, self.last = IPC(session), {}
        self.deadline = time.monotonic() + 100
        self.expected, self.protected = {}, {}
        self.fixtures = session.base / 'visual-fixtures'
        self.fixtures.mkdir()
        self.command_path = self.fixtures / 'command.ini'
        session.env.update(CORAL_TEST_COMMAND=str(self.command_path), GSETTINGS_BACKEND='memory',
                           GTK_A11Y='atspi', LANG='C.UTF-8', LC_ALL='C.UTF-8', LANGUAGE='en')
        self.start_accessibility()
        config = Path(session.env['XDG_CONFIG_HOME'])
        gtk = config / 'gtk-4.0'
        gtk.mkdir()
        (gtk / 'settings.ini').write_text('[Settings]\ngtk-theme-name=Adwaita\ngtk-font-name=Sans ' +
                                          str(case['font']) + '\ngtk-enable-animations=false\n')
        resources = session.base / 'resources'
        resources.mkdir()
        case['schemes'] = []
        for name in ('coral-dark.xml', 'coral-light.xml'):
            source, dest = PROJECT / 'resources' / name, resources / name
            shutil.copyfile(source, dest)
            assert digest(source) == digest(dest)
            case['schemes'].append(dict(file=name, sha256=digest(dest)))
        display = next(iter(self.ipc.outputs().values()))
        session.run(['wlr-randr', '--output', display['name'], '--custom-mode', '1800x1200@60Hz'])
        rules = config / 'aqueous/rules.toml'
        rules.write_text('[[window]]\napp_id = "org.aqueous.Coral"\nfloating = true\n' +
                         f'width = {case["width"]}\nheight = {HEIGHT}\n')
        self.ipc.call('command', action='session.reload', fields={})
        self.root = self.fixtures / 'coral-workbench'
        self.sample = self.write(self.root / 'welcome.md',
                                 '# Coral workbench\n\nA native workspace for small, careful changes.\n\n'
                                 '## Visual acceptance\n\n- Real files and editor buffers\n'
                                 '- Explorer and workspace search\n- Local settings and trust\n\n'
                                 'Search token: native-visual-marker\n')
        self.write(self.root / 'src' / 'main.zig', 'const std = @import("std");\n\npub fn main() void {\n    std.debug.print("Hello Coral\\n", .{});\n}\n')
        self.write(self.root / 'notes.txt', 'A second real document.\n')
        self.app = session.child(self.name, [args.binary, MODES[case['mode']][0],
                                           f'--width={case["width"]}', f'--height={HEIGHT}',
                                           '--folder', self.root, self.sample], G_DEBUG='fatal-criticals')
        window = wait_for(lambda: next(iter(self.windows()), None))
        self.window_id = window['id']
        self.ipc.call('command', action='window.activate', fields={'id': self.window_id})
        wait_for(lambda: self.probe('workspace')['documents'])
        self.browser()
        self.command('browser-activate', index=0)
        browser = self.browser()
        assert {e['name'] for e in browser['entries']} == {'welcome.md', 'notes.txt', 'src'}, browser
        self.command('focus-editor')
        self.tree()
        case['fixtures'] = {str(p.relative_to(self.fixtures)): value for p, value in self.expected.items()}
        case['isolation'] = {key: session.env[key] for key in
                             ('HOME', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'XDG_RUNTIME_DIR',
                              'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS', 'AT_SPI_BUS_ADDRESS')}

    def start_accessibility(self):
        service = Path('/usr/share/dbus-1/services/org.a11y.Bus.service')
        parser = configparser.ConfigParser()
        assert parser.read(service), 'Install the AT-SPI accessibility bus service'
        argv = shlex.split(parser['D-BUS Service']['Exec'])
        self.session.child('accessibility', argv)
        self.session.run(['gdbus', 'wait', '--session', '--timeout', '5', 'org.a11y.Bus'])
        reply = self.session.run(['gdbus', 'call', '--session', '--dest', 'org.a11y.Bus',
                                  '--object-path', '/org/a11y/bus', '--method', 'org.a11y.Bus.GetAddress']).stdout
        assert str(self.session.runtime) in reply or str(self.session.base) in reply, reply
        address = ast.literal_eval(reply)[0]
        self.session.env['AT_SPI_BUS_ADDRESS'] = address
        # The host's registry service may request systemd activation. Start it
        # explicitly against this bus instead; never contact a user manager.
        registry = configparser.ConfigParser()
        service = Path('/usr/share/dbus-1/accessibility-services/org.a11y.atspi.Registry.service')
        assert registry.read(service), 'Install the AT-SPI registry service'
        executable = shlex.split(registry['D-BUS Service']['Exec'])[0]
        self.session.child('accessibility-registry', [executable])
        self.session.run(['gdbus', 'wait', '--address', address, '--timeout', '5', 'org.a11y.atspi.Registry'])

    def windows(self):
        return [w for w in self.ipc.state() if w['kind'] == 'window']

    def window(self):
        return next(w for w in self.windows() if w['id'] == self.window_id)

    def tree(self):
        result = self.session.run([sys.executable, Path(__file__).resolve(), '--a11y-pid', str(self.app.proc.pid)])
        return json.loads(result.stdout)

    def control(self, name):
        rows = self.tree()
        matches = [r for r in rows if r['showing'] and r['name'] == name and
                   r['role'] in ('button', 'push button', 'toggle button', 'menu item', 'push button menu')]
        # GtkMenuButton exposes both its wrapper and inner toggle at the same
        # allocation. They represent one hit target, not ambiguous controls.
        unique = {tuple(r['bounds'].values()): r for r in matches}
        matches = list(unique.values())
        assert len(matches) == 1, ('Expected one visible control', name, matches)
        row = matches[0]
        assert row['sensitive'], row
        return row

    def click(self, name):
        row = self.control(name)
        r, window = row['bounds'], self.window()['geometry']
        contained(r, dict(x=0, y=0, width=window['width'], height=window['height']))
        pointer_move(self.session, window['x'] + r['x'] + r['width'] / 2,
                     window['y'] + r['y'] + r['height'] / 2)
        pointer_click(self.session)
        self.case.setdefault('clicks', []).append(row)
        time.sleep(.12)

    def menu_item(self, index, count):
        # GTK 4 may omit GMenu item names from AT-SPI. Use the native ordered
        # menu allocations, and verify the dispatched action's actual effect.
        rows = [r for r in self.tree() if r['showing'] and r['role'] == 'menu item']
        assert len(rows) == count, rows
        row, window = rows[index], self.window()['geometry']
        r = row['bounds']
        absolute = dict(r, x=window['x'] + r['x'], y=window['y'] + r['y'])
        contained(absolute, self.ipc.outputs()[self.window()['output']]['bounds'])
        assert row['sensitive'], row
        pointer_move(self.session, absolute['x'] + r['width'] / 2, absolute['y'] + r['height'] / 2)
        pointer_click(self.session)
        self.case.setdefault('menu_clicks', []).append(dict(index=index, count=count, row=row))

    def dock(self):
        previous, since = None, time.monotonic()
        def ready():
            nonlocal previous, since
            p = self.probe('dock')
            if previous != p:
                previous, since = p, time.monotonic()
            return p if time.monotonic() - since >= .12 else None
        return wait_for(ready, 6)

    def geometry(self, p, width):
        assert (p['width'], p['height']) == (width, HEIGHT), ('Requested allocation not honored', width, p)
        rect = self.window()['geometry']
        contained(rect, self.ipc.outputs()[self.window()['output']]['bounds'])
        assert (rect['width'], rect['height']) == (width, HEIGHT), rect
        editor = p['editor_bounds']
        contained(editor, dict(x=0, y=0, width=width, height=HEIGHT))
        assert p['editor_width'] >= 240 and p['editor_height'] >= 165, p
        assert abs(editor['width'] - p['editor_width']) <= 1, p
        assert abs(editor['height'] - p['editor_height']) <= 1, p
        assert p['editor_group_bounds'], p
        for group in p['editor_group_bounds']:
            contained(group, editor)
        assert p['desired']['explorer'] == 'left', p
        if width == 390:
            assert p['bottom_visible'] and not p['left_visible'] and not p['right_visible'], p
        else:
            assert p['left_visible'] and not p['bottom_visible'], p
        rows = self.tree()
        # These are allocated native controls, not synthetic probe rectangles.
        controls = []
        for name in (self.root.name, 'Command Palette · Ctrl+Shift+P', 'Editor menu'):
            row = self.control(name)
            r = row['bounds']
            contained(r, dict(x=0, y=0, width=width, height=HEIGHT))
            assert r['width'] >= 24 and r['height'] >= 24, row
            for other in controls:
                overlap_x = min(r['x'] + r['width'], other['x'] + other['width']) - max(r['x'], other['x'])
                overlap_y = min(r['y'] + r['height'], other['y'] + other['height']) - max(r['y'], other['y'])
                assert overlap_x <= 1 or overlap_y <= 1, ('Overlapping header controls', r, other)
            controls.append(r)
        self.case.setdefault('geometry', []).append(p)
        self.case['accessibility'] = rows

    def capture(self, label, state=None):
        from PIL import Image
        path = self.output / 'screenshots' / f'{self.name}-{label}.png'
        path.parent.mkdir(exist_ok=True)
        rect = self.window()['geometry']
        contained(rect, self.ipc.outputs()[self.window()['output']]['bounds'])
        self.session.run(['grim', '-g', f"{rect['x']},{rect['y']} {rect['width']}x{rect['height']}", path])
        with Image.open(path) as image:
            assert image.size == (rect['width'], rect['height']), (image.size, rect)
            assert len(image.convert('RGB').getcolors(image.width * image.height)) > 32, 'Blank/flat screenshot'
        entry = dict(path=str(path), sha256=digest(path), geometry=rect, state=state)
        self.case.setdefault('captures', []).append(entry)
        if label in ('command-center', 'workspace-selector', 'overflow', 'preferences', 'failure'):
            # Popovers and transient windows may legitimately extend outside the
            # main window. Keep the complete native output as well as its crop.
            full = path.with_name(path.stem + '-output.png')
            connector = self.ipc.outputs()[self.window()['output']]['name']
            self.session.run(['grim', '-o', connector, full])
            entry['output_path'], entry['output_sha256'] = str(full), digest(full)
        return path

    def palette_window(self):
        return next((w for w in self.windows() if w.get('title') == 'Command Palette…'), None)

    def controls(self):
        before = self.probe('workspace')
        self.click('Command Palette · Ctrl+Shift+P')
        wait_for(self.palette_window)
        self.capture('command-center')
        self.text('New Document')
        self.key('Return')
        wait_for(lambda: not self.palette_window())
        after = self.probe('workspace')
        assert len(after['documents']) == len(before['documents']) + 1, (before, after)
        self.key('w', 'ctrl')
        wait_for(lambda: len(self.probe('workspace')['documents']) == len(before['documents']))
        self.case.setdefault('checks', []).append('command center click, filter and dispatch')
        self.click(self.root.name)
        self.capture('workspace-selector')
        self.menu_item(-1, 7)  # Close workspace (keep documents).
        wait_for(lambda: not self.probe('browser')['roots'])
        self.command('open-folder', self.root)
        self.browser()
        self.case['checks'].append('workspace selector closes and reopens real workspace')
        self.click('Editor menu')
        self.capture('overflow')
        self.menu_item(0, 7)  # Command Palette, followed by six categories including Language.
        wait_for(self.palette_window)
        self.text('Preferences')
        self.key('Return')
        wait_for(lambda: not self.palette_window() and self.probe('workspace')['dialog'])
        self.capture('preferences')
        self.command('respond', response=0)
        wait_for(lambda: not self.probe('workspace')['dialog'])
        self.case['checks'].append('overflow menu dispatches palette and preferences')

    def run_case(self):
        width = self.case['width']
        p = self.dock()
        image = self.capture('workbench', p)  # Preserve rendering even if geometry fails.
        self.geometry(p, width)
        from PIL import Image
        r = p['editor_bounds']
        with Image.open(image) as screenshot:
            pixels = screenshot.convert('RGB').crop((int(r['x'] + 40), int(r['y'] + 50),
                                                     int(r['x'] + r['width'] - 8),
                                                     int(r['y'] + r['height'] - 8)))
            count, color = max(pixels.getcolors(pixels.width * pixels.height))
        # The dominant editor surface must actually render the selected mode;
        # no exact palette values, which legitimately evolve with the visual pass.
        self.case['editor_surface'] = dict(rgb=color, fraction=count / (pixels.width * pixels.height))
        assert count / (pixels.width * pixels.height) > .35, self.case['editor_surface']
        brightness = sum(color) / 3
        if self.case['mode'] in ('dark', 'follow'):
            assert brightness < 120, ('Dark mode rendered a light editor', color)
        else:
            assert brightness > 180, ('Light/native Adwaita rendered a dark editor', color)
        state = self.probe('workspace')
        assert state['settings']['theme'] == MODES[self.case['mode']][1], state
        assert state['editor_font_size'] > 0, state
        self.case['editor_font_size'] = state['editor_font_size']
        self.case['editor_font_absolute'] = state['editor_font_absolute']
        self.case.setdefault('checks', []).append('usable native editor, dock and header geometry')
        self.controls()
        self.command('focus-search')
        self.command('dock-right')
        self.query('native-visual-marker')
        search = self.settled()
        assert search['complete'] and len(search['results']) == 1, search
        self.capture('search', self.dock())
        if width == 390:
            p = self.dock()
            assert p['desired']['search'] == 'right' and p['bottom_visible'], p
            assert not p['left_visible'] and not p['right_visible'], p
            # Hide and reopen the compact bottom drawer through real controls.
            self.click('Hide panel')
            assert not self.dock()['search_visible']
            self.click('Workspace search · Ctrl+Shift+F')
            assert self.dock()['search_visible']
            self.command('window-resize', width=1024, height=HEIGHT)
            wait_for(lambda: self.probe('dock')['width'] == 1024)
            p = self.dock()
            assert p['desired']['explorer'] == 'left' and p['desired']['search'] == 'right', p
            assert p['left_visible'] and p['right_visible'] and not p['bottom_visible'], p
            assert p['editor_width'] >= 240 and p['editor_height'] >= 165, p
            self.capture('restored-side-placement', p)
            self.case['checks'].append('compact drawer toggles and restores desired left/right placement')
        self.case['checks'].append('real workspace search result')
        for path, expected in self.expected.items():
            assert digest(path) == expected, ('Fixture modified', path)
        self.no_criticals()
        assert not any('Failed to load style' in line or 'Theme parser error' in line for line in self.app.lines), self.app.lines[-30:]
        self.key('q', 'ctrl')
        assert self.app.wait(15) == 0, self.app.lines[-30:]
        self.no_criticals()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-visual')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    parser.add_argument('--case', action='append', help='Run only a named case (repeatable)')
    args = parser.parse_args()
    args.binary, args.output = args.binary.resolve(), args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    cases = [dict(name=f'{mode}-{width}', mode=mode, width=width, font=11)
             for mode in ('dark', 'light') for width in WIDTHS]
    cases += [dict(name=f'{mode}-{width}-font{font}', mode=mode, width=width, font=font)
              for mode in ('native', 'follow') for width in (1024, 390) for font in (11, 22)]
    if args.case:
        assert set(args.case) <= {c['name'] for c in cases}, ('Unknown case', args.case)
        cases = [c for c in cases if c['name'] in args.case]
    report = dict(status='running', binary=str(args.binary), binary_sha256=digest(args.binary),
                  cases=cases, limitations=['Headless Cairo rendering, not physical GPU/display acceptance.',
                  'No pixel-identical golden comparison across font/GTK versions.'],
                  unsupported=[dict(check='Follow Pearl live committed palette/font delivery',
                                    reason='No Pearl backend is launched; follow cases verify documented offline fallback and GTK font compatibility.')])
    def save():
        (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    save()
    def expired(*_):
        raise TimeoutError('Visual case exceeded its 120-second budget')
    signal.signal(signal.SIGALRM, expired)
    for case in cases:
        case['status'] = 'running'
        print('RUN', case['name'], flush=True)
        h = None
        try:
            with PrivateSession(args.output / 'sessions' / case['name'], tool_prefix=args.aqueous_prefix) as session:
                try:
                    signal.alarm(120)
                    h = VisualHarness(session, args, case, report)
                    h.run_case()
                    case['status'] = 'passed'
                except Exception:
                    if h is not None:
                        try:
                            h.capture('failure')
                            case['failure_tree'] = h.tree()
                        except Exception as exc:
                            case['capture_error'] = repr(exc)
                    else:
                        path = args.output / 'screenshots' / (case['name'] + '-startup-failure.png')
                        path.parent.mkdir(exist_ok=True)
                        session.run(['grim', path], check=False)
                        case['startup_failure_capture'] = str(path)
                    raise
                finally:
                    signal.alarm(0)
        except Exception:
            case['status'], case['failure'] = 'failed', traceback.format_exc()
            print(case['failure'], file=sys.stderr, flush=True)
        print(case['status'].upper(), case['name'], flush=True)
        save()
    report['font_scaling'] = []
    for mode in ('native', 'follow'):
        for width in (1024, 390):
            pair = [next((c for c in cases if c['name'] == f'{mode}-{width}-font{font}'), None)
                    for font in (11, 22)]
            if not all(c and c.get('editor_font_size') for c in pair):
                continue
            normal, enlarged = pair
            ratio = enlarged['editor_font_size'] / normal['editor_font_size']
            good = 1.9 <= ratio <= 2.1 and normal['editor_font_absolute'] == enlarged['editor_font_absolute']
            report['font_scaling'].append(dict(mode=mode, width=width, ratio=ratio, status='passed' if good else 'failed'))
            if not good:
                enlarged['status'] = 'failed'
                enlarged['failure'] = f'GTK font doubling did not propagate to native editor: ratio={ratio}'
    report['status'] = 'passed' if all(c['status'] == 'passed' for c in cases) else 'failed'
    save()
    print('Evidence:', args.output / 'results.json', flush=True)
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--a11y-pid':
        accessible_tree(int(sys.argv[2]))
    else:
        sys.exit(main())
