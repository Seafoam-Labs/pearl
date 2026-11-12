#!/usr/bin/env python3
"""Native M5 terminal acceptance (libghostty-vt), never the spike or VTE.

Run via the parent-wired coral-test binary (build with -Dtest-hooks=true and
-Dghostty-prefix=<prefix>; runtime needs LD_LIBRARY_PATH=<prefix>/lib). The
parent wires app/commands: terminal-probe -> Controller.probe(), the
terminal-* fixtures -> Controller.fixture(), and focus-terminal shows the dock
panel. All input goes to a private headless Wayland session; HOME/XDG state and
workspace fixtures are disposable.

The workspace is ALWAYS trusted (the consent boundary was removed), so a user
action spawns a terminal directly with no disclosure prompt; the capability
permit is still re-validated at the spawn boundary. Terminal output has no
action authority: titles/links/OSC never dispatch workbench actions, and OSC
clipboard is denied. The terminal follows the application editor font, renders
incrementally by dirty row, supports rectangular/block selection, and enables
bounded inline-only Kitty graphics.

Evidence (including partial failures, probes and screenshots) goes to
.cache/coral-terminal. A 400-second whole-suite alarm leaves cleanup headroom.
"""
import argparse
import base64
import json
import signal
import sys
import time
import traceback
from pathlib import Path

from search import PEARL, Harness
from policy import BudgetExpired, PolicyHarness, save
from pearl_session import PrivateSession, fixture_prefix, wait_for

SENTINEL = 'CORAL-TERMINAL-CLIPBOARD-SENTINEL'


class TerminalHarness(PolicyHarness):
    # The workspace is always trusted, so the policy-suite invariants (restricted
    # mode, consent, permit gating while pending) no longer apply. Read probes
    # without those assertions; terminal acceptance only asserts terminal state.
    def probe(self, kind='policy'):
        return Harness.probe(self, kind)

    def setup(self):
        self.command('window-resize', width=1200, height=800)
        root = self.fixtures / 'root'
        self.write(root / 'readme.txt', 'terminal workspace fixture\n')
        self.root = root
        self.open_workspace(root, folder=True)
        # No approval/disclosure step: the workspace is always trusted.
        return self.terminal('setup')

    def terminal(self, label=None):
        p = self.probe('terminal')
        if label:
            self.evidence.setdefault('terminal', []).append({'case': self.name, 'label': label, 'probe': p})
        return p

    def term(self, action, value=None, **fields):
        return self.command(action, value, **fields)

    def wait_session(self, predicate, timeout=10):
        return wait_for(lambda: p if (p := self.terminal()) and predicate(p) else None, timeout)

    def active(self, p=None):
        p = p or self.terminal()
        if not p['sessions']:
            return None
        active_id = p['active']
        return next((s for s in p['sessions'] if s['id'] == active_id), p['sessions'][0])

    def show(self):
        self.command('focus-terminal')
        # Give the bottom dock a usable height so the grid is more than a couple
        # of rows; the surface derives cols/rows from its real allocation.
        self.command('dock-resize', 'bottom', size=420)

    def open_terminal(self):
        """Trust is implicit; a user action spawns directly, then show the dock."""
        self.term('terminal-new')
        self.show()
        return self.wait_session(lambda p: p['count'] >= 1 and self.active(p)['phase'] == 'running')

    def clipboard(self):
        return self.session.run(['wl-paste', '--no-newline'], check=False).stdout


def wait_text(h, needle, timeout=10):
    def ready():
        s = h.active()
        return s if s and needle in s['text'] else None
    return wait_for(ready, timeout)


# ---- Scenarios ----

def trust_direct(h):
    h.setup()
    p = h.terminal('trusted-setup')
    assert p['trust'] == 'trusted', p
    # A user action spawns directly: no disclosure prompt and no accept step.
    h.term('terminal-new')
    h.show()
    p = h.wait_session(lambda p: p['count'] == 1 and h.active(p)['phase'] == 'running')
    assert p['spawned'] == 1, p
    assert p['last_error'] is None, p
    # Restart re-validates the trust permit at the spawn boundary and spawns fresh.
    first = h.active(p)['id']
    h.term('terminal-restart')
    p = h.wait_session(lambda p: (s := h.active(p)) is not None and s['phase'] == 'running' and s['id'] != first)
    assert p['spawned'] >= 2, p
    h.screenshot('trust-direct')


def output_render(h):
    h.setup()
    h.open_terminal()
    h.term('terminal-write', 'echo CORAL_RENDER_OK\r')
    s = wait_text(h, 'CORAL_RENDER_OK')
    assert s['mapped'] and s['width'] > 0 and s['height'] > 0, s
    # Unicode and ANSI styling render through the ghostty render state.
    h.term('terminal-write', 'printf "h\\xc3\\xa9\\xce\\xbb \\xe4\\xb8\\xad\\xe6\\x96\\x87 \\xf0\\x9f\\x99\\x82\\n"\r')
    wait_text(h, '中文')
    h.term('terminal-write', 'printf "\\033[1;32mGREEN\\033[0m\\n"\r')
    s = wait_text(h, 'GREEN')
    assert s['cols'] > 0 and s['rows'] > 0, s
    h.screenshot('output-render')


def resize(h):
    h.setup()
    h.open_terminal()
    before = h.active()
    h.term('terminal-resize', '40,10')
    s = wait_for(lambda: x if (x := h.active())['cols'] == 40 and x['rows'] == 10 else None, 6)
    assert (s['cols'], s['rows']) == (40, 10), s
    # The PTY winsize must follow the grid: ask the shell to report it.
    h.term('terminal-write', 'stty size\r')
    wait_text(h, '10 40')
    # A real window allocation also drives the grid through the surface tick.
    h.command('window-resize', width=900, height=600)
    wait_for(lambda: x if (x := h.active())['cols'] != 40 or x['rows'] != 10 else None, 6)
    h.screenshot('resize')


def exit_restart(h):
    h.setup()
    h.open_terminal()
    first = h.active()['id']
    h.term('terminal-write', 'exit 7\r')
    s = wait_for(lambda: x if (x := h.active()) and x['phase'] == 'exited' else None, 8)
    assert s['exit_code'] == 7 and s['eof'], s
    p = h.terminal('exited')
    assert p['reaped'] >= 1, p
    # Restart reaps the old session and spawns a fresh running one.
    h.term('terminal-restart')
    p = h.wait_session(lambda p: p['count'] >= 1 and h.active(p)['phase'] == 'running' and h.active(p)['id'] != first)
    assert p['spawned'] >= 2, p
    h.term('terminal-write', 'echo RESTART_OK\r')
    wait_text(h, 'RESTART_OK')


def cancel_reap(h):
    h.setup()
    h.open_terminal()
    s = h.active()
    # A same-group background descendant must be reaped on cancel.
    h.term('terminal-write', 'sleep 30 & sleep 30\r')
    time.sleep(0.3)
    h.term('terminal-cancel')
    p = wait_for(lambda: x if (x := h.terminal())['reaped'] >= 1 and x['count'] == 0 else None, 10)
    assert p['count'] == 0, p
    assert p['spawned'] == p['reaped'], p
    h.screenshot('cancel-reap')


def close_sessions(h):
    h.setup()
    h.open_terminal()
    # Bounded multi-session: open several tabs, then close them all.
    for _ in range(3):
        h.term('terminal-new')
    p = wait_for(lambda: x if (x := h.terminal())['count'] == 4 else None, 10)
    assert p['count'] == 4 and p['limit'] == 8, p
    for i in range(4):
        h.term('terminal-close')
        wait_for(lambda: x if (x := h.terminal())['count'] == 3 - i else None, 10)
    p = h.terminal('all-closed')
    assert p['count'] == 0 and p['spawned'] == p['reaped'], p


def session_limit(h):
    h.setup()
    h.open_terminal()
    for _ in range(10):
        h.term('terminal-new')
    p = wait_for(lambda: x if (x := h.terminal())['count'] == 8 else None, 12)
    assert p['count'] == p['limit'] == 8, p
    assert p['last_error'] == 'SessionLimit', p


def osc_clipboard_denied(h):
    h.setup()
    h.open_terminal()
    # Seed the private clipboard through the user copy path (an input serial is
    # required for Wayland selection ownership). OSC 52 must not change it.
    h.key('Shift_L')
    h.term('terminal-focus')
    h.term('terminal-write', 'echo CORAL_CLIP_SENTINEL\r')
    wait_text(h, 'CORAL_CLIP_SENTINEL')
    h.term('terminal-select-all')
    h.term('terminal-copy')
    wait_for(lambda: 'CORAL_CLIP_SENTINEL' in h.clipboard(), 6)
    # OSC 52 write (base64 "coral-attack") and read are both denied by policy.
    h.term('terminal-write', 'printf "\\033]52;c;Y29yYWwtYXR0YWNr\\007"\r')
    h.term('terminal-write', 'printf "\\033]52;c;?\\007"\r')
    time.sleep(0.5)
    clip = h.clipboard()
    assert 'CORAL_CLIP_SENTINEL' in clip and 'coral-attack' not in clip, clip
    h.screenshot('osc-clipboard-denied')


def no_stdout_injection(h):
    h.setup()
    h.open_terminal()
    before = h.probe('workspace')
    # Title, hyperlink, desktop notification and window-resize requests carry no
    # action authority: they may update a label but never dispatch workbench actions.
    h.term('terminal-write', 'printf "\\033]2;Injected Title\\007"\r')
    h.term('terminal-write', 'printf "\\033]8;;https://example.invalid\\007link\\033]8;;\\007\\n"\r')
    h.term('terminal-write', 'printf "\\033]9;desktop notification\\007"\r')
    h.term('terminal-write', 'printf "\\033[8;20;80t"\r')
    s = wait_text(h, 'link')
    assert s['title'] == 'Injected Title', s
    after = h.probe('workspace')
    assert after['documents'] == before['documents'], (before, after)
    # The program's window-resize request is ignored; allocation owns the grid.
    p = h.terminal('injection-probe')
    assert p['count'] == 1 and h.active(p)['phase'] == 'running', p
    h.screenshot('no-stdout-injection')


def editor_font(h):
    h.setup()
    h.open_terminal()
    s = h.active()
    settings = h.probe('workspace')['settings']
    # The terminal follows the application editor font family and size.
    assert s['font_family'] == 'monospace', s
    assert s['font_size'] == settings['font'], (s, settings)
    base_cell = s['cell_height']
    assert base_cell > 0 and s['cell_width'] > 0, s
    # Enlarge the editor font; the reaper pushes it and cell metrics recompute.
    h.command('settings', theme=settings['theme'], font=24)
    p = h.wait_session(lambda p: (x := h.active(p)) is not None and x['font_size'] == 24)
    s = h.active(p)
    assert s['cell_height'] > base_cell, (base_cell, s)
    h.screenshot('editor-font-24')
    # Shrink it again; metrics follow back down (no fixed Monospace 11).
    h.command('settings', theme=settings['theme'], font=10)
    p = h.wait_session(lambda p: (x := h.active(p)) is not None and x['font_size'] == 10)
    s = h.active(p)
    assert s['cell_height'] < base_cell, (base_cell, s)
    h.screenshot('editor-font-10')


def block_selection(h):
    h.setup()
    h.open_terminal()
    # Lay down a deterministic grid of identical rows.
    h.term('terminal-write', 'printf "0123456789\\n0123456789\\n0123456789\\n"\r')
    s = wait_text(h, '0123456789')
    lines = s['text'].split('\n')
    rows = [i for i, ln in enumerate(lines) if ln.strip() == '0123456789']
    assert len(rows) >= 3 and rows[1] == rows[0] + 1 and rows[2] == rows[0] + 2, (rows, s['text'])
    r0 = rows[0]
    # An input serial is required for Wayland clipboard ownership.
    h.key('Shift_L')
    h.term('terminal-focus')
    # Select columns 2..5 across the three marker rows -> a "2345" block.
    h.term('terminal-select-block', f'2,{r0},5,{r0 + 2}')
    h.term('terminal-copy')
    clip = wait_for(lambda: t if '2345' in (t := h.clipboard()) else None, 6)
    block_lines = [ln for ln in clip.split('\n') if ln != '']
    assert block_lines == ['2345', '2345', '2345'], (clip, block_lines)
    h.screenshot('block-selection')
    # Linear select-all still copies the full row text (contrast with the block).
    h.term('terminal-select-all')
    h.term('terminal-copy')
    full = wait_for(lambda: t if '6789' in (t := h.clipboard()) else None, 6)
    assert '0123456789' in full, full
    # Persistent block mode is reflected in the probe (Alt+drag uses the same path).
    h.term('terminal-block-mode', '1')
    p = h.terminal('block-mode-on')
    assert h.active(p)['block_mode'] is True, p
    h.term('terminal-block-mode', '0')
    p = h.terminal('block-mode-off')
    assert h.active(p)['block_mode'] is False, p


def kitty_graphics(h):
    h.setup()
    h.open_terminal()
    s = h.active()
    # Bounded inline-only storage: enabled, file/shared-memory mediums disabled.
    assert s['kitty_storage_limit'] > 0, s
    assert s['kitty_file_medium'] is False and s['kitty_shm_medium'] is False, s
    gen0 = s['kitty_generation']
    # Transmit a 24x24 inline RGB image (four colored quadrants) through the
    # shell (printf -> terminal). Natural pixel size keeps it visible.
    size = 24
    pixels = bytearray()
    for y in range(size):
        for x in range(size):
            if y < size // 2:
                px = (255, 0, 0) if x < size // 2 else (0, 255, 0)
            else:
                px = (0, 0, 255) if x < size // 2 else (255, 255, 0)
            pixels.extend(px)
    b64 = base64.b64encode(bytes(pixels)).decode()
    # Hide the long command echo so the screenshot shows the rendered image.
    h.term('terminal-write', 'stty -echo; clear\r')
    time.sleep(0.2)
    h.term('terminal-write', "printf '\\033_Ga=T,f=24,s=24,v=24,i=1,q=2,c=12,r=6;" + b64 + "\\033\\\\'\r")
    p = h.wait_session(lambda p: (x := h.active(p)) is not None and x['kitty_generation'] != gen0)
    s = h.active(p)
    assert s['phase'] == 'running', s
    h.screenshot('kitty-image')
    h.term('terminal-write', 'stty echo\r')
    # A file-medium image must be rejected (medium disabled): generation unchanged.
    gen1 = s['kitty_generation']
    h.term('terminal-write', "printf '\\033_Ga=T,f=24,s=2,v=2,i=2,t=f,q=2;/tmp/coral-nope\\033\\\\'\r")
    time.sleep(0.5)
    s = h.active()
    assert s['kitty_generation'] == gen1, s
    assert s['phase'] == 'running', s
    h.screenshot('kitty-file-medium-denied')


SCENARIOS = [
    ('trust-direct', trust_direct),
    ('output-render', output_render),
    ('resize', resize),
    ('exit-restart', exit_restart),
    ('cancel-reap', cancel_reap),
    ('close-sessions', close_sessions),
    ('session-limit', session_limit),
    ('osc-clipboard-denied', osc_clipboard_denied),
    ('no-stdout-injection', no_stdout_injection),
    ('editor-font', editor_font),
    ('block-selection', block_selection),
    ('kitty-graphics', kitty_graphics),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-terminal')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    parser.add_argument('--case', action='append', choices=[name for name, _ in SCENARIOS],
                        help='Run only named cases (repeatable)')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    scenarios = [(n, f) for n, f in SCENARIOS if not args.case or n in args.case]
    began = time.monotonic()
    evidence = {'status': 'running', 'checks': [], 'invocation': [sys.executable, *sys.argv],
                'binary': str(args.binary.resolve()), 'runtime_budget_seconds': 400,
                'selected_cases': [n for n, _ in scenarios], 'total_available_cases': len(SCENARIOS),
                'scope': 'Native M5 libghostty-vt terminal: always-trusted direct spawn, editor font, dirty-row rendering, block selection, bounded Kitty graphics, lifecycle, OSC policy.',
                'isolation': 'Private headless compositor/D-Bus; independent per-case HOME/XDG and fixtures.'}

    def expired(_signal, _frame):
        raise BudgetExpired('Terminal acceptance exceeded its 400-second budget')

    previous = signal.signal(signal.SIGALRM, expired)
    signal.alarm(400)
    save(output, evidence)
    try:
        binary = args.binary.resolve().read_bytes()
        import hashlib
        evidence['binary_sha256'] = hashlib.sha256(binary).hexdigest()
        if not all(marker in binary for marker in (b'CORAL_COMMAND_DONE', b'CORAL_TERMINAL ', b'CORAL_POLICY ')):
            raise RuntimeError('Binary lacks terminal/policy test hooks; build with -Dtest-hooks=true and -Dghostty-prefix')
        del binary
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
            for name, scenario in scenarios:
                record = {'name': name, 'status': 'running'}
                evidence['checks'].append(record)
                save(output, evidence)
                start, h = time.monotonic(), None
                child_start = len(session.children)
                print('RUN', name, flush=True)
                try:
                    h = TerminalHarness(session, args.binary.resolve(), output, evidence, name, began + 395)
                    scenario(h)
                    h.stop()
                    record.update(status='passed')
                    print('PASS', name, flush=True)
                except Exception as exc:
                    record.update(status='failed', error=str(exc), traceback=traceback.format_exc(),
                                  last_probe=h.last.copy() if h else {})
                    print('FAIL', name, str(exc)[:1800], flush=True)
                    if h:
                        try:
                            h.screenshot('failure')
                        except Exception:
                            record['screenshot_error'] = traceback.format_exc()
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
        for name, _ in scenarios:
            if name not in completed:
                evidence['checks'].append({'name': name, 'status': 'blocked', 'reason': 'Setup or runtime budget failed'})
        for record in evidence['checks']:
            if record['status'] == 'running':
                record.update(status='failed', error='Interrupted; see suite fatal error')
        evidence['seconds'] = time.monotonic() - began
        evidence['counts'] = {status: sum(c['status'] == status for c in evidence['checks'])
                              for status in ('passed', 'failed', 'blocked')}
        save(output, evidence)
    print(f"{evidence['status'].upper()}: {evidence['counts']['passed']}/{len(scenarios)} native terminal cases; {output / 'results.json'}", flush=True)
    return 0 if evidence['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
