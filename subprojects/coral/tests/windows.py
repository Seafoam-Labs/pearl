#!/usr/bin/env python3
"""Native multiwindow acceptance, using only a private Wayland/D-Bus/HOME/XDG.

From subprojects/coral, choose a fresh prefix (also for concurrent builds):
  zig build -Dtest-hooks=true -Doptimize=safe --prefix .cache/windows-local/install -j2
  python3 tests/windows.py --binary .cache/windows-local/install/bin/coral

F11 routes fixture commands/probes by stable registry ID, independently of focus.
Shortcuts and the palette use real Wayland input. win.* tests use GTK's exported
org.gtk.Actions window group, discovered on the private bus and verified against
this process's PID; they do NOT inject App.execute via the command-file hook.
No cross-window tab transfer or shared document model is assumed. Bounded RSS/FD
checks detect growth, not a claim of exhaustive leak freedom. Partial results,
exact assertions, native logs, fixture hashes and screenshots survive failures.
Cached build artifacts use the relative development style path `resources`;
the private working directory receives exact copies of the shipped XML schemes.
"""
import argparse
import ast
import base64
from collections import Counter
from contextlib import contextmanager
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import traceback
from pathlib import Path

from search import Harness, PEARL
from policy import BudgetExpired, PolicyHarness, save
from sessions import digest
from docks import contents, geometry, decode_slot
from app_recovery import manifest, locked
from pearl_session import PrivateSession, fixture_prefix, wait_for
from wayland_test_input import pointer_move, pointer_click


def stage_styles(session, evidence):
    """Supply the uninstalled artifact's relative resource path in its private cwd.

    Zig's addOptionPathDirectory emits "resources", not an absolute source path.
    Installed binaries find ../share/coral/styles; cached coral-test binaries
    instead depend on this cwd-relative fallback. Never change the app's cwd to
    the real repository, synthesize a scheme, or suppress missing-style warnings.
    """
    directory = session.base / 'resources'
    directory.mkdir()
    sources = Path(__file__).resolve().parents[1] / 'resources'
    staged = []
    for name in ('coral-dark.xml', 'coral-light.xml'):
        source, target = sources / name, directory / name
        expected = digest(source.read_bytes())
        shutil.copyfile(source, target)
        assert digest(target.read_bytes()) == expected, (source, target)
        staged.append(dict(source=str(source), path=str(target), sha256=expected))
    evidence['style_fixture'] = dict(cwd=str(session.base), development_path='resources', files=staged)
    return staged


def start_accessibility(session):
    """Expose only this disposable session's native widgets, never the host bus."""
    session.child('accessibility-bus', ['/usr/lib/at-spi-bus-launcher', '--launch-immediately'])
    wait_for(lambda: 'org.a11y.Bus' in session.run(
        ['busctl', '--address=' + session.env['DBUS_SESSION_BUS_ADDRESS'], 'list']).stdout)
    address = ast.literal_eval(session.run([
        'gdbus', 'call', '--session', '--dest', 'org.a11y.Bus', '--object-path',
        '/org/a11y/bus', '--method', 'org.a11y.Bus.GetAddress']).stdout)[0]
    session.env.update(AT_SPI_BUS_ADDRESS=address, GTK_A11Y='atspi')
    session.child('accessibility-registry', ['/usr/lib/at-spi2-registryd'])
    wait_for(lambda: 'org.a11y.atspi.Registry' in session.run(
        ['busctl', '--address=' + address, 'list']).stdout)


class WindowHarness(PolicyHarness):
    def launch(self, recovery=False, paths=()):
        self.target = None
        self.native_ids, self.actions = {}, {}
        self.serial += 1
        self.recovery_root = Path(self.session.env['XDG_STATE_HOME']) / 'coral/recovery'
        self.slot = Path(self.session.env['XDG_STATE_HOME']) / 'coral/sessions/current'
        self.load_gate = self.command_path.with_name('session-load.gate')
        self.session.env['CORAL_TEST_SESSION_LOAD_PAUSE'] = str(self.load_gate)
        self.app = self.app_child(f'{self.name}-{self.serial}',
                                      [self.binary, '--width=900', '--height=620', *paths],
                                      G_DEBUG='fatal-criticals')
        self.first_native = wait_for(lambda: next((w['id'] for w in self.native_windows()
                                                  if w.get('title', '').endswith('Coral')), None))
        self.bus = self.find_bus()
        self.first_action = wait_for(lambda: next(iter(self.action_paths()), None))
        if not recovery:
            self.ready()

    def native_windows(self):
        # The private session runs only this Coral process. Palette transients
        # need not carry GtkApplication's app_id, so do not filter them out.
        return [w for w in self.ipc.state() if w['kind'] == 'window']

    def click_accessible(self, label):
        """Resolve a visible control in the named owner, then send a real click."""
        surface = next(w for w in self.native_windows() if w['id'] == self.native_ids[self.target])
        assert surface['focused'], ('Accessible click must target the focused owner', surface)
        script = '''
import json, sys, gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi
pid, label, title = int(sys.argv[1]), sys.argv[2], sys.argv[3]
desktop = Atspi.get_desktop(0)
queue, matches = [], []
for i in range(desktop.get_child_count()):
    app = desktop.get_child_at_index(i)
    if app.get_process_id() == pid:
        for j in range(app.get_child_count()):
            frame = app.get_child_at_index(j)
            if frame.get_name() == title and frame.get_state_set().contains(Atspi.StateType.SHOWING):
                queue.append((frame, 0))
assert len(queue) <= 1, ('Ambiguous owner title', title)
seen = 0
while queue and seen < 5000:
    node, depth = queue.pop(0)
    seen += 1
    states = node.get_state_set()
    if (node.get_name() == label and node.get_role() in (Atspi.Role.PUSH_BUTTON, Atspi.Role.TOGGLE_BUTTON)
            and states.contains(Atspi.StateType.SHOWING)
            and states.contains(Atspi.StateType.SENSITIVE)
            and node.get_action_iface() is not None
            and node.get_action_iface().get_n_actions() > 0):
        rect = node.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        if rect.width > 0 and rect.height > 0:
            matches.append(dict(label=label, role=node.get_role_name(),
                                x=rect.x, y=rect.y, width=rect.width, height=rect.height))
    if depth < 32:
        queue.extend((node.get_child_at_index(i), depth + 1)
                     for i in range(min(node.get_child_count(), 1024)))
print(json.dumps(matches))
'''
        def locate():
            matches = json.loads(self.session.run(
                [sys.executable, '-c', script, str(self.app.proc.pid), label, surface['title']]).stdout)
            assert len(matches) <= 1, ('Ambiguous accessible control', label, matches)
            return matches[0] if matches else None

        control = wait_for(locate, 8)
        x = round(surface['geometry']['x'] + control['x'] + control['width'] / 2)
        y = round(surface['geometry']['y'] + control['y'] + control['height'] / 2)
        pointer_move(self.session, x, y)
        pointer_click(self.session)
        route = dict(case=self.name, owner=self.target, control=control, pointer=[x, y])
        self.evidence.setdefault('accessible_pointer_routes', []).append(route)
        return route

    def dbus(self, destination, path, method, *arguments):
        return self.session.run(['gdbus', 'call', '--session', '--dest', destination,
                                 '--object-path', path, '--method', method, *arguments]).stdout

    def find_bus(self):
        names = self.dbus('org.freedesktop.DBus', '/org/freedesktop/DBus',
                          'org.freedesktop.DBus.ListNames')
        for name in re.findall(r"'(:[0-9.]+)'", names):
            try:
                pid = self.dbus('org.freedesktop.DBus', '/org/freedesktop/DBus',
                                'org.freedesktop.DBus.GetConnectionUnixProcessID', name)
            except subprocess.CalledProcessError:
                continue  # The short-lived gdbus ListNames connection can vanish.
            if re.search(r'\b' + str(self.app.proc.pid) + r'\b', pid):
                return name
        raise AssertionError(('No private GTK bus connection for child PID', self.app.proc.pid, names))

    def action_paths(self):
        tree = self.session.run(['gdbus', 'introspect', '--session', '--dest', self.bus,
                                 '--object-path', '/', '--recurse']).stdout
        return set(re.findall(r'node (/[^\s{]+/window/[0-9]+)\s*\{', tree))

    def bind(self, identity, native, action):
        exported = self.dbus(self.bus, action, 'org.gtk.Actions.List')
        for name in ('new-window', 'close-window', 'next-window', 'previous-window', 'quit', 'save'):
            assert "'" + name + "'" in exported, (action, name, exported)
        self.native_ids[identity], self.actions[identity] = native, action
        self.evidence.setdefault('window_bindings', []).append(
            dict(case=self.name, serial=self.serial, id=identity, surface=native, action_path=action))

    def ready(self):
        self.ipc.call('command', action='window.activate', fields={'id': self.first_native})
        state = wait_for(lambda: p if (p := self.state())['documents'] else None)
        self.target = state['window_id']
        self.bind(self.target, self.first_native, self.first_action)
        self.drained()
        return self.target

    def command(self, action, value=None, *, allow_exit=False, **fields):
        if self.target is not None:
            fields.setdefault('window', self.target)
        if not allow_exit:
            lines, elapsed = Harness.command(self, action, value, **fields)
        else:
            self.alive()
            content = '[Test]\naction=' + action + '\n'
            if value is not None:
                content += 'value=' + self.escape(value) + '\n'
            content += ''.join(f'{key}={self.escape(v)}\n' for key, v in fields.items())
            self.command_path.write_text(content)
            start, began = len(self.app.lines), time.monotonic()
            self.key('F11')
            wait_for(lambda: self.app.proc.poll() is not None or
                     'CORAL_COMMAND_DONE' in self.app.lines[start:], 5)
            lines, elapsed = self.app.lines[start:], time.monotonic() - began
        assert not any(line.startswith('CORAL_COMMAND_REJECTED') for line in lines), (action, fields, lines)
        return lines, elapsed

    def probe(self, kind='workspace'):
        p = Harness.probe(self, kind)
        if kind == 'workspace' and self.target is not None:
            assert p['window_id'] == self.target, ('Target routing ignored', self.target, p)
        return p

    def state(self):
        return self.probe('workspace')

    def windows(self):
        p = self.probe('windows')
        entries = p['windows']
        assert p['limit'] == 16 and len(entries) <= 16, p
        assert p['live'] == sum(not w['closing'] for w in entries), p
        assert p['closing'] == sum(w['closing'] for w in entries), p
        assert p['holds'] == sum(w['holds'] + w['recovery_holds'] for w in entries), p
        assert len({w['id'] for w in entries}) == len({w['scope'] for w in entries}) == len(entries), p
        assert all(w['id'] > 0 and w['scope'] for w in entries), p
        assert p['save_limit'] == 16 and len(p['saves']) <= p['save_limit'], p
        assert len({s['path'] for s in p['saves']}) == len(p['saves']), p
        assert all(s['window'] in {w['id'] for w in entries} and s['document'] > 0
                   and Path(s['path']).is_absolute() for s in p['saves']), p
        assert p['revocation_limit'] == 256 and 0 <= p['revoked_scopes'] <= 256, p
        assert isinstance(p['revocation_saturated'], bool), p
        return p

    def select(self, identity, focus=False):
        self.target = identity
        if focus:
            self.ipc.call('command', action='window.activate', fields={'id': self.native_ids[identity]})
            wait_for(lambda: any(w['id'] == identity and w['active'] for w in self.windows()['windows']))
        return self

    @contextmanager
    def at(self, identity):
        previous = self.target
        self.target = identity
        try:
            yield
        finally:
            self.target = previous

    def action(self, name, identity=None):
        """The same GActionGroup used by win.NAME in the native menu/buttons."""
        identity = self.target if identity is None else identity
        assert name.startswith('win.'), name
        result = self.dbus(self.bus, self.actions[identity], 'org.gtk.Actions.Activate', name[4:], '[]', '{}')
        assert result.strip() == '()', result
        self.evidence.setdefault('action_routes', []).append(
            dict(case=self.name, id=identity, action=name, path=self.actions[identity]))

    def new_window(self, keyboard=False, wait_ready=True):
        before = {w['id'] for w in self.windows()['windows']}
        surfaces, paths = {w['id'] for w in self.native_windows()}, self.action_paths()
        if keyboard:
            self.select(self.target, focus=True)
            self.key('n', 'ctrl', 'shift')
        else:
            self.action('win.new-window')
        p = wait_for(lambda: p if len((p := self.windows())['windows']) == len(before) + 1 else None)
        new = next(w['id'] for w in p['windows'] if w['id'] not in before)
        assert new > max(before), (before, p)
        native = wait_for(lambda: next((w['id'] for w in self.native_windows() if w['id'] not in surfaces), None))
        path = wait_for(lambda: next(iter(self.action_paths() - paths), None))
        self.bind(new, native, path)
        self.target = new
        if wait_ready:
            wait_for(lambda: self.state()['documents'])
            self.drained()
        return new

    def palette(self, label):
        self.select(self.target, focus=True)
        self.key('p', 'ctrl', 'shift')
        wait_for(lambda: any(w.get('title') == 'Command Palette…' for w in self.native_windows()))
        self.text(label)
        self.key('Return')
        wait_for(lambda: not any(w.get('title') == 'Command Palette…' for w in self.native_windows()))
        self.evidence.setdefault('palette_routes', []).append(dict(case=self.name, label=label))

    def drained(self, count=None):
        def ready():
            p = self.windows()
            # Each LIVE browser owns one long-lived watcher hold. Closing
            # entries must disappear entirely, not merely return to this baseline.
            return p if (p['holds'] == p['live'] and not p['closing'] and not p['saves'] and p['session_owner'] is None and
                         all(w['holds'] == 1 and w['recovery_holds'] == 0 for w in p['windows']) and
                         not p['preferences_pending'] and not any(w['recovery_opening'] for w in p['windows']) and
                         (count is None or p['live'] == count)) else None
        p = wait_for(ready, 15)
        self.evidence.setdefault('drains', []).append(dict(case=self.name, registry=p))
        return p

    def gone(self, identity):
        def absent():
            p = self.windows()
            return p if all(w['id'] != identity for w in p['windows']) else None
        return wait_for(absent, 15)

    def close_window(self, identity, survivor, keyboard=False):
        self.select(identity, focus=keyboard)
        if keyboard:
            self.key('w', 'ctrl', 'shift')
        else:
            self.action('win.close-window')
        self.select(survivor, focus=True)
        self.gone(identity)

    def open_document(self, path):
        self.command('open', path)
        return wait_for(lambda: d if (d := self.document(path)) and d['text'] else None)

    def workspace(self, root):
        self.command('open-folder', root)
        browser = self.browser()
        assert browser['error_name'] is None and len(browser['roots']) == 1, browser
        self.policy_idle()
        return browser

    def policy_idle(self):
        return wait_for(lambda: p if not ((p := self.probe('policy'))['pending'] or
                                         p['active'] is not None or p['preferences_pending']) else None, 15)

    def query(self, text):
        self.command('search-query', text, mode='text')
        wait_for(lambda: p if not ((p := self.probe('search'))['active'] or p['pending']) else None, 15)
        time.sleep(.03)
        return self.probe('search')

    def settled(self, timeout=15):
        return self.policy_idle()

    def replace_keyboard(self, text):
        self.select(self.target, focus=True)
        self.action('win.focus-editor')
        self.key('a', 'ctrl')
        self.text(text)
        wait_for(lambda: self.active()[0]['text'] == text)

    def responsive(self, identity, text='sibling remains responsive π🙂'):
        self.select(identity, focus=True)
        self.action('win.new')
        self.text(text)
        assert self.active()[0]['text'] == text and self.active()[0]['dirty'], self.state()
        self.key('w', 'ctrl')
        wait_for(lambda: self.state()['dialog'])
        self.command('respond', response=1)
        wait_for(lambda: not self.state()['dialog'])

    def native_probe(self):
        start = len(self.app.lines)
        self.key('F12')
        line = wait_for(lambda: next((s for s in self.app.lines[start:] if s.startswith('CORAL_PROBE ')), None))
        return json.loads(line.removeprefix('CORAL_PROBE '))

    def journals(self, texts):
        def ready():
            found = {}
            for path in self.recovery_root.glob('*/manifest'):
                try:
                    data = manifest(path)
                    actual = {base64.b64decode(d['text']).decode() for d in data['documents']}
                    for text in texts:
                        if text in actual and locked(path.parent):
                            found[text] = path
                except (FileNotFoundError, ValueError, AssertionError):
                    pass  # Atomic publication may replace the directory during polling.
            return found if len(found) == len(texts) else None
        return wait_for(ready, 20)

    def crash(self):
        self.no_criticals()
        self.app.signal(signal.SIGKILL)
        assert self.app.wait() == -signal.SIGKILL
        wait_for(lambda: not self.native_windows())

    def recovery_choice(self, key, marker=None):
        titles = ('Recover interrupted session', 'Recovery copied safely')
        dialog = wait_for(lambda: next((w for w in self.native_windows() if w.get('title') in titles), None))
        self.ipc.call('command', action='window.activate', fields={'id': dialog['id']})
        start = len(self.app.lines)
        self.key(key)
        if marker:
            wait_for(lambda: 'CORAL_RECOVERY_PROMPT ' + marker in self.app.lines[start:], 15)
        else:
            wait_for(lambda: all(w['id'] != dialog['id'] for w in self.native_windows()))

    def no_criticals(self):
        bad = [line for line in self.app.lines if re.search(
            r'CRITICAL|panic:|protocol error|(?:Gtk|Gdk|GLib|GObject|Pango).*WARNING|'
            r'WARNING.*(?:Gtk|Gdk|GLib|GObject|Pango)|assertion .*failed|error\(gpa\).*leak', line, re.I)]
        assert not bad, '\n'.join(bad)

    def stop(self):
        if self.app is None:
            return
        if self.app.proc.poll() is None:
            # Resolve each actual modal in serial Quit All order. The final
            # response may exit before an F11 acknowledgement is collected.
            entries = [w for w in self.windows()['windows'] if not w['closing']]
            assert entries, self.last
            self.select(entries[0]['id'], focus=True)
            self.action('win.quit')
            deadline = time.monotonic() + 20
            while self.app.proc.poll() is None:
                assert time.monotonic() < deadline, ('Quit All did not drain', self.last)
                # A destroyed target cannot receive probes; use the currently
                # focused surviving window, including its dirty-close dialog.
                self.target = None
                if not self.native_windows():
                    time.sleep(.025)
                    continue
                try:
                    p = self.state()
                except (AssertionError, TimeoutError):
                    # Clean Quit All can finish between the surface snapshot
                    # and F11. Only a verified successful exit is acceptable.
                    if self.app.proc.poll() == 0:
                        break
                    raise
                if p['dialog']:
                    self.target = p['window_id']
                    self.command('respond', response=1, allow_exit=True)
                else:
                    time.sleep(.025)
            assert self.app.wait() == 0, self.app.lines[-40:]
            wait_for(lambda: not self.native_windows())
        self.no_criticals()


def pair(h):
    first = h.target
    second = h.new_window(keyboard=True)
    return first, second


def routes_and_close(h):
    first, second = pair(h)
    h.select(first)  # F11 is delivered to focused SECOND, but targets FIRST.
    h.command('insert', 'first only')
    assert h.active()[0]['text'] == 'first only'
    h.select(second)
    assert h.active()[0]['text'] == ''
    h.action('win.new', first)
    with h.at(first):
        assert len(h.state()['documents']) == 2
    assert len(h.state()['documents']) == 1
    h.action('win.close', first)
    with h.at(first):
        wait_for(lambda: len(h.state()['documents']) == 1)
    h.palette('Next Window')
    wait_for(lambda: any(w['id'] == first and w['active'] for w in h.windows()['windows']))
    h.select(first)
    h.palette('Previous Window')
    wait_for(lambda: any(w['id'] == second and w['active'] for w in h.windows()['windows']))
    h.action('win.next-window', first)
    wait_for(lambda: any(w['id'] == second and w['active'] for w in h.windows()['windows']))
    h.action('win.previous-window', second)
    wait_for(lambda: any(w['id'] == first and w['active'] for w in h.windows()['windows']))
    h.select(first, focus=True)
    before = contents(h.state())
    h.key('w', 'ctrl', 'shift')
    wait_for(lambda: h.state()['dialog'])
    h.command('respond', response=0)
    after = contents(h.state())
    assert after == before and not h.windows()['quitting'], (before, after)
    h.action('win.close-window')
    wait_for(lambda: h.state()['dialog'])
    h.command('respond', response=1)
    h.select(second, focus=True)
    h.gone(first)
    h.responsive(second)
    # A retired stable ID must be rejected, never routed to the survivor.
    lines, _ = Harness.command(h, 'workspace-probe', window=first)
    assert 'CORAL_COMMAND_REJECTED unknown-window' in lines, lines
    h.drained(1)


def isolation(h):
    first, second = pair(h)
    for identity, label, indent in ((first, 'left', 2), (second, 'right', 7)):
        h.select(identity, focus=True)
        root = h.fixtures / label
        h.write(root / '.coral/settings.json', json.dumps({'version': 1, 'settings': {'indent': indent}}))
        path = h.write(root / 'same.txt', label + ' unique-token\n')
        h.workspace(root)
        h.open_document(path)
        h.replace_keyboard(label + ' unsaved-token π🙂')
        policy = h.policy_idle()
        doc = next(d for d in policy['documents'] if d['path'] == str(path))
        assert doc['effective']['values']['indent'] == indent, doc
        assert doc['effective']['origins']['indent'] == 'folder', doc
        assert policy['trust'] == 'restricted' and not any(policy['permits']), policy
    h.select(first)
    h.action('win.split-group')
    h.command('focus-explorer')
    h.action('win.dock-right')
    result = h.query('left unsaved-token')
    h.exact(result, 1, ['same.txt'])
    assert result['results'][0]['source'].get('overlay'), result
    left = contents(h.state())
    assert len(left['groups']) == 2
    assert h.probe('dock')['desired']['explorer'] == 'right'
    h.command('policy-trust-confirm')
    assert h.probe('policy')['confirmation']
    h.command('respond', response=1)
    assert h.policy_idle()['trust'] == 'trusted'
    h.select(second)
    assert len(h.state()['groups']) == 1
    assert h.probe('dock')['desired']['explorer'] == 'left'
    assert h.policy_idle()['trust'] == 'restricted'
    assert h.probe('search')['query'] != 'left unsaved-token'
    h.exact(h.query('left unsaved-token'), 0)
    h.exact(h.query('right unsaved-token'), 1, ['same.txt'])
    assert h.probe('browser')['roots'][0]['path'] == str(h.fixtures / 'right')
    h.select(first)
    assert contents(h.state()) == left
    assert h.probe('search')['query'] == 'left unsaved-token'
    assert h.probe('browser')['roots'][0]['path'] == str(h.fixtures / 'left')
    h.verify_files()


def quit_serial(h):
    first, second = pair(h)
    third = h.new_window()
    for identity in (first, second, third):
        h.select(identity, focus=True)
        h.replace_keyboard(f'dirty window {identity}')
    h.select(second, focus=True)
    h.key('q', 'ctrl')
    wait_for(lambda: h.state()['dialog'])
    assert h.windows()['quitting']
    for identity in (first, third):
        with h.at(identity):
            assert not h.state()['dialog'], 'Quit All opened concurrent dirty prompts'
    h.action('win.new-window', first)
    assert h.windows()['live'] == 3
    with h.at(first):
        assert 'Quit All' in h.state()['notice'], h.state()
    h.command('respond', response=1)
    h.select(first)
    wait_for(lambda: h.state()['dialog'])
    with h.at(third):
        assert not h.state()['dialog'] and h.active()[0]['dirty']
    h.command('respond', response=0)
    p = h.drained(2)
    assert not p['quitting'] and not any(w['quitting'] for w in p['windows']), p
    h.gone(second)
    with h.at(third):
        assert not h.state()['dialog'] and h.active()[0]['text'] == f'dirty window {third}'
    fourth = h.new_window()
    h.close_window(fourth, first)
    h.select(third, focus=True)
    h.palette('Quit All')
    wait_for(lambda: h.state()['dialog'])
    h.command('respond', response=0)
    assert not h.windows()['quitting']


def delayed_close(h, kind):
    first, second = pair(h)
    h.select(first)
    root = h.fixtures / 'root'
    path = h.write(root / 'target.txt', 'delayed needle\n')
    h.workspace(root)
    h.drained(2)
    gate = kind == 'session_load'
    try:
        if kind == 'search':
            h.command('search-delay', 3000)
            h.command('search-query', 'needle', mode='text')
            wait_for(lambda: h.probe('search')['active'])
        elif kind == 'policy':
            h.command('policy-delay', 3000)
            h.command('policy-recheck')
            wait_for(lambda: h.probe('policy')['active'] is not None)
        elif kind == 'session':
            h.command('session-delay', 3000)
            h.action('win.save-workspace-session')
            wait_for(lambda: h.probe('session')['busy'])
        elif gate:
            h.action('win.save-workspace-session')
            wait_for(lambda: h.probe('session')['status'] == 'saved')
            h.command('close-workspace')
            h.browser()
            h.load_gate.touch(mode=0o600)
            start = len(h.app.lines)
            h.action('win.restore-workspace-session')
            wait_for(lambda: 'CORAL_SESSION_WORKSPACE_LOAD_PAUSED' in h.app.lines[start:])
            assert h.probe('browser')['loading'] and h.probe('session')['busy']
        else:
            h.command('explorer-delay')
            h.command('workspace-rescan' if kind == 'browser' else 'open', None if kind == 'browser' else path)
            assert h.probe('browser')['pending'] > 0, h.last
        before = h.windows()
        documents = h.state()['documents']
        assert next(w for w in before['windows'] if w['id'] == first)['holds'] > 1, before
        h.action('win.close-window')
        h.select(second, focus=True)
        if kind in ('browser', 'load', 'session', 'session_load'):
            # These workers can change the snapshot. M2 refuses close until
            # they resolve; no documents may be removed on that refusal.
            with h.at(first):
                rejected = wait_for(lambda: p if (p := h.state())['notice'] ==
                                    'Finish pending operations before closing this window.' else None, 2)
                assert rejected['documents'] == documents and not rejected['dialog'], rejected
            closing = h.windows()
            assert any(w['id'] == first and not w['closing'] and not w['quitting'] and
                       w['holds'] > 1 for w in closing['windows']), closing
        else:
            # Closing now first commits an automatic snapshot. Observe native
            # teardown, not the transient pre-commit registry state.
            closing = wait_for(lambda: p if (p := h.windows())['closing'] == 1 else None, 2)
            assert any(w['id'] == first and w['closing'] and w['holds'] > 0
                       for w in closing['windows']), closing
        h.evidence.setdefault('inflight', []).append(dict(case=h.name, before=before, closing=closing))
        h.responsive(second)
    finally:
        h.load_gate.unlink(missing_ok=True)
    if kind in ('browser', 'load', 'session', 'session_load'):
        h.drained(2)
        h.select(first, focus=True)
        documents = h.state()['documents']
        h.action('win.close-window')
        for _ in range(sum(d['dirty'] for d in documents)):
            wait_for(lambda: h.state()['dialog'])
            h.command('respond', response=1)
        h.select(second, focus=True)
    h.gone(first)
    h.drained(1)
    assert not any(d['path'] == str(path) for d in h.state()['documents']), h.state()
    h.verify_files()


def recovery_startup_drain(h):
    first = h.target
    h.drained(1)
    fd = os.open(h.recovery_root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        second = h.new_window(wait_ready=False)
        p = h.windows()
        opening = next(w for w in p['windows'] if w['id'] == second)
        assert opening['recovery_opening'] and opening['recovery_holds'] > 0, p
        h.action('win.close-window')
        h.select(first, focus=True)
        p = h.windows()
        opening = next(w for w in p['windows'] if w['id'] == second)
        assert not opening['closing'] and opening['recovery_opening'] and opening['recovery_holds'] > 0, p
        with h.at(second):
            state = h.state()
            assert not state['documents'] and not state['dialog'], state
            assert 'Finish the current dialog or startup recovery' in state['notice'], state
        h.responsive(first)
        h.evidence.setdefault('inflight', []).append(dict(case=h.name, refused_close=p))
    finally:
        os.close(fd)
    h.drained(2)
    with h.at(second):
        wait_for(lambda: h.state()['documents'])
    h.close_window(second, first)
    h.gone(second)
    h.drained(1)
    assert len(list(h.recovery_root.iterdir())) == 1


def resource_sample(h):
    status = Path(f'/proc/{h.app.proc.pid}/status').read_text()
    return dict(rss=h.rss(), fds=len(list(Path(f'/proc/{h.app.proc.pid}/fd').iterdir())),
                threads=int(re.search(r'^Threads:\s+(\d+)', status, re.M)[1]))


def registry_reuse(h):
    first = h.target
    ids, samples = [], []
    for index in range(24):
        new = h.new_window(keyboard=index % 2 == 0)
        ids.append(new)
        h.close_window(new, first, keyboard=index % 2 == 1)
        p = h.drained(1)
        assert [w['id'] for w in p['windows']] == [first], p
        wait_for(lambda: len(list(h.recovery_root.iterdir())) == 1)
        if index in (3, 11, 23):
            samples.append(resource_sample(h))
        h.responsive(first, f'iteration {index}')
    assert ids == sorted(set(ids)) and len(ids) >= 20 and ids[-1] > 16, ids
    h.evidence['reuse'] = dict(ids=ids, samples=samples,
                              bounds=dict(fds=8, threads=4, rss_bytes=64 * 1024 * 1024))
    assert samples[-1]['fds'] <= samples[0]['fds'] + 8, samples
    assert samples[-1]['threads'] <= samples[0]['threads'] + 4, samples
    assert samples[-1]['rss'] <= samples[0]['rss'] + 64 * 1024 * 1024, samples


def window_limit(h):
    first = h.target
    ids = [first]
    for _ in range(15):
        ids.append(h.new_window())
    h.action('win.new-window')
    assert h.windows()['live'] == 16
    assert '16 live or draining windows' in h.state()['notice'], h.state()
    victim = ids[-1]
    root = h.fixtures / 'root'
    h.write(root / 'target.txt', 'needle\n')
    h.workspace(root)
    h.command('search-delay', 3000)
    h.command('search-query', 'needle', mode='text')
    wait_for(lambda: h.probe('search')['active'])
    h.action('win.close-window')
    h.select(first, focus=True)
    p = wait_for(lambda: p if (p := h.windows())['closing'] == 1 else None, 2)
    assert (p['live'], p['closing']) == (15, 1), p
    h.action('win.new-window')
    p = h.windows()
    assert len(p['windows']) == 16 and max(w['id'] for w in p['windows']) == victim, p
    assert '16 live or draining windows' in h.state()['notice']
    h.gone(victim)
    new = h.new_window()
    assert new == max(ids) + 1, ('Rejected creates consumed IDs', ids, new)
    h.drained(16)


def save_conflict(h):
    first, second = pair(h)
    path = h.write(h.fixtures / 'shared.txt', 'original disk\n')
    for identity, text in ((first, 'first edits π'), (second, 'second edits 🙂')):
        h.select(identity, focus=True)
        h.open_document(path)
        h.replace_keyboard(text)
    h.action('win.save', first)  # Save nonfocused owner via the real window action.
    with h.at(first):
        wait_for(lambda: not h.document(path)['dirty'])
    assert path.read_text() == 'first edits π'
    h.expected[path] = digest(path.read_bytes())  # This one explicit save is authorized.
    assert h.document(path)['dirty'] and h.document(path)['text'] == 'second edits 🙂'
    h.key('s', 'ctrl')
    wait_for(lambda: h.state()['dialog'])
    assert h.native_probe()['dialog'] == 3, 'Expected native etag-conflict dialog'
    assert path.read_text() == 'first edits π'
    h.command('respond', response=0)
    assert h.document(path)['dirty'] and h.document(path)['text'] == 'second edits 🙂'
    with h.at(first):
        assert not h.document(path)['dirty'] and h.document(path)['text'] == 'first edits π'
    h.verify_files()


def recovery_kept(h):
    h.replace_keyboard('kept recovery payload')
    old = h.journals(['kept recovery payload'])['kept recovery payload']
    raw = old.read_bytes()
    h.crash()
    assert not locked(old.parent)
    h.launch(recovery=True)
    h.app.expect('CORAL_RECOVERY_PROMPT restore')
    h.recovery_choice('F9')
    first = h.ready()
    assert old.read_bytes() == raw and not locked(old.parent)
    prompts = sum('CORAL_RECOVERY_PROMPT' in line for line in h.app.lines)
    second = h.new_window()
    h.drained(2)
    assert not h.state()['dialog'] and h.active()[0]['text'] == ''
    assert sum('CORAL_RECOVERY_PROMPT' in line for line in h.app.lines) == prompts
    h.close_window(first, second)
    h.responsive(second)
    h.stop()
    assert old.read_bytes() == raw and not locked(old.parent)
    assert len(list(h.recovery_root.iterdir())) == 1, 'Kept journal was reoffered or removed'


def recovery_two_journals(h):
    first, second = pair(h)
    texts = ['left crash copy α🙂', 'right crash copy β🙂']
    for identity, text, name in zip((first, second), texts, ('left.txt', 'right.txt')):
        h.select(identity, focus=True)
        path = h.write(h.fixtures / name, 'source must not be written\n')
        h.open_document(path)
        h.replace_keyboard(text)
        h.action('win.split-group')
    journals = h.journals(texts)
    assert len(set(journals.values())) == 2, journals
    for path in journals.values():
        assert locked(path.parent) and path.stat().st_mode & 0o777 == 0o600
        assert path.parent.stat().st_mode & 0o777 == 0o700
    h.evidence['crash_journals'] = [{'path': str(p), 'sha256': digest(p.read_bytes())} for p in journals.values()]
    h.crash()
    assert all(not locked(p.parent) for p in journals.values())
    h.verify_files()
    h.launch(recovery=True)
    for _ in texts:
        wait_for(lambda: any(w.get('title') == 'Recover interrupted session' for w in h.native_windows()))
        h.recovery_choice('F8', 'transferred')
        h.recovery_choice('F10')
    h.ready()
    state = h.state()
    recovered = [d for d in state['documents'] if d['text'] in texts]
    assert sorted(d['text'] for d in recovered) == sorted(texts), state
    assert all(d['dirty'] and d['path'] is None for d in recovered), recovered
    for doc in recovered:
        assert sum(v['document_id'] == doc['id'] for v in state['views']) == 2, state
    assert all(not p.parent.exists() for p in journals.values())
    h.verify_files()
    h.stop()
    assert not list(h.recovery_root.iterdir())


def shared_session_busy(h):
    first, second = pair(h)
    h.select(first)
    h.command('insert', 'first explicit snapshot')
    h.command('session-delay', 3000)
    h.action('win.save-workspace-session')
    wait_for(lambda: h.probe('session')['busy'])
    assert h.windows()['session_owner'] == first
    h.select(second)
    before = contents(h.state())
    for action in ('win.save-workspace-session', 'win.restore-workspace-session'):
        h.action(action)
        p = wait_for(lambda: p if (p := h.probe('session'))['status'] == 'failed' else None)
        assert p['error_name'] == 'Busy' and not p['busy'], p
        assert h.windows()['session_owner'] == first
        assert contents(h.state()) == before
        h.evidence.setdefault('busy_rejections', []).append(dict(action=action, state=p))
    h.drained(2)
    with h.at(first):
        assert h.probe('session')['status'] == 'saved'
    original = h.slot.read_bytes()
    h.command('insert', 'second explicit snapshot')
    h.action('win.save-workspace-session')
    wait_for(lambda: h.probe('session')['status'] == 'saved')
    h.drained(2)
    current = h.slot.read_bytes()
    assert current != original
    header, descriptor, recovery = decode_slot(current)
    magic, checksum, body = recovery.split(b'\n', 2)
    assert digest(body).encode() == checksum, (magic, checksum)
    snapshot = json.loads(body)
    texts = [base64.b64decode(d['text']).decode() for d in snapshot['documents']]
    assert texts == ['second explicit snapshot'], (header, descriptor, texts)
    h.evidence['session_slot'] = dict(first_sha256=digest(original), last_sha256=digest(current))


def two_window_shot(h, first, second, label):
    outputs = list(h.ipc.outputs())
    assert len(outputs) >= 2
    for identity, output in zip((first, second), outputs):
        h.ipc.call('command', action='window.move', fields={'id': h.native_ids[identity], 'output': output})
        h.ipc.call('command', action='window.maximized', fields={'id': h.native_ids[identity], 'value': True})
    time.sleep(.2)
    docks = {}
    for identity in (first, second):
        with h.at(identity):
            p = h.probe('dock')
            geometry(p)
            docks[str(identity)] = p
    surfaces = h.native_windows()
    assert all(any(w['id'] == h.native_ids[i] and w['visible'] for w in surfaces) for i in (first, second)), surfaces
    h.screenshot(label)
    path = h.output / 'screenshots' / f'{h.name}-{label}.png'
    h.evidence.setdefault('screenshots', []).append(dict(path=str(path), sha256=digest(path.read_bytes()), docks=docks, surfaces=surfaces))
    return path


def editor_color(h, identity, screenshot):
    from PIL import Image
    with h.at(identity):
        rect = h.probe('dock')['editor_bounds']
    window = next(w for w in h.native_windows() if w['id'] == h.native_ids[identity])
    x, y = window['geometry']['x'] + rect['x'], window['geometry']['y'] + rect['y']
    # Blank lower editor interior avoids decorations, tab labels, caret and text.
    box = (int(x + rect['width'] * .5), int(y + rect['height'] * .65),
           int(x + rect['width'] * .85), int(y + rect['height'] * .85))
    with Image.open(screenshot) as image:
        crop = image.convert('RGB').crop(box)
        pixels = crop.load()
        return Counter(pixels[x, y] for y in range(crop.height) for x in range(crop.width)).most_common(1)[0][0]


def preferences_and_css(h):
    first, second = pair(h)
    for identity, label, indent in ((first, 'left', 2), (second, 'right', 7)):
        h.select(identity)
        root = h.fixtures / label
        h.write(root / '.coral/settings.json', json.dumps({'version': 1, 'settings': {'indent': indent}}))
        h.workspace(root)
        h.open_document(h.write(root / 'text.txt', label + '\n'))
    h.select(first)
    h.command('policy-user', wrap='false', spaces='false', indent=5)
    h.command('settings', theme=1, font=18)
    h.drained(2)
    for identity, indent in ((first, 2), (second, 7)):
        h.select(identity)
        state = h.state()
        assert (state['settings']['theme'], state['settings']['font']) == (1, 18), state['settings']
        p = h.policy_idle()
        doc = next(d for d in p['documents'] if d['path'] is not None)
        assert doc['effective']['values']['indent'] == indent, doc
        assert doc['effective']['origins']['indent'] == 'folder', doc
        assert doc['effective']['values']['wrap'] is False and doc['effective']['values']['spaces'] is False, doc
        assert doc['effective']['origins']['wrap'] == 'user', doc
    settings = h.preferences.read_bytes()
    assert settings and h.windows()['preferences_pending'] is False
    shot = two_window_shot(h, first, second, 'two-window-light-layout')
    colors = [editor_color(h, identity, shot) for identity in (first, second)]
    assert colors[0] == colors[1] and min(colors[1]) > 128, colors
    h.close_window(first, second)
    h.drained(1)
    h.screenshot('surviving-light-appearance')
    path = h.output / 'screenshots' / f'{h.name}-surviving-light-appearance.png'
    after = editor_color(h, second, path)
    assert after == colors[1], ('Closing sibling removed surviving CSS', colors, after)
    assert h.state()['settings']['font'] == 18
    assert h.preferences.read_bytes() == settings
    h.evidence['appearance'] = dict(before=colors, after=after, preferences_sha256=digest(settings))


def external_quit_palette(h):
    """Reproduce teardown from another owner, not activation within the palette."""
    for attempt in range(3):
        if attempt:
            # This teardown fixture needs exactly two clean owners. An explicit
            # file launch suppresses the preceding Quit All's automatic reopen.
            path = h.write(h.fixtures / 'palette-relaunch.txt', 'clean palette owner\n')
            h.launch(paths=(path,))
        first, second = pair(h)
        h.select(second, focus=True)
        assert all(not d['dirty'] for d in h.state()['documents'])
        h.key('p', 'ctrl', 'shift')
        palette = wait_for(lambda: next((w for w in h.native_windows()
                                        if w.get('title') == 'Command Palette…'), None))
        assert palette['focused'], palette
        # Do not focus first or dismiss the palette: Quit All is external to B.
        h.action('win.quit', first)
        assert h.app.wait(timeout=15) == 0, h.app.lines[-40:]
        wait_for(lambda: not h.native_windows())
        h.no_criticals()
        h.evidence.setdefault('external_palette_quits', []).append(
            dict(attempt=attempt + 1, requester=first, palette_owner=second, palette=palette))


def explorer_button_owners(h):
    first, second = pair(h)
    h.command('settings', theme=1, font=14)
    roots = [h.fixtures / name for name in ('folder-root', 'manifest-root')]
    for root in roots:
        h.write(root / 'sentinel.txt', root.name + '\n')
    workspace = h.write(h.fixtures / 'clicked.coral-workspace', json.dumps(
        {'version': 1, 'roots': [{'path': str(roots[1])}]}))
    # GTK's AT-SPI frames do not expose ACTIVE here. Distinct real document
    # titles bind accessible controls unambiguously to each native owner.
    for owner in (first, second):
        h.select(owner)
        h.open_document(h.write(h.fixtures / f'owner-{owner}.txt', 'chooser owner\n'))
    two_window_shot(h, first, second, 'explorer-buttons-before-clicks')
    for owner, sibling, folder in ((first, second, True), (second, first, False),
                                    (first, second, False), (second, first, True)):
        with h.at(sibling):
            other_before = h.probe('browser')
        h.select(owner, focus=True)
        h.action('win.focus-explorer')
        dock = h.probe('dock')
        assert dock['desired']['explorer'] == 'left' and dock['explorer_visible'], dock
        h.click_accessible('Explorer actions and safety information')
        previous = {w['id'] for w in h.native_windows()}
        route = h.click_accessible('Open Folder…' if folder else 'Workspace…')
        chooser = wait_for(lambda: next((w for w in h.native_windows() if w['id'] not in previous), None))
        assert 'Palette' not in chooser.get('title', ''), chooser
        # Probe from the sibling: the chooser itself has no Coral F11 handler.
        h.select(sibling, focus=True)
        assert not h.probe('browser')['choosing'], h.last
        h.select(owner)
        choosing = h.probe('browser')
        assert choosing['choosing'], ('Explorer button chose the wrong owner', owner, choosing)
        h.evidence.setdefault('explorer_clicks', []).append(dict(
            owner=owner, action='win.open-folder' if folder else 'win.open-workspace',
            pointer=route['pointer'], control=route['control'], chooser=chooser, owner_browser=choosing))
        h.ipc.call('command', action='window.activate', fields={'id': chooser['id']})
        h.key('l', 'ctrl')
        h.key('a', 'ctrl')
        h.text(str(roots[0] if folder else workspace))
        h.key('Return')
        if folder:
            time.sleep(.3)  # Location Enter navigates; Ctrl+Enter accepts.
            h.key('Return', 'ctrl')
        wait_for(lambda: all(w['id'] != chooser['id'] for w in h.native_windows()))
        h.select(owner, focus=True)
        browser = h.browser()
        assert not browser['choosing'] and browser['error_name'] is None, browser
        assert [r['canonical'] for r in browser['roots']] == [str(roots[0 if folder else 1])], browser
        assert browser['manifest'] == (None if folder else str(workspace)), browser
        with h.at(sibling):
            other_after = h.probe('browser')
            assert (other_after['roots'], other_after['manifest']) == (other_before['roots'], other_before['manifest']), (other_before, other_after)
    h.verify_files()


def native_font_broadcast(h):
    first, second = pair(h)
    observed = {}
    for size in (12, 24):
        h.select(first)
        h.command('settings', theme=2, font=size)  # Native GTK, not .coral CSS.
        h.drained(2)
        samples = []
        for identity in (first, second):
            h.select(identity, focus=True)
            def resolved():
                p = h.state()
                old = observed.get(12, [{}])[0].get('size', 0)
                return p if p['editor_font_size'] > (old * 1.8 if size == 24 else 0) else None
            p = wait_for(resolved)
            assert p['settings']['theme'] == 2 and p['settings']['font'] == size, p
            samples.append(dict(window=identity, size=p['editor_font_size'], absolute=p['editor_font_absolute']))
        assert samples[0]['size'] == samples[1]['size'], samples
        assert samples[0]['absolute'] == samples[1]['absolute'], samples
        observed[size] = samples
    for small, large in zip(observed[12], observed[24]):
        assert 1.95 <= large['size'] / small['size'] <= 2.05, (small, large)
        assert large['absolute'] == small['absolute'], (small, large)
    h.close_window(first, second)
    h.drained(1)
    p = h.state()
    assert (p['editor_font_size'], p['editor_font_absolute']) == (observed[24][1]['size'], observed[24][1]['absolute']), p
    h.screenshot('native-font-24-surviving-window')
    h.evidence['native_fonts'] = observed


def assert_permits(p, trusted):
    assert p['permits'] == [trusted] * 6, p
    assert p['trust'] == ('trusted' if trusted else 'restricted'), p
    if not trusted:
        assert not p['gate_valid'] and not p['retired_permit_valid'], p


def confirm_scope(h):
    h.action('win.workspace-trust')
    p = wait_for(lambda: p if (p := h.probe('policy'))['confirmation'] else None)
    assert p['dialog'] and not p['shared_cleanup_pending'], p
    h.command('respond', response=1)
    p = h.policy_idle()
    assert_permits(p, True)
    assert not p['shared_revocation_blocked'], p
    return p


def shared_revoke(h, fail_write=False):
    first, second = pair(h)
    unrelated = h.new_window()
    root, other = h.fixtures / 'shared', h.fixtures / 'unrelated'
    for directory in (root, other):
        h.write(directory / 'safe.txt', 'never execute repository content\n')
    h.select(first, focus=True)
    h.workspace(root)
    a = confirm_scope(h)
    h.select(second, focus=True)
    h.workspace(root)
    b = h.policy_idle()
    assert_permits(b, True)  # Initial same-scope disk approval, before revoke.
    assert a['scope_key'] == b['scope_key'] and a['fingerprint'] == b['fingerprint'], (a, b)
    h.command('policy-gate')
    b = h.probe('policy')
    assert b['gate_pending'] and b['gate_valid'], b
    h.select(unrelated, focus=True)
    h.workspace(other)
    c = confirm_scope(h)
    assert c['scope_key'] != a['scope_key'], (a, c)
    h.command('policy-gate')
    disk = h.store.read_bytes()
    for identity, delay in ((first, 3000), (second, 4500)):
        h.select(identity)
        # Keep both removals pending for the immediate probes, but stagger
        # successful writes: the store intentionally has a nonblocking lock.
        h.command('policy-delay', delay)
        if fail_write:
            h.command('policy-fail-write')
    h.select(second, focus=True)
    h.action('win.workspace-revoke', first)
    # No settling/recheck between revoke and B's observation. Both removals
    # are delayed, so the permits must be invalid before disk publication.
    b = h.probe('policy')
    assert_permits(b, False)
    assert b['gate_cancelled'] and not b['gate_pending'], b
    assert b['shared_revocation_blocked'] and b['shared_cleanup_pending'], b
    assert b['shared_revocation_generation'] > 0 and b['active'] == 'revoke', b
    generation = b['shared_revocation_generation']
    assert h.store.read_bytes() == disk, 'Removal committed before synchronous invalidation was observed'
    with h.at(first):
        a = h.probe('policy')
        assert_permits(a, False)
        assert a['shared_revocation_generation'] == generation and a['shared_cleanup_pending'], a
    with h.at(unrelated):
        c = h.probe('policy')
        assert_permits(c, True)
        assert c['gate_valid'] and c['shared_revocation_generation'] == 0 and not c['shared_revocation_blocked'], c
    registry = h.windows()
    assert registry['revoked_scopes'] == 1 and not registry['revocation_saturated'], registry
    h.evidence.setdefault('shared_revocations', []).append(
        dict(case=h.name, stage='synchronous-before-disk', first=a, second=b, unrelated=c, registry=registry))
    fresh = h.new_window(wait_ready=False)
    h.workspace(root)
    p = h.policy_idle()
    assert_permits(p, False)
    assert p['scope_key'] == b['scope_key'] and p['shared_revocation_blocked'] and p['shared_cleanup_pending'], p
    h.action('win.workspace-trust')
    p = h.probe('policy')
    assert not p['confirmation'] and not p['dialog'], p
    h.drained(4)
    for identity in (first, second):
        with h.at(identity):
            p = h.policy_idle()
            assert_permits(p, False)
            assert bool(p['failed_revokes']) == fail_write, p
            if fail_write:
                assert 'TestWriteFailed' in (p['store_error'] or ''), p
    assert (h.store.read_bytes() == disk) == fail_write
    # Remove every owner that saw the original approval/revocation. Only the
    # unrelated trusted window and Manager's scope tombstone remain.
    for identity in (first, second, fresh):
        h.close_window(identity, unrelated)
    newest = h.new_window()
    h.workspace(root)
    p = h.policy_idle()
    assert_permits(p, False)
    assert p['shared_revocation_generation'] == generation and p['shared_revocation_blocked'], p
    assert not p['shared_cleanup_pending'], p
    if fail_write:
        assert h.store.read_bytes() == disk, 'Test must leave a real old disk approval for the new owner to reject'
    h.evidence.setdefault('shared_revocations', []).append(dict(case=h.name, stage='source-owners-gone', policy=p))
    # An explicit retry removes any failed old grant, then a new confirmation
    # acknowledges the current generation in this owner only.
    h.action('win.workspace-revoke')
    h.drained(2)
    p = h.policy_idle()
    assert not p['failed_revokes'] and not p['shared_cleanup_pending'], p
    assert p['shared_revocation_generation'] > generation and p['shared_revocation_blocked'], p
    approved = confirm_scope(h)
    with h.at(unrelated):
        p = h.policy_idle()
        assert_permits(p, True)
        assert p['gate_valid'] and p['scope_key'] == c['scope_key'], p
    h.select(newest)
    h.evidence.setdefault('shared_revocations', []).append(dict(case=h.name, stage='fresh-confirmation', policy=approved))
    h.verify_files()


def trust_records(path):
    if not path.exists():
        return []
    raw = path.read_bytes()
    magic = b'CORAL-TRUST\x00'
    assert raw.startswith(magic), path
    version = int.from_bytes(raw[len(magic):len(magic) + 4], 'little')
    count = int.from_bytes(raw[len(magic) + 4:len(magic) + 8], 'little')
    offset = len(magic) + 8
    assert version == 1 and count <= 256 and len(raw) == offset + count * 32 + 32, path
    assert bytes.fromhex(digest(raw[:-32])) == raw[-32:], 'Trust-store checksum mismatch'
    return [raw[offset + i * 32:offset + (i + 1) * 32].hex() for i in range(count)]


def restricted_revoke_owner_closes(h):
    first, second = pair(h)
    root = h.fixtures / 'never-approved'
    h.write(root / 'safe.txt', 'This scope has never been trusted.\n')
    before = {}
    for identity in (first, second):
        h.select(identity, focus=True)
        h.workspace(root)
        p = h.policy_idle()
        assert_permits(p, False)
        assert p['fingerprint'] and p['scope_key'] and p['shared_revocation_generation'] == 0, p
        before[identity] = p
    assert before[first]['scope_key'] == before[second]['scope_key'], before
    assert before[first]['fingerprint'] == before[second]['fingerprint'], before
    assert trust_records(h.store) == [], 'A must never have an approval/known grant'
    h.select(first)
    h.command('policy-delay', 5000)
    h.action('win.workspace-revoke')
    p = h.probe('policy')
    assert p['active'] == 'revoke' and p['shared_cleanup_pending'], p
    assert_permits(p, False)
    h.action('win.close-window')
    h.select(second, focus=True)
    # B's own quick removal has finished. Only A's held job can account for
    # shared cleanup, even though closing A has cleared its workspace model.
    b = h.policy_idle()
    registry = h.windows()
    a = next((w for w in registry['windows'] if w['id'] == first), None)
    assert a and a['closing'] and a['holds'] > 0, ('Delayed owner already drained', registry)
    evidence = dict(case=h.name, initial=before, closing_registry=registry, sibling=b)
    h.evidence['restricted_owner_cleanup'] = evidence
    assert_permits(b, False)
    assert b['shared_revocation_blocked'] and b['shared_cleanup_pending'], (
        'Closing never-approved A lost its removal scope/key; B can approve before A deletes the grant', registry, b)
    assert not b['pending'] and b['active'] is None, b
    assert trust_records(h.store) == []
    jobs = b['jobs_started']
    h.action('win.workspace-trust')
    denied = h.probe('policy')
    assert_permits(denied, False)
    assert denied['shared_cleanup_pending'] and not denied['confirmation'] and not denied['dialog'], denied
    assert denied['jobs_started'] == jobs, ('Early approval started during retired-owner cleanup', denied)
    assert trust_records(h.store) == [], 'Early confirmation wrote a new disk approval'
    still_closing = h.windows()
    assert any(w['id'] == first and w['closing'] and w['holds'] > 0 for w in still_closing['windows']), still_closing
    evidence['denied_while_owner_held'] = denied
    h.gone(first)
    h.drained(1)
    b = h.policy_idle()
    assert not b['shared_cleanup_pending'], b
    assert_permits(b, False)
    approved = confirm_scope(h)
    key = approved['fingerprint']
    assert trust_records(h.store) == [key], (approved, trust_records(h.store))
    saved = h.store.read_bytes()
    # Revalidation actually consults disk; it must not merely retain an in-memory
    # permit after the retired owner deletes the newly approved fingerprint.
    h.command('policy-recheck')
    revalidated = h.policy_idle()
    assert_permits(revalidated, True)
    assert revalidated['fingerprint'] == key and h.store.read_bytes() == saved, revalidated
    evidence.update(approved=approved, revalidated=revalidated, store_sha256=digest(saved))
    h.stop()
    assert h.store.read_bytes() == saved
    h.launch()
    h.workspace(root)
    restored = h.policy_idle()
    assert_permits(restored, True)
    assert restored['fingerprint'] == key and h.store.read_bytes() == saved, restored
    evidence['restored_after_restart'] = restored
    h.verify_files()


def reservation(h, owner, document, path):
    expected = dict(window=owner, document=document, path=str(path.resolve()))
    p = wait_for(lambda: p if (p := h.windows())['saves'] else None)
    assert p['saves'] == [expected], (expected, p)
    return p


def snapshot_etag(h, document):
    # Workspace probes intentionally omit opaque etags. The real explicit
    # checkpoint captures them without updating a document's disk baseline.
    h.action('win.save-workspace-session')
    wait_for(lambda: h.probe('session')['status'] == 'saved')
    _, _, recovery = decode_slot(h.slot.read_bytes())
    _, checksum, body = recovery.split(b'\n', 2)
    assert digest(body).encode() == checksum
    doc = next(d for d in json.loads(body)['documents'] if d['id'] == document)
    assert doc['saved_etag'] is not None, doc
    return doc['saved_etag']


def save_pair(h, alias=False):
    first, second = pair(h)
    path = h.write(h.fixtures / 'shared.txt', 'unchanged original disk\n')
    requested = path
    if alias:
        requested = h.fixtures / 'alias.txt'
        requested.symlink_to(path.name)
    for identity, text in ((first, 'first reserved edit π'), (second, 'second reserved edit 🙂')):
        h.select(identity, focus=True)
        h.command('open', requested if identity == second else path)
        wait_for(lambda: h.document(path))
        h.replace_keyboard(text)
    return first, second, path, requested


def save_overlap(h, alias=False):
    first, second, path, requested = save_pair(h, alias)
    second_doc = h.document(path)
    etag = snapshot_etag(h, second_doc['id'])
    original = path.read_bytes()
    h.select(first)
    first_doc = h.document(path)
    h.command('save-delay', 3000)
    h.action('win.save')
    reserved = reservation(h, first, first_doc['id'], path)
    h.select(second, focus=True)
    h.key('s', 'ctrl')
    assert 'Save destination is busy' in h.state()['notice'], h.state()
    assert h.document(path) == second_doc and not h.state()['dialog'], h.state()
    assert path.read_bytes() == original
    # Save As and existing symlink aliases must use the same canonical admission.
    h.command('save-path', requested)
    assert 'Save destination is busy' in h.state()['notice'] and h.document(path) == second_doc, h.state()
    assert snapshot_etag(h, second_doc['id']) == etag, 'Busy rejection replaced the losing document etag'
    reservation(h, first, first_doc['id'], path)
    assert path.read_bytes() == original
    h.evidence.setdefault('save_reservations', []).append(dict(case=h.name, stage='ordinary-and-save-as-rejected', registry=reserved, retained_etag=etag))
    h.drained(2)
    assert path.read_text() == first_doc['text']
    h.expected[path] = digest(path.read_bytes())
    h.key('s', 'ctrl')
    wait_for(lambda: h.state()['dialog'])
    assert h.native_probe()['dialog'] == 3, 'Post-overlap Save must still see the old etag conflict'
    assert not h.windows()['saves']
    # Leave B's conflict dialog open, acquire A's next reservation, then choose
    # the real Overwrite response. Force must not bypass cross-window admission.
    h.select(first)
    h.command('insert', ' next')
    next_doc = h.document(path)
    h.command('save-delay', 1500)
    h.action('win.save')
    reserved = reservation(h, first, first_doc['id'], path)
    h.select(second)
    h.command('respond', response=3)
    assert 'Save destination is busy' in h.state()['notice'], h.state()
    assert h.document(path) == second_doc and not h.state()['dialog'], h.state()
    assert path.read_text() == first_doc['text']
    reservation(h, first, first_doc['id'], path)
    h.evidence.setdefault('save_reservations', []).append(dict(case=h.name, stage='force-rejected', registry=reserved))
    h.drained(2)
    assert path.read_text() == next_doc['text']
    h.expected[path] = digest(path.read_bytes())
    h.select(second, focus=True)
    h.key('s', 'ctrl')
    wait_for(lambda: h.state()['dialog'])
    assert h.native_probe()['dialog'] == 3
    h.command('respond', response=3)
    wait_for(lambda: not h.document(path)['dirty'])
    h.drained(2)
    assert path.read_text() == second_doc['text']
    h.expected[path] = digest(path.read_bytes())
    if alias:
        assert requested.is_symlink() and requested.resolve() == path and requested.read_bytes() == path.read_bytes()
    h.verify_files()


def save_cancel_release(h):
    first, second, path, _ = save_pair(h)
    before = path.read_bytes()
    second_doc = h.document(path)
    h.select(first)
    doc = h.document(path)
    h.command('save-delay', 1200)
    h.action('win.save')
    reservation(h, first, doc['id'], path)
    h.command('cancel-io')
    h.select(second, focus=True)
    h.action('win.save')
    assert 'Save destination is busy' in h.state()['notice'], h.state()
    assert h.document(path) == second_doc and path.read_bytes() == before
    h.drained(2)
    assert path.read_bytes() == before
    with h.at(first):
        assert h.document(path) == doc, h.state()
    # The sibling's original etag must still work after the cancelled writer.
    h.action('win.save')
    wait_for(lambda: not h.document(path)['dirty'])
    h.drained(2)
    assert path.read_text() == second_doc['text']
    h.expected[path] = digest(path.read_bytes())
    h.verify_files()


def save_failure_release(h):
    first, second, path, _ = save_pair(h)
    destination = h.fixtures / 'missing-parent' / 'copy.txt'
    original = path.read_bytes()
    second_doc = h.document(path)
    h.select(first)
    doc = h.document(path)
    h.command('save-delay', 1200)
    h.command('save-path', destination)
    reservation(h, first, doc['id'], destination)
    h.select(second, focus=True)
    h.command('save-path', destination)
    assert 'Save destination is busy' in h.state()['notice'], h.state()
    assert h.document(path) == second_doc and not destination.exists()
    h.drained(2)
    with h.at(first):
        assert h.document(path) == doc, h.state()
    assert not destination.exists() and path.read_bytes() == original
    assert any('event=document-save-failed' in line for line in h.app.lines), h.app.lines[-30:]
    destination.parent.mkdir()
    h.command('save-path', destination)
    wait_for(lambda: d if (d := h.document(destination)) and not d['dirty'] else None)
    h.drained(2)
    assert destination.read_text() == second_doc['text'] and path.read_bytes() == original
    h.expected[destination] = digest(destination.read_bytes())
    h.verify_files()


SCENARIOS = [
    ('keyboard_palette_win_actions_dirty_close_first', routes_and_close),
    ('independent_documents_groups_docks_roots_search_trust', isolation),
    ('quit_all_serial_cancel_and_deny_new', quit_serial),
    *[(f'delayed_{kind}_close_drains', lambda h, kind=kind: delayed_close(h, kind))
      for kind in ('search', 'browser', 'load', 'policy', 'session', 'session_load')],
    ('recovery_startup_close_drains', recovery_startup_drain),
    ('registry_reuse_24_cycles', registry_reuse),
    ('window_limit_includes_draining', window_limit),
    ('same_file_independent_edits_save_conflict', save_conflict),
    ('recovery_discovery_first_only_kept_not_reoffered', recovery_kept),
    ('two_journals_crash_restore_no_source_writes', recovery_two_journals),
    ('shared_explicit_session_busy_serialization', shared_session_busy),
    ('shared_preferences_root_overrides_scoped_css_screenshot', preferences_and_css),
    ('external_quit_all_clean_sibling_palette_repeated', external_quit_palette),
    ('explorer_real_button_click_chooser_ownership', explorer_button_owners),
    ('native_gtk_resolved_font_broadcast_12_24', native_font_broadcast),
    ('same_scope_revoke_synchronous_cleanup_and_reconfirm', shared_revoke),
    ('failed_revoke_tombstone_survives_source_close', lambda h: shared_revoke(h, fail_write=True)),
    ('overlapping_save_save_as_force_reservations', save_overlap),
    ('canonical_symlink_save_reservation_alias', lambda h: save_overlap(h, alias=True)),
    ('cancelled_save_releases_reservation_retry', save_cancel_release),
    ('failed_save_releases_reservation_retry', save_failure_release),
    ('restricted_revoke_owner_close_blocks_fresh_approval', restricted_revoke_owner_closes),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-windows')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    parser.add_argument('--case', action='append', choices=[name for name, _ in SCENARIOS])
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    scenarios = [(name, run) for name, run in SCENARIOS if not args.case or name in args.case]
    began = time.monotonic()
    evidence = dict(status='running', checks=[], invocation=[sys.executable, *sys.argv],
                    binary=str(args.binary.resolve()), runtime_budget_seconds=550,
                    selected_cases=[name for name, _ in scenarios], total_available_cases=len(SCENARIOS),
                    isolation='Private headless compositor and D-Bus, per-case disposable HOME/XDG/fixtures',
                    scope='Independent windows, real keyboard/palette and exported win.* GActions; no tab transfer/shared docs')

    def expired(_signal, _frame):
        raise BudgetExpired('Multiwindow acceptance exceeded its 550-second budget')

    previous = signal.signal(signal.SIGALRM, expired)
    signal.alarm(550)
    save(output, evidence)
    try:
        binary = args.binary.resolve().read_bytes()
        evidence['binary_sha256'] = digest(binary)
        assert all(marker in binary for marker in (b'CORAL_WINDOWS ', b'CORAL_COMMAND_DONE', b'CORAL_SESSION ')), 'Build with -Dtest-hooks=true'
        del binary
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
            staged_styles = stage_styles(session, evidence)
            if any(name == 'explorer_real_button_click_chooser_ownership' for name, _ in scenarios):
                start_accessibility(session)
            for name, scenario in scenarios:
                record = dict(name=name, status='running')
                evidence['checks'].append(record)
                save(output, evidence)
                start, h = time.monotonic(), None
                child_start = len(session.children)
                print('RUN', name, flush=True)
                try:
                    h = WindowHarness(session, args.binary.resolve(), output, evidence, name, began + 545)
                    scenario(h)
                    h.stop()
                    h.verify_files()
                    record.update(status='passed', fixture_hashes={str(p): v for p, v in h.expected.items()})
                    print('PASS', name, flush=True)
                except Exception as exc:
                    record.update(status='failed', error=str(exc), traceback=traceback.format_exc(),
                                  last_probe=h.last.copy() if h else {})
                    print('FAIL', name, str(exc)[:1800], flush=True)
                    if h:
                        for label, operation in (('screenshot', lambda: h.screenshot('failure')),
                                                 ('fixture_integrity', h.verify_files), ('gtk_warnings', h.no_criticals)):
                            try:
                                operation()
                            except Exception:
                                record[label + '_error'] = traceback.format_exc()
                finally:
                    if h:
                        h.load_gate.unlink(missing_ok=True)
                    for child in reversed(session.children[child_start:]):
                        child.stop()
                    del session.children[child_start:]
                    record['seconds'] = time.monotonic() - start
                    save(output, evidence)
            for entry in staged_styles:
                for key in ('source', 'path'):
                    assert digest(Path(entry[key]).read_bytes()) == entry['sha256'], ('Style resource changed', entry)
        evidence['status'] = 'passed' if all(c['status'] == 'passed' for c in evidence['checks']) else 'failed'
    except (Exception, BudgetExpired):
        evidence.update(status='failed', fatal=traceback.format_exc())
        print(evidence['fatal'], file=sys.stderr, flush=True)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        completed = {c['name'] for c in evidence['checks']}
        for name, _ in scenarios:
            if name not in completed:
                evidence['checks'].append(dict(name=name, status='blocked', reason='Setup/runtime budget failed'))
        for record in evidence['checks']:
            if record['status'] == 'running':
                record.update(status='failed', error='Interrupted; see suite fatal error')
        evidence['seconds'] = time.monotonic() - began
        evidence['counts'] = {status: sum(c['status'] == status for c in evidence['checks']) for status in ('passed', 'failed', 'blocked')}
        save(output, evidence)
    print(f"{evidence['status'].upper()}: {evidence['counts']}; {output / 'results.json'}", flush=True)
    return 0 if evidence['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
