#!/usr/bin/env python3
"""M6/M7 native agent-panel acceptance, in a private Wayland/D-Bus/HOME/XDG.

  python3 -B tests/agent.py --binary /path/to/coral-test --case fake-thread-send-stream

Every fixture workspace, skill file and thread store lives under the disposable
session tree; no host file is read or written and no host repository is touched.
The controller is driven through its documented fixture bridge, which exercises
the *actual* widgets and public entry points (src/agent/controller.zig). The
fake provider is deterministic and offline; its default script streams no tool
calls, so permission/review fixtures are asserted to be inert without a pending
request (they never grant trust or bypass a gate), and mid-stream cancellation,
scripted tool permissions and review apply/reject are covered by the GTK-free
agent-core-unit / agent-protocol-unit suites instead.

Known controller boundaries asserted as observed (backend files are not edited):
  * The provider picker's ACP selection carries an empty argv, so an ACP send
    fails cleanly (state=failed) instead of spawning the disposable adapters;
    real adapter parity lives in agent-protocol-unit.
  * Engine.restore() rehydrates backend slots from the thread store, but the
    controller does not rebuild UI thread rows, so a restarted panel probes
    count=0 while the durable store file survives.

Integration gate: the binary must contain the CORAL_AGENT probe marker. A stale
binary that predates the parent's controller/command wiring is refused up front
rather than producing misleading per-case failures.

Fixture/probe API (src/agent/controller.zig):
  actions: agent-probe agent-show agent-new-thread agent-send agent-cancel
           agent-allow agent-deny agent-accept-review agent-reject-review
           agent-select-thread agent-set-provider agent-close
  probe:   CORAL_AGENT {ok,count,limit,transcript_limit,attachment_limit,active,
           busy,closed,visible,provider,last_error,host{root,read,write,spawn,
           kill,search,diff},threads[{id,title,provider,state,transcript_bytes,
           messages,attachments,permission,review}],skills{query,matches},
           providers[{name,ok,detail}]}
"""
import argparse
import json
import signal
import sys
import time
import traceback
from pathlib import Path

from search import PEARL
from policy import BudgetExpired, save
from windows import WindowHarness, stage_styles
from pearl_session import PrivateSession, fixture_prefix, wait_for

MARKER = 'CORAL_AGENT'
REQUIRED_MARKERS = (b'CORAL_AGENT ', b'CORAL_COMMAND_DONE')
TRANSCRIPT_LIMIT = 1024 * 1024
THREAD_LIMIT = 64


class AgentHarness(WindowHarness):
    isolated_app_cwd = True

    def probe(self, kind='policy'):
        # WindowHarness defaults probes to 'workspace', but the inherited
        # PolicyHarness trust helpers require the policy probe. Restore that
        # default while keeping WindowHarness's target routing.
        return super().probe(kind)

    def fixture(self, settings=None):
        super().fixture(settings)
        root = self.roots[0]
        self.agent_root = root
        self.write(root / 'notes.txt', 'agent fixture workspace\n')
        # Real skill markdown loaded by Engine.newThread from <root>/.coral/skills.
        self.write(root / '.coral' / 'skills' / 'zig-style.md',
                   '---\nname: zig-style\ndescription: Zig formatting conventions\n---\n'
                   'Use const where possible.\n')
        self.write(root / '.coral' / 'skills' / 'git-commit.md',
                   '---\nname: git-commit\ndescription: Commit message help\n---\n'
                   'Write imperative commit messages.\n')
        self.write(root / '.coral' / 'skills' / 'python-tips.md',
                   '---\nname: python-tips\ndescription: Testing hints\n---\n'
                   'Prefer pytest fixtures.\n')
        return self.manifest

    # --- agent probe / fixture helpers ---------------------------------------

    def ap(self):
        lines, _ = self.command('agent-probe')
        prefix = MARKER + ' '
        value = next((json.loads(line[len(prefix):]) for line in lines if line.startswith(prefix)), None)
        assert value is not None, ('CORAL_AGENT probe absent — controller not wired', lines[-6:])
        self.last[MARKER] = value
        return value

    def wait_agent(self, predicate, timeout=18):
        def ready():
            value = self.ap()
            return value if predicate(value) else None
        try:
            return wait_for(ready, timeout)
        except TimeoutError as exc:
            raise AssertionError(('Agent deadline', self.last.get(MARKER))) from exc

    def idle_agent(self, timeout=18):
        return self.wait_agent(lambda p: not p['busy'], timeout)

    def new_thread(self, title):
        self.command('agent-new-thread', title)
        p = self.wait_agent(lambda q: q['count'] > 0 and q['active'] is not None)
        return next(t for t in p['threads'] if t['id'] == p['active'])

    def send(self, text):
        self.command('agent-send', text)

    def send_done(self, text, messages, timeout=18):
        self.send(text)
        return self.wait_agent(lambda p: not p['busy'] and p['threads'] and
                               next(t for t in p['threads'] if t['id'] == p['active'])['messages'] >= messages
                               and next(t for t in p['threads'] if t['id'] == p['active'])['state'] == 'idle',
                               timeout)

    def focus_agent(self):
        self.command('focus-agent')
        try:
            return wait_for(lambda: p if (p := self.probe('dock'))['focus'] == 'agent' else None, 4)
        except TimeoutError:
            # The first show may race the slot's initial map; a second real
            # focus action after allocation is the user-visible retry.
            self.command('focus-agent')
            return wait_for(lambda: p if (p := self.probe('dock'))['focus'] == 'agent' else None, 6)

    def setup(self, trust=True):
        self.fixture()
        self.open_workspace(self.manifest)
        if trust:
            self.approve()
        return self.ap()

    def store_dir(self):
        return Path(self.session.env['XDG_STATE_HOME']) / 'coral' / 'agents'


# --- scenarios ---------------------------------------------------------------

def panel_probe_show_hide(h):
    p = h.setup()
    assert p['ok'] and not p['closed'] and not p['busy'], p
    assert p['count'] == 0 and p['limit'] == THREAD_LIMIT and p['active'] is None, p
    assert p['transcript_limit'] == TRANSCRIPT_LIMIT and p['attachment_limit'] == 128, p
    assert p['provider'] == 'fake' and p['last_error'] is None and p['threads'] == [], p
    assert p['skills'] == {'query': '', 'matches': 0}, p
    # The host root snapshot binds at attach/invalidate; opening the first
    # workspace does not invalidate, so it is still unset here. Counters prove
    # no host I/O has run.
    assert all(p['host'][key] == 0 for key in ('read', 'write', 'spawn', 'kill', 'search', 'diff')), p
    providers = {entry['name']: entry for entry in p['providers']}
    assert providers['fake']['ok'], providers
    assert not providers['openai']['ok'] and providers['openai']['detail'] == 'missing base_url', providers
    # ACP is served by the dedicated ACP worker, not the provider registry.
    assert not providers['acp']['ok'] and providers['acp']['detail'] == 'unknown provider', providers
    # Default dock intent: a hidden right panel; the other four are unchanged.
    dock = h.probe('dock')
    assert dock['desired']['agent'] == 'right' and not dock['desired']['agent_visible'], dock
    assert not dock['agent_visible'] and not dock['right_visible'], dock
    assert dock['desired']['explorer'] == 'left' and dock['desired']['terminal'] == 'bottom', dock
    h.command('agent-show')
    assert h.ap()['visible'], h.ap()
    dock = h.focus_agent()
    assert dock['agent_visible'] and dock['right_visible'] and dock['desired']['agent_visible'], dock
    h.snapshot('agent-panel-focused')
    h.command('toggle-agent')
    dock = h.probe('dock')
    assert not dock['agent_visible'] and dock['focus'] == 'editor', dock
    assert not h.ap()['visible'], h.ap()
    h.command('toggle-agent')
    assert h.probe('dock')['agent_visible'] and h.ap()['visible']
    h.command('hide-panel')
    dock = h.probe('dock')
    assert not dock['agent_visible'] and dock['focus'] == 'editor', dock
    # The controller's close button hides its own root; the dock slot intent
    # survives until the dock action hides it (observed controller semantics).
    h.focus_agent()
    h.command('agent-close')
    assert not h.ap()['visible'], h.ap()
    assert h.probe('dock')['agent_visible']
    h.command('agent-show')
    assert h.ap()['visible']


def fake_thread_send_stream(h):
    h.setup()
    thread = h.new_thread('Stream fixture')
    assert thread['title'] == 'Stream fixture' and thread['provider'] == 'fake', thread
    assert thread['state'] == 'idle' and thread['messages'] == 0 and thread['attachments'] == 0, thread
    p = h.send_done('hello agent', 1)
    t = next(t for t in p['threads'] if t['id'] == thread['id'])
    assert t['messages'] == 1 and t['state'] == 'idle' and not p['busy'], t
    assert t['transcript_bytes'] > 0 and t['permission'] is None and t['review'] is None, t
    # The empty deterministic script performs no host I/O.
    assert all(p['host'][key] == 0 for key in ('read', 'write', 'spawn', 'kill', 'search', 'diff')), p
    assert p['last_error'] is None, p
    p = h.send_done('second turn', 2)
    t = next(t for t in p['threads'] if t['id'] == thread['id'])
    assert t['messages'] == 2 and t['transcript_bytes'] > 0, t
    h.snapshot('fake-thread-streamed')


def permission_review_inert(h):
    h.setup()
    thread = h.new_thread('Gate fixture')
    h.send_done('no tools here', 1)
    before = h.ap()
    # No pending permission or review exists: every decision fixture must be a
    # no-op. Fixtures never fabricate consent, apply edits or spawn processes.
    for action in ('agent-allow', 'agent-deny', 'agent-accept-review', 'agent-reject-review'):
        h.command(action)
    after = h.ap()
    t = next(t for t in after['threads'] if t['id'] == thread['id'])
    assert t['state'] == 'idle' and t['permission'] is None and t['review'] is None, t
    assert t['messages'] == 1 and not after['busy'], t
    assert after['last_error'] is None, after
    assert all(after['host'][key] == 0 for key in ('read', 'write', 'spawn', 'kill', 'search', 'diff')), after
    assert after['count'] == before['count'] == 1, (before, after)
    h.snapshot('permission-review-fixtures-inert')


def cancel_and_resend(h):
    h.setup()
    # Cancel without any thread is safe.
    h.command('agent-cancel')
    assert h.ap()['count'] == 0 and h.ap()['last_error'] is None
    thread = h.new_thread('Cancel fixture')
    h.send_done('first turn', 1)
    # The deterministic script completes before the next main-loop turn, so the
    # thread is idle; cancelling an idle thread must not poison it. Mid-stream
    # cancellation is asserted by agent-core-unit's wait_cancel script.
    h.command('agent-cancel')
    p = h.ap()
    t = next(t for t in p['threads'] if t['id'] == thread['id'])
    assert t['state'] == 'idle' and not p['busy'], t
    p = h.send_done('after cancel', 2)
    t = next(t for t in p['threads'] if t['id'] == thread['id'])
    assert t['messages'] == 2 and t['state'] == 'idle', t
    assert p['last_error'] is None, p
    h.snapshot('cancel-idle-and-resend')


def provider_picker(h):
    h.setup()
    thread = h.new_thread('Picker fixture')
    for name in ('openai', 'acp', 'fake'):
        h.command('agent-set-provider', name)
        p = h.ap()
        assert p['provider'] == name, p
        assert next(t for t in p['threads'] if t['id'] == thread['id'])['provider'] == name, p
    # A new thread inherits the picker selection.
    h.command('agent-set-provider', 'openai')
    second = h.new_thread('OpenAI thread')
    assert second['provider'] == 'openai', second
    h.command('agent-set-provider', 'fake')
    h.send_done('fake again', 1)
    # The picker's ACP selection carries an empty argv (controller boundary):
    # the send must fail cleanly without spawning anything, then recover.
    h.command('agent-select-thread', thread['id'])
    h.command('agent-set-provider', 'acp')
    h.send('acp attempt')
    p = h.wait_agent(lambda q: next(t for t in q['threads'] if t['id'] == thread['id'])['state'] == 'failed')
    assert p['host']['spawn'] == 0 and not p['busy'], p
    h.command('agent-set-provider', 'fake')
    p = h.send_done('recovered', 1)
    t = next(t for t in p['threads'] if t['id'] == thread['id'])
    assert t['state'] == 'idle' and t['provider'] == 'fake', t
    h.snapshot('provider-picker-and-clean-acp-failure')


def skills_search(h):
    h.setup()
    h.new_thread('Skills fixture')
    # Drive the real skills entry through the app fixture bridge; its "changed"
    # signal runs the controller's actual updateSkills/searchSkills workflow.
    h.command('agent-skills-query', 'zig')
    p = h.wait_agent(lambda q: q['skills']['query'] == 'zig')
    assert p['skills']['matches'] == 1, p
    h.command('agent-skills-query', 'commit')
    p = h.wait_agent(lambda q: q['skills']['query'] == 'commit')
    assert p['skills']['matches'] == 1, p
    h.command('agent-skills-query', 'zzz-no-such-skill')
    p = h.wait_agent(lambda q: q['skills']['query'] == 'zzz-no-such-skill')
    assert p['skills']['matches'] == 0, p
    # Skills search never disturbs the conversation.
    p = h.send_done('skills then send', 1)
    assert p['threads'][0]['messages'] == 1 and p['last_error'] is None, p
    h.snapshot('skills-search')


def select_thread(h):
    h.setup()
    alpha = h.new_thread('Alpha')
    beta = h.new_thread('Beta')
    p = h.ap()
    assert p['count'] == 2 and p['active'] == beta['id'], p
    h.command('agent-select-thread', '0')
    assert h.ap()['active'] == alpha['id']
    h.command('agent-select-thread', '1')
    assert h.ap()['active'] == beta['id']
    h.command('agent-select-thread', alpha['id'])
    assert h.ap()['active'] == alpha['id']
    h.command('agent-select-thread', '1')
    h.send_done('targeted send', 1)
    p = h.ap()
    by_id = {t['id']: t for t in p['threads']}
    assert by_id[beta['id']]['messages'] == 1 and by_id[alpha['id']]['messages'] == 0, p
    h.snapshot('thread-selection')


def thread_persistence(h):
    h.setup()
    thread = h.new_thread('Persist me')
    h.send_done('remember this token', 1)
    path = h.store_dir() / (thread['id'] + '.json')
    assert path.is_file(), sorted(q.name for q in h.store_dir().iterdir())
    saved = json.loads(path.read_text())
    assert saved['id'] == thread['id'] and saved['title'] == 'Persist me', saved
    assert saved['provider'] == 'fake', saved
    assert any(m['role'] == 'user' and m['content'] == 'remember this token' for m in saved['messages']), saved
    raw = path.read_bytes()
    h.stop()
    h.launch()
    p = h.ap()
    assert p['ok'] and not p['closed'], p
    # Engine.restore() rehydrates backend slots, but the controller does not
    # rebuild UI rows (backend boundary; engine-level restore is asserted by
    # agent-core-unit). The durable store survives the restart untouched.
    assert p['count'] == 0 and p['threads'] == [], p
    assert path.read_bytes() == raw
    again = h.new_thread('After restart')
    assert again['id'] != thread['id']
    h.send_done('still working', 1)
    h.snapshot('thread-store-survives-restart')


def bounds(h):
    h.setup()
    for i in range(THREAD_LIMIT):
        h.command('agent-new-thread', 'T%d' % i)
    p = h.ap()
    assert p['count'] == THREAD_LIMIT and len(p['threads']) == THREAD_LIMIT, p
    h.command('agent-new-thread', 'One too many')
    p = h.ap()
    assert p['count'] == THREAD_LIMIT and p['last_error'] == 'ThreadLimit', p
    # A transcript larger than the 1 MiB bound is trimmed oldest-first. Use
    # newline-separated lines: a single unbroken 1 MiB line would make Pango
    # layout block the main loop rather than exercise the trim bound.
    h.command('agent-select-thread', '0')
    line = 'a' * 200 + '\n'
    payload = line * ((TRANSCRIPT_LIMIT // len(line)) + 40)
    p = h.send_done(payload, 1, timeout=30)
    t = p['threads'][0]
    assert t['transcript_bytes'] == TRANSCRIPT_LIMIT, t
    assert p['attachment_limit'] == 128 and not p['busy'], p
    h.snapshot('thread-and-transcript-bounds')


SCENARIOS = [
    ('panel-probe-show-hide', panel_probe_show_hide),
    ('fake-thread-send-stream', fake_thread_send_stream),
    ('permission-review-inert', permission_review_inert),
    ('cancel-and-resend', cancel_and_resend),
    ('provider-picker', provider_picker),
    ('skills-search', skills_search),
    ('select-thread', select_thread),
    ('thread-persistence', thread_persistence),
    ('bounds', bounds),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-agent')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    parser.add_argument('--case', action='append', default=None,
                        help='Exact case name or prefix group; repeatable. Subsets are reported as partial.')
    args = parser.parse_args()
    binary = args.binary.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    blob = binary.read_bytes()
    missing = [marker.decode() for marker in REQUIRED_MARKERS if marker not in blob]
    if missing:
        print('REFUSED: binary lacks M6/M7 agent probe marker(s) %s — the parent has not wired '
              'src/agent/controller.zig into this build.' % missing, file=sys.stderr, flush=True)
        sys.exit(2)

    selected = SCENARIOS
    if args.case:
        selected = [(name, fn) for name, fn in SCENARIOS
                    if any(name == want or name.startswith(want) for want in args.case)]
        if not selected:
            print('No cases match --case %s' % args.case, file=sys.stderr)
            sys.exit(2)

    began = time.monotonic()
    evidence = {'status': 'running', 'checks': [], 'runtime_budget_seconds': 400,
                'partial': len(selected) != len(SCENARIOS),
                'measurement_note': 'Native GTK probe assertions; Wayland key-to-handler acknowledgement, not frame latency.',
                'isolation': 'Private headless compositor, D-Bus, HOME and XDG; disposable per-case fixtures; no host writes.'}

    def expired(_signal, _frame):
        raise BudgetExpired('Agent acceptance exceeded the 400-second whole-suite budget')

    previous = signal.signal(signal.SIGALRM, expired)
    signal.alarm(400)
    save(output, evidence)
    try:
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
            stage_styles(session, evidence)
            for name, scenario in selected:
                record = {'name': name, 'status': 'running'}
                evidence['checks'].append(record)
                save(output, evidence)
                start, h = time.monotonic(), None
                child_start = len(session.children)
                print('RUN', name, flush=True)
                try:
                    h = AgentHarness(session, binary, output, evidence, name, began + 395)
                    scenario(h)
                    h.stop()
                    h.verify_files()
                    record.update(status='passed', fixture_hashes_verified=len(h.expected),
                                  executable_sentinels_absent=len(h.sentinels))
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
        for name, _ in selected:
            if name not in completed:
                evidence['checks'].append({'name': name, 'status': 'blocked', 'reason': 'Suite setup or runtime budget failed'})
        for record in evidence['checks']:
            if record['status'] == 'running':
                record.update(status='failed', error='Interrupted; see suite fatal error')
        evidence['seconds'] = time.monotonic() - began
        save(output, evidence)
    passed = sum(c['status'] == 'passed' for c in evidence['checks'])
    label = 'PARTIAL' if evidence['partial'] else evidence['status'].upper()
    print(f"{label}: {passed}/{len(selected)} native agent cases; {output / 'results.json'}", flush=True)
    sys.exit(0 if evidence['status'] == 'passed' else 1)


if __name__ == '__main__':
    main()
