#!/usr/bin/env python3
"""Targeted workspace permit/LSP lifecycle regression in a private native session.

Build a hooks-enabled Coral, then run this with --binary PATH --aqueous-prefix /usr.
Uses automatic approval and the production accept action with explicit workspace trust; only the
configured, repository-owned fake LSP executes. All config and transcripts are
private disposable fixtures. No language/controller test bypasses are used.
"""
import argparse
import hashlib
import json
import os
import sys
import tempfile
import time
from pathlib import Path

TESTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TESTS))
import policy
from policy import PolicyHarness, wait_for

FAKE = TESTS / 'fixtures/fake_lsp.py'


class LifecycleHarness(PolicyHarness):
    isolated_app_cwd = True

    def launch(self, *paths):
        case_output = self.output / self.name
        case_output.mkdir(exist_ok=True)
        # Retain prior evidence without including its messages in this launch.
        self.transcripts = Path(tempfile.mkdtemp(prefix='run-', dir=case_output))
        config = Path(self.session.env['HOME']) / '.config/coral/languages.json'
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(json.dumps({'version': 1, 'servers': [{
            'language': 'zig', 'argv': [sys.executable, str(FAKE), '--log',
                                      str(self.transcripts / 'lsp.jsonl'), '--log-sequence'],
            'env': {'PATH': '/usr/bin:/bin'}, 'cwd': 'root',
        }]}))
        config.chmod(0o600)
        super().launch(*paths)

    def messages(self):
        records = []
        for path in sorted(self.transcripts.glob('lsp.*.jsonl')):
            for line in path.read_text().splitlines():
                record = json.loads(line)
                if record['kind'] == 'receive':
                    records.append(record['message'])
        return records

    def peers(self):
        # Check the actual fake-server process, not only an owner-side slot.
        children, pending = set(), [self.app.proc.pid]
        while pending:
            parent = pending.pop()
            for path in Path(f'/proc/{parent}/task').glob('*/children'):
                try:
                    for pid in map(int, path.read_text().split()):
                        if pid not in children:
                            children.add(pid)
                            pending.append(pid)
                except (FileNotFoundError, ProcessLookupError):
                    pass
        peers = set()
        for pid in children:
            try:
                if str(FAKE).encode() in Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0'):
                    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
                    peers.add((int(pid), fields[19]))
            except FileNotFoundError:
                pass
        return peers

    def start_server(self):
        p = wait_for(lambda: p if (p := self.probe('language'))['dialog'] and p['mode'] == 'start' else None, 15)
        assert p['session_count'] == 0 and not self.peers() and not self.messages(), p
        assert p['automatic']['approval_key'] and 'Approval is saved' in p['popup'], p
        self.command('language-accept')
        p = wait_for(lambda: p if (p := self.probe('language'))['session_count'] == 1
                     and p['sessions'][0]['state'] == 'ready'
                     and p['sessions'][0]['documents'] else None, 10)
        assert len(self.peers()) == 1, self.peers()
        return p

    def setup(self, folder=False, settings=True, nested=False):
        self.roots = [self.fixtures / 'root']
        self.source = self.write(self.roots[0] / 'main.zig', 'const answer = 42;\n')
        self.write(self.roots[0] / 'nested/other.zig', 'const other = 1;\n')
        if settings:
            self.folder_settings(0, {})
        self.spec = {'version': 1, 'roots': [{'path': 'root'}], 'settings': {}}
        self.manifest = self.write(self.fixtures / 'test.coral-workspace', json.dumps(self.spec))
        self.open_workspace(self.roots[0] if folder else self.manifest, folder=folder)
        if nested:
            self.source = self.roots[0] / 'nested/other.zig'
            self.command('browser-browse-relative', 'nested')
            self.browser()
        self.open_document(self.source)
        p = self.browser()
        assert not p['watch_fallback'], p
        self.approve()
        self.gate()
        return self.start_server()

    def stopped(self, before, mutation, resumes=False):
        request = self.probe()['request']
        peers = self.peers()
        self.command('explorer-watch-delay', 1500)
        mutation()
        wait_for(lambda: self.probe('language')['session_count'] == 0, 5)
        p = self.probe()
        # Policy generation is local to its scope and resets on modelChanged;
        # request is the monotonic owner generation across model replacements.
        assert p['request'] > request and p['gate_cancelled'], p
        assert not p['gate_valid'], p
        browser = self.probe('browser')
        assert p['pending'] or browser['loading'] or not browser['watch_ready'], (p, browser)
        wait_for(lambda: not (self.peers() & peers), 5)
        self.browser()
        self.settled()
        # A successful unchanged-policy recheck can admit a NEW automatic
        # session. It must never revive the retired permit, session or process.
        if resumes:
            self.trusted()
            live = wait_for(lambda: p if (p := self.probe('language'))['session_count'] == 1
                            and p['sessions'][0]['state'] == 'ready' and p['sessions'][0]['documents'] else None, 15)
            assert live['sessions'][0]['id'] != before['sessions'][0]['id'] and not live['dialog'], live
            assert self.peers() and not (self.peers() & peers)
        else:
            self.restricted()
        until = time.monotonic() + 2.5
        while time.monotonic() < until:
            live = self.probe('language')
            assert live['session_count'] == int(resumes) and not live['dialog'], live
            assert all(s['id'] != before['sessions'][0]['id'] for s in live['sessions']), live
            assert not (self.peers() & peers)
            assert not self.probe()['gate_valid'], 'old capability gate revived'
            time.sleep(.15)
        assert sum(m.get('method') == 'initialize' for m in self.messages()) == (2 if resumes else 1)
        self.evidence.setdefault('lifecycle', []).append({
            'case': self.name, 'retired_session': before['sessions'][0]['id'],
            'gate_cancelled': True, 'automatic_new_session': resumes,
        })


def saves(h, folder, nested=False):
    before = h.setup(folder=folder, settings=not folder, nested=nested)
    peer = h.peers()
    permit = h.probe()
    session = before['sessions'][0]['id']
    for number in range(3):
        h.command('select', start=0, end=0)
        h.command('insert', f'// save {number} é😀\n')
        h.command('save')
        document = wait_for(lambda: d if not (d := h.document(h.source))['dirty'] else None)
        h.expected[h.source] = hashlib.sha256(h.source.read_bytes()).hexdigest()
        wait_for(lambda: len([m for m in h.messages() if m.get('method') == 'textDocument/didSave']) == number + 1)
        h.browser()  # Wait beyond event delivery, page scans and debounce.
        p = h.trusted()
        assert p['gate_valid'] and not p['gate_cancelled'], p
        assert p['policy_generation'] == permit['policy_generation'], (permit, p)
        assert h.peers() == peer
        live = h.probe('language')
        assert live['session_count'] == 1 and live['sessions'][0]['id'] == session, live
        messages = h.messages()
        saved = [m for m in messages if m.get('method') == 'textDocument/didSave'][-1]
        assert saved['params']['text'] == document['text'] == h.source.read_text(), saved
        assert any(m.get('method') == 'textDocument/didChange' for m in messages), messages
        assert not any(m.get('method') in ('shutdown', 'exit') for m in messages), messages
    # Atomic sibling replacement and deletion also alter root ctime, not identity.
    sibling = h.roots[0] / 'sibling.zig'
    temp = h.roots[0] / '.save-temp'
    temp.write_text('const sibling = 1;\n')
    os.replace(temp, sibling)
    sibling.unlink()
    h.browser()
    assert h.probe()['policy_generation'] == permit['policy_generation']
    assert h.probe()['gate_valid'] and h.peers() == peer
    assert sum(m.get('method') == 'initialize' for m in h.messages()) == 1
    h.evidence.setdefault('lifecycle', []).append({'case': h.name, 'saves': 3,
        'same_process_and_permit': True, 'didSave_text_matches_disk': True})


def policy_replacement(h, kind):
    before = h.setup(folder=kind in ('settings', 'settings-create', 'settings-atomic'),
                     settings=kind != 'settings-create', nested=kind == 'nested-gitignore')

    def mutate():
        if kind == 'root':
            root = h.roots[0]
            old = root.with_name('old-root')
            root.rename(old)
            for path in list(h.expected):
                if path.is_relative_to(root):
                    h.expected[old / path.relative_to(root)] = h.expected.pop(path)
            root.mkdir()
            h.write(h.source, 'const replacement = 1;\n')
        elif kind in ('manifest', 'manifest-same'):
            temporary = h.manifest.with_suffix('.replacement')
            temporary.write_text(json.dumps(dict(h.spec, settings={'indent': 3}))
                                 if kind == 'manifest' else h.manifest.read_text())
            os.replace(temporary, h.manifest)
            h.expected[h.manifest] = hashlib.sha256(h.manifest.read_bytes()).hexdigest()
        elif kind in ('settings', 'settings-create'):
            h.folder_settings(0, {'indent': 3})
        elif kind == 'settings-atomic':
            settings = h.roots[0] / '.coral/settings.json'
            temporary = settings.with_suffix('.replacement')
            temporary.write_bytes(settings.read_bytes())
            os.replace(temporary, settings)
        elif kind in ('gitignore', 'nested-gitignore'):
            h.write(h.source.parent / '.gitignore', '*.generated.zig\n')
        elif kind == 'overflow':
            h.command('explorer-overflow')
        elif kind == 'security':
            h.roots[0].chmod(0o700)
        elif kind == 'switch':
            other = h.fixtures / 'other-root'
            other.mkdir()
            h.command('open-folder', other)
        else:
            # Keep recheck in flight long enough to check synchronous retirement.
            h.command('policy-delay', 1200)
            h.command('policy-' + kind)

    h.stopped(before, mutate, resumes=kind in ('manifest-same', 'settings-atomic', 'gitignore',
                                              'nested-gitignore', 'security', 'overflow', 'recheck'))


def root_chain(h, ancestry=False, during_load=False):
    h.roots = [h.fixtures / 'root0', h.fixtures / 'root1']
    for root in h.roots:
        h.write(root / 'main.zig', 'const answer = 42;\n')
    alias = h.fixtures / 'alias'
    parent = h.fixtures / 'resolver' if ancestry else h.fixtures
    parent.mkdir(exist_ok=True)
    middle = parent / 'middle'
    middle.symlink_to(h.roots[0])
    alias.symlink_to(middle.relative_to(h.fixtures))
    h.spec = {'version': 1, 'roots': [{'path': 'alias'}], 'settings': {}}
    h.manifest = h.write(h.fixtures / 'test.coral-workspace', json.dumps(h.spec))
    if during_load:
        h.command('explorer-watch-delay', 1500)
        h.command('open-workspace', h.manifest)
        wait_for(lambda: (p := h.probe('browser'))['loading'] and p['watch_worker_busy'])
        middle.unlink()
        middle.symlink_to(h.roots[1])
        p = h.browser()
        assert p['roots'][0]['canonical'] == str(h.roots[1]), p
        assert p['policy_watch_ready'] and not p['watch_fallback'], p
        h.restricted()
        initial = h.roots[1]
    else:
        h.open_workspace(h.manifest)
        initial = h.roots[0]
    h.source = initial / 'main.zig'
    h.open_document(h.source)
    h.approve()
    h.gate()
    before = h.start_server()
    assert before['sessions'][0]['path'] == str(initial), before
    # Saving through an aliased root must not invalidate its ancestry watches.
    permit, peers = h.probe(), h.peers()
    h.command('insert', '// aliased root save\n')
    h.command('save')
    wait_for(lambda: not h.document(h.source)['dirty'])
    h.expected[h.source] = hashlib.sha256(h.source.read_bytes()).hexdigest()
    wait_for(lambda: any(m.get('method') == 'textDocument/didSave' for m in h.messages()))
    h.browser()
    assert h.probe()['request'] == permit['request'] and h.probe()['gate_valid']
    assert h.peers() == peers
    replacement = h.roots[0] if during_load else h.roots[1]
    alias_inode = alias.lstat().st_ino

    def retarget():
        if ancestry:
            parent.rename(parent.with_name('old-resolver'))
            parent.mkdir()
            middle.symlink_to(replacement)
        else:
            temporary = middle.with_name('replacement-link')
            temporary.symlink_to(replacement)
            os.replace(temporary, middle)
        assert alias.lstat().st_ino == alias_inode
        assert alias.resolve() == replacement

    h.stopped(before, retarget)
    p = h.restricted()
    assert p['approval_required'], p
    assert h.probe('browser')['roots'][0]['canonical'] == str(replacement)


def root_chain_cap(h):
    root = h.fixtures / 'root'
    h.roots = [root]
    source = h.write(root / 'main.zig', 'const answer = 42;\n')
    # Below Linux's 40-link traversal limit but above the 128 subscription cap:
    # each intermediate target adds distinct runtime ancestry outside the root.
    target = root
    for number in range(35):
        middle = h.fixtures / 'routes' / str(number) / 'a/b/middle'
        middle.parent.mkdir(parents=True)
        middle.symlink_to(target)
        target = middle
    alias = h.fixtures / 'alias'
    alias.symlink_to(target)
    assert alias.resolve() == root
    manifest = h.write(h.fixtures / 'test.coral-workspace', json.dumps({
        'version': 1, 'roots': [{'path': 'alias'}], 'settings': {},
    }))
    h.open_workspace(manifest)
    h.open_document(source)
    p = h.restricted()
    browser = h.probe('browser')
    assert browser['watch_fallback'] and not browser['policy_watch_ready'], browser
    assert p['status'] == 'failed' and 'WorkspaceMonitoringUnavailable' in p['store_error'], p
    h.command('policy-trust-confirm')
    assert not h.probe()['confirmation'] and not h.probe()['dialog']
    h.command('policy-recheck')
    h.restricted()
    h.command('language-start')
    assert h.probe('language')['session_count'] == 0 and not h.peers()


if __name__ == '__main__':
    selection = argparse.ArgumentParser(add_help=False)
    selection.add_argument('--case', action='append', help='run only the named lifecycle case (repeatable)')
    selected, remaining = selection.parse_known_args()
    sys.argv[1:] = remaining
    save_evidence = policy.save

    def save(output, evidence):
        evidence['measurement_note'] = ('Native workspace/LSP lifecycle with explicitly trusted fake server; '
                                        'session identity, process start time and wire didSave checked.')
        save_evidence(output, evidence)

    policy.save = save
    policy.PolicyHarness = LifecycleHarness
    policy.SCENARIOS = [('save_manifest', lambda h: saves(h, False)),
                        ('save_folder_without_settings', lambda h: saves(h, True)),
                        ('save_watched_nested_source', lambda h: saves(h, False, True))]
    policy.SCENARIOS += [(kind + '_retires_permit', lambda h, kind=kind: policy_replacement(h, kind))
                        for kind in ('root', 'manifest', 'manifest-same', 'settings',
                                     'settings-create', 'settings-atomic', 'gitignore',
                                     'nested-gitignore', 'security', 'overflow', 'recheck',
                                     'revoke', 'switch')]
    policy.SCENARIOS += [('root_chain_retarget', root_chain),
                         ('root_chain_runtime_ancestor', lambda h: root_chain(h, ancestry=True)),
                         ('root_chain_load_barrier', lambda h: root_chain(h, during_load=True)),
                         ('root_chain_cap_fails_closed', root_chain_cap)]
    if selected.case:
        unknown = set(selected.case) - {name for name, _ in policy.SCENARIOS}
        if unknown:
            raise SystemExit('Unknown lifecycle cases: ' + ', '.join(sorted(unknown)))
        policy.SCENARIOS = [(name, run) for name, run in policy.SCENARIOS if name in selected.case]
    if '--output' not in sys.argv:
        sys.argv += ['--output', str(policy.PEARL / '.cache/coral-workspace-lifecycle')]
    sys.exit(policy.main())
