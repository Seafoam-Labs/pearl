#!/usr/bin/env python3
"""Native safe-settings/trust acceptance; never runs the search acceptance suite.

Run via zig build policy. All input goes to a private headless Wayland session;
all HOME/XDG state and repository fixtures are disposable. The only capability
exercise is policy-gate (a pending permit, NOT a task runner). Sentinel scripts
are inert fixtures: this harness never invokes repository executable content.
Evidence, including partial failures, goes to .cache/coral-policy. A 500-second
whole-suite alarm leaves cleanup headroom within the 540-second runtime budget.
"""
import argparse
import configparser
import hashlib
import json
import os
import shutil
import signal
import stat
import sys
import time
import traceback
from pathlib import Path

# Import only the reusable input/probe/file helpers, not search.run or main.
# search also establishes the shared scripts/integration helper import paths.
from search import PEARL, Harness
from pearl_session import PrivateSession, fixture_prefix, wait_for
from test_surfaces import IPC

KEYS = ('lines', 'wrap', 'spaces', 'indent')
DEFAULTS = dict(lines=True, wrap=True, spaces=True, indent=4)


def save(output, evidence):
    (output / 'results.json').write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + '\n')


class BudgetExpired(BaseException):
    pass


class PolicyHarness(Harness):
    def __init__(self, session, binary, output, evidence, name, deadline):
        # Reuse Harness's protocol, but not its search-specific launch/fixtures.
        self.session, self.binary, self.output, self.evidence = session, binary, output, evidence
        self.name, self.deadline = name, deadline
        self.ipc = IPC(session)
        self.last, self.expected, self.protected = {}, {}, {}
        self.serial, self.peak_rss = 0, 0
        self.app = None
        base = session.base / name
        for key, leaf in (('HOME', 'home'), ('XDG_CONFIG_HOME', 'config'),
                          ('XDG_STATE_HOME', 'state'), ('XDG_CACHE_HOME', 'cache'),
                          ('XDG_DATA_HOME', 'data')):
            directory = base / leaf
            directory.mkdir(parents=True, mode=0o700)
            session.env[key] = str(directory)
        self.fixtures = base / 'fixtures'
        self.fixtures.mkdir()
        self.command_path = base / 'command.ini'
        session.env['CORAL_TEST_COMMAND'] = str(self.command_path)
        self.preferences = Path(session.env['XDG_CONFIG_HOME']) / 'coral/preferences.ini'
        self.store = Path(session.env['XDG_STATE_HOME']) / 'coral/trust/store'
        self.sentinels = []
        self.launch()

    def launch(self, *paths):
        self.serial += 1
        self.app = self.session.child(f'{self.name}-{self.serial}', [self.binary, *paths], G_DEBUG='fatal-criticals')
        window = wait_for(lambda: next((w for w in self.ipc.state() if w['kind'] == 'window'), None))
        self.ipc.call('command', action='window.activate', fields={'id': window['id']})
        wait_for(lambda: self.probe('workspace')['documents'])
        wait_for(lambda: not (p := self.probe('projects'))['busy'] and
                 not p['suppression_pending'] and not p['restore_cleanup'], 20)
        self.settled()

    def stop(self, without_session=False):
        if self.app is not None and self.app.proc.poll() is None:
            p = self.probe()
            assert not p['dialog'], p
            assert not any(d['dirty'] for d in p['documents']), p
            self.key('q', 'ctrl')
            if without_session:
                wait_for(lambda: self.probe('lifecycle')['dialog'] == 'close_without_session')
                assert self.probe()['documents'] == p['documents']
                start = len(self.app.lines)
                self.command_path.write_text('[Test]\naction=respond\nresponse=1\n')
                self.key('F11')
                wait_for(lambda: self.app.proc.poll() is not None or
                         'CORAL_COMMAND_DONE' in self.app.lines[start:])
            assert self.app.wait(timeout=12) == 0, self.app.lines[-30:]
        if self.app is not None:
            self.no_criticals()

    def restart(self, *paths):
        self.stop()
        self.launch(*paths)

    def probe(self, kind='policy'):
        p = super().probe(kind)
        if kind == 'policy':
            assert p['worker_limit'] == p['recheck_limit'] == 1, p
            assert p['jobs_started'] - p['jobs_reaped'] == int(p['active'] is not None), p
            assert not p['retired_permit_valid'], p
            assert len(p['permits']) == 6, p
            if p['trust'] == 'restricted' or p['pending']:
                assert not any(p['permits']) and not p['gate_valid'], p
        return p

    def settled(self, timeout=15):
        return wait_for(lambda: p if not ((p := self.probe())['pending'] or p['preferences_pending']) else None, timeout)

    def snapshot(self, label):
        p = self.probe()
        self.evidence.setdefault('observations', []).append({'case': self.name, 'label': label, 'policy': p})
        return p

    def screenshot(self, name):
        super().screenshot(self.name + '-' + name)

    def open_workspace(self, path, folder=False):
        browser = super().open_workspace(path, folder)
        assert browser['error_name'] is None, browser
        return self.settled()

    def rescan(self, error=False):
        self.command('workspace-rescan')
        browser = self.browser()
        assert bool(browser['error_name']) == error, browser
        p = self.settled()
        if error:
            self.restricted(p)
            assert p['status'] == 'failed' and p['store_error'], p
            self.snapshot('rejected-rescan:' + browser['error_name'])
        return p

    def restricted(self, p=None):
        p = p or self.settled()
        assert p['trust'] == 'restricted' and not any(p['permits']), p
        assert not p['gate_pending'] and not p['gate_valid'], p
        self.checks()
        return p

    def trusted(self, p=None):
        p = p or self.settled()
        assert p['trust'] == p['status'] == 'trusted' and all(p['permits']), p
        assert p['store_error'] is None, p
        self.checks()
        return p

    def checks(self):
        lines, _ = self.command('policy-checks')
        assert 'CORAL_POLICY_CHECKS ok=1' in lines, lines

    def confirmation(self):
        self.command('policy-trust-confirm')
        p = self.probe()
        assert p['dialog'] and p['confirmation'], p
        return p

    def approve(self):
        self.confirmation()
        self.command('respond', response=1)
        return self.trusted()

    def gate(self):
        self.command('policy-gate')
        p = self.probe()
        assert p['gate_pending'] and p['gate_valid'], p
        return p

    def invalidated(self, before):
        p = self.probe()
        self.restricted(p)
        assert p['gate_cancelled'] and p['policy_generation'] > before['policy_generation'], p
        return p

    def effective(self, path, values, origins, language=None, root=None):
        p = self.probe()
        d = next(d for d in p['documents'] if d['path'] == (str(path) if path is not None else None))
        expected = dict(zip(KEYS, origins)) if not isinstance(origins, dict) else origins
        assert d['effective']['values'] == values, (d, values)
        assert d['effective']['origins'] == expected, (d, expected)
        assert d['effective']['context'] == {'language': language, 'root_path': str(root) if root else None}, d
        views = [v for v in p['views'] if v['document'] == d['id']]
        assert views, d
        for view in views:
            assert {key: view[key] for key in KEYS} == values, (view, values)
            assert view['indent_width'] == values['indent'], view
        self.checks()
        return views

    def preference_bytes(self):
        self.settled()
        return self.preferences.read_bytes() if self.preferences.exists() else None

    def inspect_store(self, label):
        directory = self.store.parent
        records = []
        assert not any(directory.is_relative_to(root) for root in self.roots), directory
        assert not directory.is_relative_to(self.manifest.parent), directory
        if directory.exists():
            for path in sorted(directory.iterdir()):
                info = path.lstat()
                item = {'name': path.name, 'mode': oct(stat.S_IMODE(info.st_mode)),
                        'size': info.st_size, 'uid': info.st_uid, 'links': info.st_nlink}
                if stat.S_ISREG(info.st_mode):
                    item['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
                records.append(item)
        self.evidence.setdefault('state_files', []).append({'case': self.name, 'label': label, 'files': records})
        return records

    def fixture(self, settings=None):
        self.roots = [self.fixtures / 'left', self.fixtures / 'right']
        for root in self.roots:
            self.write(root / 'plain.txt', 'safe settings fixture\nsecond line\n')
            self.write(root / 'code.zig', 'const policy_fixture = 1;\n')
            marker = self.fixtures / (root.name + '-EXECUTED')
            script = self.write(root / 'never-run.sh', '#!/bin/sh\nprintf executed > ' + str(marker) + '\n')
            script.chmod(0o700)
            self.sentinels.append(marker)
            self.write(root / '.coral/settings.json', json.dumps({'version': 1, 'settings': {}}))
        self.spec = {'version': 1, 'roots': [{'path': 'left'}, {'path': 'right'}], 'settings': settings or {}}
        self.manifest = self.write(self.fixtures / 'test.coral-workspace', json.dumps(self.spec))
        return self.manifest

    def folder_settings(self, index, values):
        return self.write(self.roots[index] / '.coral/settings.json', json.dumps({'version': 1, 'settings': values}))

    def verify_files(self):
        for marker in self.sentinels:
            assert not marker.exists(), f'Repository executable content ran: {marker}'
        for path, digest in self.expected.items():
            assert path.is_file() and not path.is_symlink(), path
            assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, path


def settings_and_preferences(h):
    h.fixture({'lines': False, 'wrap': False, 'indent': 2,
               'languages': {'zig': {'wrap': True, 'spaces': False, 'indent': 6}}})
    h.folder_settings(0, {'lines': True, 'wrap': False, 'indent': 3,
                          'languages': {'zig': {'indent': 8}}})
    outside = h.write(h.fixtures / 'outside.txt', 'outside root\n')
    h.command('new')
    h.effective(None, DEFAULTS, ['default'] * 4)
    h.open_document(outside)
    h.effective(outside, DEFAULTS, ['default'] * 4)
    assert not any(h.probe()['user_present'].values())
    before = h.preference_bytes()
    h.restricted(h.open_workspace(h.manifest))
    left, right = h.roots
    h.open_document(left / 'plain.txt')
    h.effective(left / 'plain.txt', dict(lines=True, wrap=False, spaces=True, indent=3),
                ['folder', 'folder', 'default', 'folder'], root=left)
    h.open_document(right / 'plain.txt')
    h.effective(right / 'plain.txt', dict(lines=False, wrap=False, spaces=True, indent=2),
                ['workspace', 'workspace', 'default', 'workspace'], root=right)
    assert h.preference_bytes() == before, 'Repository settings wrote user preferences'
    h.command('policy-user', lines='false', wrap='false', spaces='false', indent=5)
    h.settled()
    h.effective(outside, dict(lines=False, wrap=False, spaces=False, indent=5), ['user'] * 4)
    h.effective(left / 'plain.txt', dict(lines=True, wrap=False, spaces=False, indent=3),
                ['folder', 'folder', 'user', 'folder'], root=left)
    # Explicit defaults must have user provenance, not be mistaken for absence.
    h.command('policy-user', lines='true', wrap='true', spaces='true', indent=4)
    h.settled()
    assert all(h.probe()['user_present'].values())
    h.effective(outside, DEFAULTS, ['user'] * 4)
    h.effective(None, DEFAULTS, ['user'] * 4)
    h.open_document(left / 'code.zig')
    h.command('policy-language', 'zig')
    zig = dict(lines=True, wrap=True, spaces=False, indent=8)
    origins = ['folder', 'workspace_language', 'workspace_language', 'folder_language']
    h.effective(left / 'code.zig', zig, origins, 'zig', left)
    h.command('split-group')
    h.command('select', start=0, end=12)
    h.command('excerpt')
    views = h.effective(left / 'code.zig', zig, origins, 'zig', left)
    assert sum(not v['excerpt'] for v in views) == 2 and sum(v['excerpt'] for v in views) == 1, views
    h.command('policy-language', 'text')  # Unknown ID clears the source language.
    h.effective(left / 'code.zig', dict(lines=True, wrap=False, spaces=True, indent=3),
                ['folder', 'folder', 'user', 'folder'], root=left)
    h.command('policy-language', 'zig')
    h.effective(left / 'code.zig', zig, origins, 'zig', left)
    h.open_document(right / 'code.zig')
    h.command('policy-language', 'zig')
    h.effective(right / 'code.zig', dict(lines=False, wrap=True, spaces=False, indent=6),
                ['workspace', 'workspace_language', 'workspace_language', 'workspace_language'], 'zig', right)
    h.command('policy-show')
    assert h.probe()['dialog'] and not h.probe()['confirmation']
    h.screenshot('provenance')
    h.command('respond', response=0)
    saved = h.preference_bytes()
    config = configparser.ConfigParser()
    config.read_string(saved.decode())
    assert all(config['Coral'].getboolean(k) for k in KEYS[:3])
    assert config['Coral'].getint('indent') == 4
    h.command('settings', theme=1, font=17)  # Saving unrelated globals must not copy repo values.
    saved = h.preference_bytes()
    h.restart()
    assert h.preference_bytes() == saved
    h.open_document(outside)
    h.effective(outside, DEFAULTS, ['user'] * 4)
    h.open_workspace(h.manifest)
    h.open_document(left / 'code.zig')
    h.command('policy-language', 'zig')
    h.effective(left / 'code.zig', zig, origins, 'zig', left)
    assert h.preference_bytes() == saved
    h.command('close-workspace')
    wait_for(lambda: not h.probe('browser')['roots'])
    h.settled()
    h.effective(left / 'code.zig', DEFAULTS, ['user'] * 4, 'zig')
    h.snapshot('preferences-reloaded-with-explicit-default-presence')


def longline_language_and_excerpt(h):
    h.fixture({'indent': 8, 'languages': {'c': {'indent': 2}}})
    root = h.roots[0]
    plain = root / 'plain.txt'
    short = h.write(root / 'short.c', 'int policy_fixture = 1;\n')
    original = '/*' + 'aé🌱' * 20000 + '*/'
    assert len(original.encode()) > 16 * 1024 and '\n' not in original
    huge = h.write(root / 'longline.c', original)
    h.restricted(h.open_workspace(h.manifest))
    h.open_document(plain)
    h.effective(plain, dict(DEFAULTS, indent=8),
                ['default', 'default', 'default', 'workspace'], root=root)
    h.open_document(short)
    values = dict(DEFAULTS, indent=2)
    origins = ['default', 'default', 'default', 'workspace_language']
    h.effective(short, values, origins, 'c', root)
    short_policy = next(d for d in h.probe()['documents'] if d['path'] == str(short))
    assert short_policy['parser_attached'] and not short_policy['presentation_limited'], short_policy

    def limited_views():
        views = h.effective(huge, values, origins, 'c', root)
        doc = next(d for d in h.probe()['documents'] if d['path'] == str(huge))
        assert not doc['parser_attached'] and doc['presentation_limited'], doc
        return views

    h.open_document(huge)
    state = wait_for(lambda: p if (p := h.probe('workspace'))['layout_blocked'] and p['syntax_limited'] else None)
    document = next(d for d in state['documents'] if d['path'] == str(huge))
    assert document['text'] == original and not document['dirty'], document
    # Do not use policy-language here: resetting language after fallback would
    # conceal loss of the logical C identity when presentation disables syntax.
    limited_views()
    h.snapshot('logical-c-override-survives-longline-presentation-fallback')
    offset = 12345
    h.command('guard-offset', offset=offset)
    h.key('Return')

    def excerpt_ready():
        p = h.probe('workspace')
        active = next(v for v in p['views'] if v['active'])
        return (p, active) if active['excerpt_start'] is not None else None

    state, view = wait_for(excerpt_ready)
    assert view['document_id'] == document['id'], view
    assert view['excerpt_start'] == len(original[:offset].encode()), view
    assert view['excerpt_end'] == len(original[:offset + 2048].encode()), view
    assert not state['layout_blocked'] and state['editable'], state
    views = limited_views()
    assert any(v['excerpt'] for v in views) and any(not v['excerpt'] for v in views), views
    h.command('select', start=1, end=1)
    wait_for(lambda: h.probe('workspace')['editor_focused'])
    h.text('!')
    edited = original[:offset + 1] + '!' + original[offset + 1:]
    changed = wait_for(lambda: d if (d := h.document(huge))['text'] == edited and d['dirty'] else None)
    assert changed['revision'] > document['revision'], changed
    limited_views()
    h.screenshot('editable-c-excerpt')
    h.snapshot('logical-c-override-survives-excerpt-edit')
    h.key('z', 'ctrl')
    restored = wait_for(lambda: d if (d := h.document(huge))['text'] == original else None)
    assert restored['revision'] > changed['revision'], restored
    limited_views()
    h.snapshot('logical-c-override-survives-excerpt-undo')
    assert huge.read_text() == original, 'Excerpt test wrote the source file'
    # Grouped excerpt history may retain a dirty marker after restoring text.
    # Dispose through native close/discard, never save or manufacture clean state.
    for _ in range(2):
        state = h.probe('workspace')
        index = next(i for i, v in enumerate(state['views']) if v['document_id'] == document['id'])
        h.command('focus-view', index=index)
        h.command('close')
        if h.probe()['dialog']:
            h.command('respond', response=1)
        if h.document(huge) is None:
            break
    assert h.document(huge) is None, 'Long-line fixture still has an open view'


def user_settings_trust_identity(h):
    h.fixture()
    h.command('policy-user', indent=4)
    h.settled()
    h.open_workspace(h.manifest)
    path = h.roots[0] / 'plain.txt'
    h.open_document(path)
    origins = ['default', 'default', 'default', 'user']
    h.effective(path, DEFAULTS, origins, root=h.roots[0])
    approved = h.approve()
    original = approved['fingerprint']
    assert original is not None and approved['expected_fingerprint'] == original
    assert not approved['approval_required'] and approved['user_baseline'] == DEFAULTS
    h.restart()
    p = h.trusted(h.open_workspace(h.manifest))
    assert p['fingerprint'] == original, 'Unchanged user settings lost persisted approval'
    assert p['expected_fingerprint'] == original and not p['approval_required'], p
    h.open_document(path)
    h.gate()
    h.command('policy-user', indent=6)
    p = h.restricted(h.probe())
    assert p['gate_cancelled'], p
    p = h.restricted()
    changed = p['fingerprint']
    assert changed is not None and changed != original, (original, p)
    assert p['policy_fingerprint'] == approved['policy_fingerprint'], p
    assert p['effective_policy_fingerprint'] != approved['effective_policy_fingerprint'], p
    assert p['expected_fingerprint'] == original and p['approval_required'], p
    assert p['user_baseline'] == dict(DEFAULTS, indent=6) and p['user_present']['indent'], p
    h.effective(path, dict(DEFAULTS, indent=6), origins, root=h.roots[0])
    h.snapshot('user-safe-setting-changes-trust-fingerprint-and-retires-permit')
    h.confirmation()
    h.command('respond', response=0)
    h.restricted()
    h.restart()
    p = h.restricted(h.open_workspace(h.manifest))
    assert p['fingerprint'] == changed, p
    h.open_document(path)
    h.effective(path, dict(DEFAULTS, indent=6), origins, root=h.roots[0])
    assert h.approve()['fingerprint'] == changed
    h.restart()
    p = h.trusted(h.open_workspace(h.manifest))
    assert p['fingerprint'] == changed, p
    assert p['expected_fingerprint'] == changed and not p['approval_required'], p
    h.snapshot('changed-user-policy-restores-only-after-fresh-approval')


def absent_preferences(h):
    h.fixture({'lines': False, 'wrap': False, 'spaces': False, 'indent': 8})
    h.open_workspace(h.manifest)
    h.open_document(h.roots[0] / 'plain.txt')
    h.command('settings', theme=2, font=18)
    config = configparser.ConfigParser()
    config.read_string(h.preference_bytes().decode())
    assert not any(k in config['Coral'] for k in KEYS), dict(config['Coral'])
    h.restart()
    h.open_document(h.roots[0] / 'plain.txt')
    h.effective(h.roots[0] / 'plain.txt', dict(lines=False, wrap=False, spaces=False, indent=8),
                ['workspace'] * 4, root=h.roots[0])
    before = h.probe('workspace')['documents']
    h.command('close-workspace')
    wait_for(lambda: not h.probe('browser')['roots'])
    h.settled()
    assert h.probe('workspace')['documents'] == before
    h.effective(h.roots[0] / 'plain.txt', DEFAULTS, ['default'] * 4)
    assert not any(h.probe()['user_present'].values())
    h.snapshot('absent-safe-keys-survive-global-save')


def rescan_and_rejected_settings(h):
    h.fixture({'indent': 2})
    h.open_workspace(h.manifest)
    path = h.roots[0] / 'plain.txt'
    h.open_document(path)
    h.command('split-group')
    h.command('select', start=0, end=8)
    h.command('excerpt')
    h.folder_settings(0, {'wrap': False, 'indent': 7})
    h.rescan()
    values = dict(lines=True, wrap=False, spaces=True, indent=7)
    origins = ['default', 'folder', 'default', 'folder']
    h.effective(path, values, origins, root=h.roots[0])
    h.snapshot('rescan-applies-to-duplicate-and-excerpt-widgets')
    settings = h.roots[1] / '.coral/settings.json'
    original = settings.read_bytes()
    # Reject the entire candidate, not only the bad root. Trust cannot relax schema.
    for label, content in (
        ('parse', '{'),
        ('duplicate', '{"version":1,"settings":{"indent":2,"indent":8}}'),
        ('range', '{"version":1,"settings":{"indent":9}}'),
        ('exec', json.dumps({'version': 1, 'settings': {'command': str(h.roots[1] / 'never-run.sh')}})),
        ('fifo', None), ('symlink', None), ('directory-symlink', None),
    ):
        h.approve()
        h.gate()
        settings.unlink()
        moved = None
        if label == 'fifo':
            os.mkfifo(settings, 0o600)
        elif label == 'symlink':
            target = h.write(h.fixtures / 'external-settings.json', original)
            settings.symlink_to(target)
        elif label == 'directory-symlink':
            directory = settings.parent
            moved = h.fixtures / 'moved-coral'
            directory.rename(moved)
            (moved / 'settings.json').write_bytes(original)
            directory.symlink_to(moved, target_is_directory=True)
        else:
            settings.write_text(content)
        try:
            h.rescan(error=True)
            h.effective(path, values, origins, root=h.roots[0])
            assert h.probe()['gate_cancelled']
            h.snapshot('unsafe-settings-' + label)
        finally:
            if moved:
                settings.parent.unlink()
                moved.rename(settings.parent)
            else:
                settings.unlink()
            settings.write_bytes(original)
        h.rescan()
    # Missing settings are optional, unlike malformed/unsafe settings.
    settings.unlink()
    del h.expected[settings]
    h.rescan()
    h.effective(path, values, origins, root=h.roots[0])
    h.approve()
    original_manifest = h.manifest.read_bytes()
    bad = dict(h.spec, settings={'tasks': [str(h.roots[0] / 'never-run.sh')]})
    h.manifest.write_text(json.dumps(bad))
    try:
        h.rescan(error=True)
        h.snapshot('manifest-executable-key-rejected-while-trusted')
    finally:
        h.manifest.write_bytes(original_manifest)
    h.rescan()


def confirmation_persistence_revoke(h):
    h.fixture()
    h.restricted(h.open_workspace(h.manifest))
    h.command('policy-gate')
    h.restricted()
    h.command('policy-show')
    p = h.probe()
    assert p['dialog'] and not p['confirmation']
    h.command('respond', response=1)  # Provenance -> genuine confirmation, not approval.
    p = h.probe()
    assert p['dialog'] and p['confirmation'] and p['trust'] == 'restricted', p
    h.screenshot('confirmation-cancel')
    h.command('respond', response=0)
    h.restricted()
    assert not h.store.exists(), 'Cancel persisted an approval'
    h.restart()
    h.restricted(h.open_workspace(h.manifest))
    h.approve()
    key = h.probe()['fingerprint']
    records = h.inspect_store('approved')
    assert any(r['name'] == 'store' and r['mode'] == '0o600' for r in records), records
    assert stat.S_IMODE(h.store.parent.stat().st_mode) == 0o700
    h.restart()
    p = h.trusted(h.open_workspace(h.manifest))
    assert p['fingerprint'] == key
    before = h.gate()
    h.command('policy-show')
    h.command('respond', response=2)  # Revoke from the provenance UI.
    h.invalidated(before)
    h.restricted()
    h.inspect_store('revoked')
    h.restart()
    h.restricted(h.open_workspace(h.manifest))
    h.command('policy-show')
    h.command('respond', response=3)
    h.restricted()
    h.snapshot('revoke-persisted-across-restart')


def delayed_revocation(h):
    h.fixture()
    h.open_workspace(h.manifest)
    h.approve()
    before = h.gate()
    h.command('policy-delay', 1800)
    h.command('policy-revoke')
    p = h.invalidated(before)
    assert p['pending'] and p['active'] == 'revoke', p
    h.restricted()
    h.restart()
    h.restricted(h.open_workspace(h.manifest))
    h.snapshot('permit-invalid-before-durable-revocation')


def exact_scope(h):
    h.fixture({'indent': 2})
    h.open_workspace(h.manifest)
    original = h.approve()['fingerprint']
    h.folder_settings(0, {'indent': 5})
    p = h.restricted(h.rescan())
    assert p['fingerprint'] != original
    policy_key = h.approve()['fingerprint']
    old = h.roots[0].with_name('left-original')
    h.roots[0].rename(old)
    # Retain the original inode to make replacement deterministic.
    for path in list(h.expected):
        if path.is_relative_to(h.roots[0]):
            digest = h.expected.pop(path)
            h.expected[old / path.relative_to(h.roots[0])] = digest
    h.roots[0].mkdir()
    h.folder_settings(0, {'indent': 5})
    p = h.restricted(h.rescan())
    assert p['fingerprint'] != policy_key
    replaced = h.approve()['fingerprint']
    h.spec['exclude'] = ['never-run.sh']
    h.write(h.manifest, json.dumps(h.spec))
    p = h.restricted(h.rescan())
    assert p['fingerprint'] != replaced
    h.approve()
    alternate = h.write(h.fixtures / 'other.coral-workspace', json.dumps(h.spec))
    h.restricted(h.open_workspace(alternate))
    h.approve()
    h.restricted(h.open_workspace(h.roots[0], folder=True))
    h.command('close-workspace')
    wait_for(lambda: not h.probe('browser')['roots'])
    h.settled()
    h.spec['roots'] = [{'path': 'right'}]
    h.write(h.manifest, json.dumps(h.spec))
    h.restricted(h.open_workspace(h.manifest))
    h.snapshot('policy-root-inode-manifest-and-root-set-scopes-distinct')


def previously_approved_root_incarnation(h):
    h.fixture()
    root = h.roots[0]
    parked_a = h.fixtures / 'incarnation-a'
    parked_b = h.fixtures / 'incarnation-b'

    def node(path):
        info = path.stat()
        return info.st_dev, info.st_ino

    def park(source, destination):
        identity = node(source)
        source.rename(destination)
        assert node(destination) == identity
        for path in list(h.expected):
            if path.is_relative_to(source):
                digest = h.expected.pop(path)
                h.expected[destination / path.relative_to(source)] = digest

    incarnation_a = node(root)
    h.open_workspace(h.manifest)
    key_a = h.approve()['fingerprint']
    assert key_a is not None
    h.stop()
    park(root, parked_a)
    # Same lexical path and contents, distinct retained directory identities.
    # Never delete either incarnation or depend on allocator/inode reuse timing.
    shutil.copytree(parked_a, root)
    for path, digest in list(h.expected.items()):
        if path.is_relative_to(parked_a):
            h.expected[root / path.relative_to(parked_a)] = digest
    incarnation_b = node(root)
    assert incarnation_b != incarnation_a
    h.launch()
    h.restricted(h.open_workspace(h.manifest))
    key_b = h.approve()['fingerprint']
    assert key_b is not None and key_b != key_a
    h.inspect_store('both-root-incarnations-approved-through-dialogs')
    h.restart()
    p = h.trusted(h.open_workspace(h.manifest))
    assert p['fingerprint'] == key_b, 'Initial restart must restore approved B'
    h.stop()
    park(root, parked_b)
    park(parked_a, root)
    assert node(root) == incarnation_a and node(parked_b) == incarnation_b
    h.launch()
    p = h.trusted(h.open_workspace(h.manifest))
    assert p['fingerprint'] == key_a, 'Initial restart must restore approved A'
    h.gate()
    # Change the live owner's root from A to already-approved B. A fresh process
    # may load B's approval, but ongoing verification must not adopt another key.
    park(root, parked_a)
    park(parked_b, root)
    assert node(root) == incarnation_b and node(parked_a) == incarnation_a
    h.command('policy-recheck')
    p = h.restricted(h.probe())
    assert p['gate_cancelled'], p
    h.restricted()
    h.browser()
    p = h.restricted()  # Watch completion must not silently grant the persisted B key.
    assert p['fingerprint'] == key_b and p['expected_fingerprint'] == key_a, p
    assert p['approval_required'], p
    h.evidence.setdefault('root_incarnations', []).append({
        'case': h.name, 'a': {'device_inode': incarnation_a, 'fingerprint': key_a},
        'b': {'device_inode': incarnation_b, 'fingerprint': key_b},
        'restart_restored_both': True, 'ongoing_revalidation_rejected_b': True,
    })
    h.snapshot('ongoing-revalidation-rejects-previously-approved-root-incarnation')


def stale_confirmation(h):
    h.fixture()
    other = h.write(h.fixtures / 'other.coral-workspace', json.dumps({'version': 1, 'roots': [{'path': 'right'}]}))
    for action in ('switch', 'revoke'):
        h.open_workspace(h.manifest)
        h.confirmation()
        if action == 'switch':
            h.open_workspace(other)
        else:
            h.command('policy-revoke')
            h.settled()
        p = h.probe()
        assert p['dialog'] and not p['confirmation'], p
        h.command('respond', response=1)
        h.restricted()
        h.restart()
        h.restricted(h.open_workspace(h.manifest))
        h.snapshot('stale-dialog-' + action)


def stale_worker(h, delivery, action):
    h.fixture()
    other = h.write(h.fixtures / 'other.coral-workspace', json.dumps({'version': 1, 'roots': [{'path': 'right'}]}))
    h.open_workspace(h.manifest)
    h.confirmation()
    h.command('policy-delivery-delay' if delivery else 'policy-delay', 2200)
    h.command('respond', response=1)
    p = h.probe()
    assert p['active'] == 'approve' and p['pending'], p
    if delivery:
        # Observe the worker's durable write before invalidating owner delivery.
        # This is a real on-disk approval, never a manufactured trust fixture.
        wait_for(lambda: h.store.exists() and h.store.stat().st_size > 0, 2)
        assert h.probe()['active'] == 'approve'
        h.inspect_store('approval-written-before-delivery')
    if action == 'switch':
        h.command('open-workspace', other)
    else:
        h.command('policy-revoke')
    h.restricted(h.probe())
    h.browser()
    h.restricted()
    h.inspect_store('stale-approval-retired')
    h.restart()
    h.restricted(h.open_workspace(h.manifest))
    h.restricted(h.open_workspace(other))
    h.snapshot('stale-worker-did-not-persist-trust')


def damaged_state(h):
    h.fixture()
    h.open_workspace(h.manifest)
    h.approve()
    approved = h.store.read_bytes()
    target = h.fixtures / 'untrusted-store-target'
    target.write_bytes(approved)
    target.chmod(0o600)
    h.expected[target] = hashlib.sha256(approved).hexdigest()
    for damage in ('corrupt', 'mode', 'fifo', 'symlink', 'directory-mode', 'missing'):
        h.store.unlink()
        if damage == 'corrupt':
            h.store.write_bytes(b'not a Coral trust store\n')
            h.store.chmod(0o600)
        elif damage == 'mode':
            h.store.write_bytes(approved)
            h.store.chmod(0o644)
        elif damage == 'fifo':
            os.mkfifo(h.store, 0o600)
        elif damage == 'symlink':
            h.store.symlink_to(target)
        elif damage == 'directory-mode':
            h.store.write_bytes(approved)
            h.store.chmod(0o600)
            h.store.parent.chmod(0o755)
        try:
            before = h.gate() if h.probe()['trust'] == 'trusted' else None
            h.command('policy-recheck')
            if before:
                h.invalidated(before)
            p = h.restricted()
            if damage != 'missing':
                assert p['status'] == 'failed' and p['store_error'], p
            h.snapshot('state-' + damage)
            # This loop tests a fresh trust lookup, not automatic layout restore.
            # Explicit workspace CLI also exercises startup suppression without
            # removing any retained project or trust state.
            h.restart('--workspace', h.manifest)
            assert h.browser()['manifest'] == str(h.manifest)
            p = h.restricted(h.settled())
            if damage != 'missing':
                assert p['status'] == 'failed' and p['store_error'], p
            h.inspect_store('restart-' + damage)
        finally:
            h.store.parent.chmod(0o700)
            if h.store.exists() or h.store.is_symlink():
                h.store.unlink()
            h.store.write_bytes(approved)
            h.store.chmod(0o600)
        h.command('policy-recheck')
        if damage == 'missing':
            # Missing records still allow the initial lookup to anchor the same
            # verified identity; later restoration is not an incarnation switch.
            h.trusted()
        else:
            # An unsafe/corrupt initial load never established an expected key.
            # Repairing disk state cannot turn an ongoing lookup into a restore.
            p = h.restricted()
            assert p['approval_required'] and p['store_error'] is None, p
            assert p['expected_fingerprint'] is None, p
            h.snapshot('repaired-state-requires-fresh-approval-' + damage)
            h.approve()
    h.stop()
    # Reads of absent state mean restricted. Approval cannot provision missing
    # state-home ancestors: only the app-owned coral/trust children may be made.
    state_home = Path(h.session.env['XDG_STATE_HOME'])
    missing = state_home / 'missing-parent' / 'state'
    h.session.env['XDG_STATE_HOME'] = str(missing)
    h.launch()
    h.restricted(h.open_workspace(h.manifest))
    assert not missing.exists()
    h.confirmation()
    h.command('respond', response=1)
    p = h.restricted()
    assert p['status'] == 'failed' and p['store_error'], p
    assert not missing.exists()
    h.snapshot('missing-state-home-cannot-persist-approval')
    h.stop(without_session=True)
    assert not missing.exists()
    inside = h.roots[0] / 'machine-state'
    inside.mkdir(mode=0o700)
    h.session.env['XDG_STATE_HOME'] = str(inside)
    h.launch()
    p = h.restricted(h.open_workspace(h.manifest))
    assert p['status'] == 'failed' and 'StateInsideWorkspace' in p['store_error'], p
    h.snapshot('repository-cannot-be-trust-authority')


def failed_writes(h):
    h.fixture()
    h.open_workspace(h.manifest)
    h.confirmation()
    h.command('policy-fail-write')
    h.command('respond', response=1)
    p = h.restricted()
    assert p['status'] == 'failed' and p['store_error'], p
    h.snapshot('failed-approval-write')
    h.restart()
    h.restricted(h.open_workspace(h.manifest))
    h.approve()
    before = h.gate()
    h.command('policy-fail-write')
    h.command('policy-revoke')
    h.invalidated(before)
    p = h.restricted()
    assert p['failed_revokes'] and p['store_error'], p
    h.command('policy-recheck')
    h.restricted()
    h.snapshot('failed-revoke-remains-restricted-with-visible-error')
    # An injected failure means disk was not changed; do not claim impossible
    # cross-process durability. Explicit retry must persist the revocation.
    h.command('policy-revoke')
    p = h.restricted()
    assert not p['failed_revokes'] and p['store_error'] is None, p
    h.restart()
    h.restricted(h.open_workspace(h.manifest))
    h.inspect_store('successful-explicit-retry')


def delayed_shutdown(h):
    h.fixture()
    h.open_workspace(h.manifest)
    h.approve()
    before = h.gate()
    h.command('policy-delay', 4000)
    h.command('policy-recheck')
    p = h.invalidated(before)
    assert p['active'] == 'recheck', p
    lines, elapsed = h.command('policy-checks')
    assert 'CORAL_POLICY_CHECKS ok=1' in lines and elapsed < 1, (lines, elapsed)
    h.command('policy-show')
    assert h.probe()['dialog']
    h.screenshot('responsive-during-delayed-worker')
    h.command('respond', response=0)
    assert h.probe()['active'] == 'recheck', 'Delay elapsed before shutdown test'
    began = time.monotonic()
    h.key('q', 'ctrl')
    wait_for(lambda: not any(w['kind'] == 'window' for w in h.ipc.state()), 2)
    window_seconds = time.monotonic() - began
    assert window_seconds < 2 and h.app.proc.poll() is None, 'Window did not close ahead of retained worker'
    assert h.app.wait(timeout=8) == 0, h.app.lines[-30:]
    h.no_criticals()
    h.evidence['shutdown'] = {'input_ack_seconds': elapsed, 'window_close_seconds': window_seconds,
                              'window_closed_before_worker_exit': True, 'exit_status': 0}


SCENARIOS = [
    ('settings_and_preferences', settings_and_preferences),
    ('longline_language_and_excerpt', longline_language_and_excerpt),
    ('user_settings_trust_identity', user_settings_trust_identity),
    ('absent_preferences', absent_preferences),
    ('rescan_and_rejected_settings', rescan_and_rejected_settings),
    ('confirmation_persistence_revoke', confirmation_persistence_revoke),
    ('delayed_revocation', delayed_revocation),
    ('exact_scope', exact_scope),
    ('previously_approved_root_incarnation', previously_approved_root_incarnation),
    ('stale_confirmation', stale_confirmation),
    ('stale_approval_switch', lambda h: stale_worker(h, False, 'switch')),
    ('stale_approval_revoke', lambda h: stale_worker(h, False, 'revoke')),
    ('stale_delivery_switch', lambda h: stale_worker(h, True, 'switch')),
    ('stale_delivery_revoke', lambda h: stale_worker(h, True, 'revoke')),
    ('damaged_state', damaged_state),
    ('failed_writes', failed_writes),
    ('delayed_shutdown', delayed_shutdown),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-policy')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    began = time.monotonic()
    evidence = {'status': 'running', 'checks': [], 'runtime_budget_seconds': 500,
                'measurement_note': 'Native GTK properties and origins; Wayland key-to-handler acknowledgement, not frame latency. Gates execute nothing.',
                'isolation': 'Private headless compositor, D-Bus, HOME and XDG; independent per-group config/state; restarts preserve that group state.'}

    def expired(_signal, _frame):
        raise BudgetExpired('Policy acceptance exceeded the 500-second whole-suite budget')

    previous = signal.signal(signal.SIGALRM, expired)
    signal.alarm(500)
    save(output, evidence)
    try:
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
            for name, scenario in SCENARIOS:
                record: dict[str, object] = {'name': name, 'status': 'running'}
                evidence['checks'].append(record)
                save(output, evidence)
                start, h = time.monotonic(), None
                child_start = len(session.children)
                print('RUN', name, flush=True)
                try:
                    h = PolicyHarness(session, args.binary.resolve(), output, evidence, name, began + 495)
                    scenario(h)
                    h.stop()
                    h.verify_files()
                    record.update(status='passed', fixture_hashes_verified=len(h.expected), executable_sentinels_absent=len(h.sentinels))
                    print('PASS', name, flush=True)
                except Exception as exc:
                    record.update(status='failed', error=str(exc), traceback=traceback.format_exc(),
                                  last_probe=h.last.copy() if h else {})
                    print('FAIL', name, str(exc)[:1800], flush=True)
                    if h:
                        try:
                            h.screenshot('failure')
                            h.verify_files()
                        except Exception:
                            record['failure_evidence_error'] = traceback.format_exc()
                finally:
                    # Also clean up failed launches, before __init__ returned h.
                    for child in reversed(session.children[child_start:]):
                        child.stop()
                    del session.children[child_start:]
                    record['seconds'] = time.monotonic() - start
                    save(output, evidence)
        evidence['status'] = 'passed' if all(c['status'] == 'passed' for c in evidence['checks']) else 'failed'
    except (Exception, BudgetExpired):
        evidence.update(status='failed', fatal=traceback.format_exc())
        print(evidence['fatal'], file=sys.stderr, flush=True)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        completed = {c['name'] for c in evidence['checks']}
        for name, _ in SCENARIOS:
            if name not in completed:
                evidence['checks'].append({'name': name, 'status': 'blocked', 'reason': 'Suite setup or runtime budget failed'})
        for record in evidence['checks']:
            if record['status'] == 'running':
                record.update(status='failed', error='Interrupted; see suite fatal error')
        evidence['seconds'] = time.monotonic() - began
        save(output, evidence)
    passed = sum(c['status'] == 'passed' for c in evidence['checks'])
    print(f"{evidence['status'].upper()}: {passed}/{len(SCENARIOS)} native policy groups; {output / 'results.json'}", flush=True)
    return 0 if evidence['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
