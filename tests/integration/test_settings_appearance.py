#!/usr/bin/env python3
"""S3: real standalone editors and shared Pearl draft authority in a private session."""
import argparse
import copy
import hashlib
import json
import time
import uuid
from pathlib import Path
from PIL import Image
from test_settings_app import (ROOT, APP_ID, PrivateSession, IPC, wait_for, ctl, capture,
                               clean, request, probe, windows, click_widget, keys, resize)
from settings_editor import EditorPeer


def settled(peer):
    return wait_for(lambda: (v if not (v := peer.state())['busy'] else False), 25)


def ready(s, ipc):
    return wait_for(lambda: (v if (v := probe(s, ipc))['editor']['ready'] and
                            v['editor']['download'] == 'none' and not v['editor']['local'] and
                            v['editor']['upload'] == 'none' and v['editor']['can_edit'] and not v['editor']['state']['busy'] else False), 15)


def control(s, ipc, field):
    return next(c['bounds'] for c in probe(s, ipc)['controls'] if c['field'] == field)


def click(s, ipc, field):
    time.sleep(.2)  # Wait for GTK to allocate controls after snapshot/layout changes.
    if field not in ('raw', 'apply', 'discard', 'merge'):
        for _ in range(30):
            v = probe(s, ipc); rect = control(s, ipc, field); body = v['body_bounds']
            if rect['y'] >= body['y'] and rect['y'] + rect['height'] <= body['y'] + body['height']:
                break
            win = windows(ipc)[0]['geometry']
            s.run(['wlrctl','pointer','move','-100000','-100000'])
            s.run(['wlrctl','pointer','move',str(round(win['x']+body['x']+body['width']/2)),str(round(win['y']+body['y']+body['height']/2))])
            # Small viewports can oscillate past a partly clipped control with a
            # fixed wheel step. Reduce the final scroll to the missing distance.
            below = rect['y'] > body['y']
            distance = rect['y'] + rect['height'] - body['y'] - body['height'] if below else body['y'] - rect['y']
            step = min(120, max(10, distance + 5))
            s.run(['wlrctl','pointer','scroll',str(step if below else -step),'0'])
            time.sleep(.1)
        else:
            raise AssertionError(('control not reachable', field, rect, body))
    click_widget(s, ipc, control(s, ipc, field))


def type_text(s, text):
    s.run(['wtype', '-s', '100', '-M', 'ctrl', 'a', '-m', 'ctrl', text, '-s', '50'])


def raw(s, ipc, text):
    request(s, ipc, page='advanced')
    wait_for(lambda: probe(s, ipc)['page'] == 'advanced')
    ready(s, ipc)
    click(s, ipc, 'raw')
    type_text(s, text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('settings', 'pearl', 'ctl', 'spike'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/settings-app/s3/acceptance')
    args = parser.parse_args()
    for name in ('settings', 'pearl', 'ctl', 'spike', 'output'):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    report = dict(status='running', checks=checks, binaries={n: hashlib.sha256(getattr(args, n).read_bytes()).hexdigest() for n in ('settings','pearl','ctl')})
    def passed(name):
        checks[name] = True
        print('PASS', name, flush=True)
    try:
        with PrivateSession(args.output/'session', tool_prefix=ROOT/'.cache/aqueous-082') as s:
            s.env['GSETTINGS_BACKEND'] = 'memory'
            mode = s.base/'generator-mode'; mode.write_text('pass')
            calls = s.base/'generator-calls'; calls.write_text('')
            s.env.update(PATH=str(ROOT/'tests/fixtures/theme')+':'+s.env['PATH'],
                         PEARL_TEST_GENERATOR_MODE=str(mode), PEARL_TEST_GENERATOR_LOG=str(calls))
            ipc = IPC(s)
            output = next(iter(ipc.outputs().values()))
            s.run(['wlr-randr', '--output', output['name'], '--custom-mode', '1600x1100@60Hz'])
            rules = Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
            resize(s, rules, 1040, 760)
            shell = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings'); shell.expect('event=control-ready')
            peer = EditorPeer(s, ipc); other = EditorPeer(s, ipc)
            initial = settled(peer)
            original = json.loads(peer.document('committed'))
            path = Path(ctl(s, args.ctl, 'preferences', 'status')['result']['path'])

            # A full-size candidate, including multi-byte chunk boundaries, is
            # retained verbatim even when invalid. No partial upload is visible.
            text = '{"font":"' + 'a'*32758 + '🐚' + 'b'*(65536-32758-4-11) + '"}'
            assert len(text.encode()) == 65536
            peer.keep(text)
            assert other.document() == text
            assert not peer.state()['valid']
            assert peer.action('validate')['state'] == 'failed'
            assert not path.exists()
            peer.keep(''); assert other.document() == ''
            assert not peer.state()['valid']
            peer.action('discard')
            passed('bounded-full-document-invalid-and-empty-retention')

            state = peer.state()
            begin = peer.call('document.begin', domain='pearl', expected_draft_revision=state['draft_revision'], base_revision=state['base_revision'], bytes='3', sha256=hashlib.sha256(b'abc').hexdigest())['result']
            assert not peer.call('document.write', transfer=begin['transfer'], offset='1', text='abc')['ok']
            assert peer.call('document.write', transfer=begin['transfer'], offset='0', text='xyz')['ok']
            result = peer.call('document.finish', transfer=begin['transfer'], operation=uuid.uuid4().hex)['result']
            assert result['state'] == 'failed' and result['error_code'] == 'DigestMismatch', result
            assert peer.state()['draft_revision'] == state['draft_revision']
            assert not peer.call('document.begin', domain='pearl', expected_draft_revision=state['draft_revision'], base_revision=state['base_revision'], bytes='65537', sha256='0'*64)['ok']
            passed('partial-transfer-and-digest-failure-never-mutate-draft')

            stale = peer.state()
            peer.keep('{"font_size":16}')
            assert peer.action('discard', expected_draft_revision=stale['draft_revision'])['error_code'] == 'StaleDraft'
            assert other.document() == '{"font_size":16}'
            nonce = uuid.uuid4().hex
            params = dict(domain='pearl', expected_draft_revision=peer.state()['draft_revision'], operation=nonce)
            one = peer.call('draft.validate', **params)
            two = other.call('draft.validate', **dict(reversed(list(params.items()))))
            assert one['result'] == two['result']
            assert not other.call('draft.discard', **params)['ok']
            peer.action('discard')
            passed('shared-cas-and-canonical-operation-deduplication')

            app = s.child('settings', [args.settings, '--page', 'appearance'], G_DEBUG='fatal-warnings')
            app.expect('event=settings-window-created'); ready(s, ipc)
            assert not probe(s, ipc)['fixture']
            fields = {c['field'] for c in probe(s, ipc)['controls']}
            assert {'mode','variant','source','gtk_name','seed','wallpaper','color','font','font_size','fit','density','motion','choose','raw'} <= fields
            capture(s, 'appearance-real-dark')
            # Actual form input preserves unrelated fields from the full JSON.
            p = copy.deepcopy(original); p['font_size'] = 16
            p['theme'].update(mode='dynamic', source='seed', seed='#7654ab')
            p['reduced_motion'] = True
            peer.keep(json.dumps(p)); ready(s, ipc)
            wait_for(lambda: probe(s, ipc)['editor']['state']['draft_revision'] == int(peer.state()['draft_revision']) and probe(s, ipc)['editor']['can_edit'])
            click(s, ipc, 'seed'); type_text(s, '#123456')
            wait_for(lambda: json.loads(peer.document())['theme']['seed'] == '#123456')
            actual = json.loads(peer.document()); expected = copy.deepcopy(p); expected['theme']['seed'] = '#123456'
            assert actual == expected, actual
            assert not path.exists()
            passed('real-appearance-form-preserves-full-preference-document')

            raw(s, ipc, '{"font_size":')
            request(s, ipc, page='sound')
            wait_for(lambda: probe(s, ipc)['page'] == 'sound')
            assert peer.document() == '{"font_size":' and not peer.state()['valid']
            assert not probe(s, ipc)['editor']['can_apply']
            app.stop(); clean(app)
            assert shell.proc.poll() is None and not path.exists()
            app = s.child('settings-reopen', [args.settings, '--page', 'advanced'], G_DEBUG='fatal-warnings')
            app.expect('event=settings-window-created'); ready(s, ipc)
            assert probe(s, ipc)['editor']['bytes'] == len('{"font_size":')
            capture(s, 'advanced-invalid-retained')
            passed('invalid-advanced-navigation-close-reopen-without-save')

            raw(s, ipc, json.dumps(expected))
            ready(s, ipc)
            click(s, ipc, 'apply')
            wait_for(lambda: path.exists() and not peer.state()['dirty'] and not peer.state()['busy'], 25)
            assert json.loads(path.read_text()) == expected
            assert path.stat().st_mode & 0o777 == 0o600
            request(s, ipc, page='appearance'); ready(s, ipc)
            wait_for(lambda: probe(s, ipc)['appearance_updates'] > 1)
            passed('explicit-apply-atomic-save-and-event-driven-theme-refresh')

            # Normal transient chooser cancels without a draft, then previews an
            # accepted image without changing saved preferences until Apply.
            before = path.read_bytes()
            click(s, ipc, 'choose'); wait_for(lambda: probe(s, ipc)['editor']['picker'])
            keys(s, 'Escape'); wait_for(lambda: not probe(s, ipc)['editor']['picker'])
            assert not peer.state()['dirty'] and path.read_bytes() == before
            image = s.base/'wallpaper with spaces.png'; Image.new('RGB',(1400,800),(64,105,155)).save(image)
            click(s, ipc, 'choose'); wait_for(lambda: probe(s, ipc)['editor']['picker'])
            s.run(['wtype','-s','200','-M','ctrl','l','-m','ctrl',str(image),'-k','Return'])
            wait_for(lambda: peer.state()['dirty'])
            wait_for(lambda: probe(s, ipc)['editor']['preview'], 15)
            assert json.loads(peer.document())['wallpaper']['path'] == str(image)
            assert path.read_bytes() == before
            capture(s, 'appearance-wallpaper-preview')
            click(s, ipc, 'apply'); wait_for(lambda: not peer.state()['dirty'] and not peer.state()['busy'], 25)
            expected = json.loads(path.read_text())
            passed('normal-wallpaper-dialog-cancel-select-preview-and-save')

            # Failure keeps working preferences and shared draft intact.
            bad = copy.deepcopy(expected); bad['wallpaper']['path'] = str(s.base/'missing.png')
            peer.keep(json.dumps(bad)); result = peer.action('apply')
            assert result['state'] == 'failed', result
            assert json.loads(path.read_text()) == expected and peer.state()['dirty']
            peer.action('discard')
            bad = copy.deepcopy(expected); bad['theme'].update(mode='gtk', gtk_name='Missing-S3-Theme')
            peer.keep(json.dumps(bad)); result = peer.action('apply')
            assert result['state'] == 'failed' and result['error_code'] == 'GtkThemeNotInstalled', result
            peer.action('discard')
            passed('image-and-native-theme-failure-retain-draft-and-working-settings')

            # Persistence and opt-in exports keep their independent outcomes.
            before = path.read_bytes()
            bad = copy.deepcopy(expected); bad['font_size'] = 17
            peer.keep(json.dumps(bad)); path.parent.chmod(0o500)
            try:
                result = peer.action('apply')
                assert result['state'] == 'failed' and result['error_code'] == 'SaveFailed', result
                assert path.read_bytes() == before and peer.state()['dirty']
            finally:
                path.parent.chmod(0o700)
            peer.action('discard')
            exported = copy.deepcopy(expected)
            exported['exports'] = [{'name':'s3.conf','template':'background={{surface}}\n'}]
            peer.keep(json.dumps(exported)); assert peer.action('apply')['state'] == 'succeeded'
            export = path.parent/'exports/s3.conf'; assert export.exists()
            export.write_text('user-owned contents')
            exported['font_size'] = 16
            peer.keep(json.dumps(exported)); assert peer.action('apply')['state'] == 'succeeded'
            assert peer.state()['export_error'] == 'ExportOwnershipConflict' and not peer.state()['dirty']
            assert export.read_text() == 'user-owned contents'
            peer.keep(json.dumps(expected)); assert peer.action('apply')['state'] == 'succeeded'
            passed('save-failure-retention-and-independent-export-error')

            # Independent external edits merge; overlapping edits remain intact.
            mine = copy.deepcopy(expected); mine['font_size'] = 17
            peer.keep(json.dumps(mine))
            theirs = copy.deepcopy(expected); theirs['density'] = 'compact'
            state = settled(peer)
            ctl(s, args.ctl, 'preferences', 'apply', '--revision', state['revision'], '--text', json.dumps(theirs))
            wait_for(lambda: not peer.state()['busy'] and peer.state()['conflict'], 25)
            assert peer.action('merge')['state'] == 'succeeded'
            merged = json.loads(peer.document()); assert merged['font_size'] == 17 and merged['density'] == 'compact'
            assert peer.action('apply')['state'] == 'succeeded'
            expected = json.loads(path.read_text())
            mine = copy.deepcopy(expected); mine['font_size'] = 18
            peer.keep(json.dumps(mine)); theirs = copy.deepcopy(expected); theirs['font_size'] = 19
            ctl(s, args.ctl, 'preferences', 'apply', '--revision', settled(peer)['revision'], '--text', json.dumps(theirs))
            wait_for(lambda: not peer.state()['busy'] and peer.state()['conflict'], 25)
            assert peer.action('merge')['error_code'] == 'MergeConflict'
            assert json.loads(peer.document()) == mine and json.loads(path.read_text()) == theirs
            request(s, ipc, page='advanced'); ready(s, ipc); capture(s, 'advanced-conflict')
            peer.action('discard'); expected = theirs
            passed('external-change-three-way-merge-and-overlapping-conflict')

            # Slow dynamic preparation allows a second editor to retain a newer
            # serial with the same text. Apply may clear only the captured serial.
            slow = copy.deepcopy(expected); slow['theme'].update(mode='dynamic', source='seed', seed='#a12378')
            mode.write_text('slow'); peer.keep(json.dumps(slow))
            operation = peer.action('apply', wait=False); assert operation['state'] == 'pending', operation
            second = copy.deepcopy(slow); second['font_size'] = 20
            other.keep(json.dumps(second)); other.keep(json.dumps(slow))
            newest = other.state()['draft_revision']
            wait_for(lambda: not peer.state()['busy'], 25)
            assert peer.state()['dirty'] and peer.state()['draft_revision'] == newest
            assert json.loads(path.read_text()) == slow
            mode.write_text('pass'); peer.action('discard'); expected = slow
            passed('in-flight-apply-cannot-clear-newer-equal-text-draft')

            # Native lock denies all mutations, releases transfers and hides the
            # window. Unlock alone does not resume or present this frontend.
            locker = s.child('locker',[args.spike],input_pipe=True,PEARL_T00_ISOLATED='1',WLR_BACKENDS='headless',PEARL_T00_MODE='plain')
            locker.expect('T00 event=ready')
            locker.proc.stdin.write('lock\n'); locker.proc.stdin.flush(); locker.expect('T00 event=locked')
            wait_for(lambda: peer.state()['locked'])
            wait_for(lambda: not probe(s, ipc)['visible'])
            state = peer.state()
            assert not peer.call('document.begin', domain='pearl', expected_draft_revision=state['draft_revision'],base_revision=state['base_revision'],bytes='0',sha256=hashlib.sha256(b'').hexdigest())['ok']
            assert not peer.call('draft.apply',domain='pearl',expected_draft_revision=state['draft_revision'],base_revision=state['base_revision'],operation=uuid.uuid4().hex)['ok']
            locker.proc.stdin.write('unlock\n'); locker.proc.stdin.flush(); locker.expect('T00 event=unlocked')
            wait_for(lambda: not peer.state()['locked']); time.sleep(.3)
            assert not probe(s, ipc)['visible']
            request(s, ipc, page='appearance'); wait_for(lambda: probe(s, ipc)['visible']); ready(s, ipc)
            locker.proc.stdin.write('quit\n'); locker.proc.stdin.flush(); locker.proc.wait(5); clean(locker)
            passed('lock-denial-hidden-window-and-explicit-unlock-resume')

            # Closing immediately after typing flushes the candidate. Reopening
            # retains it; Discard is explicit and never rewrites the saved file.
            raw(s, ipc, '{"font_size":21}')
            before = path.read_bytes(); app.stop(); clean(app)
            assert peer.document() == '{"font_size":21}' and path.read_bytes() == before
            app = s.child('settings-final', [args.settings, '--page','appearance'],G_DEBUG='fatal-warnings')
            app.expect('event=settings-window-created'); ready(s, ipc)
            click(s, ipc, 'discard'); wait_for(lambda: not peer.state()['dirty'])
            assert path.read_bytes() == before
            passed('close-flush-reopen-and-explicit-discard')

            # Exercise real controls under committed light/native themes, then
            # compact navigation with the largest supported application text.
            for theme_mode, variant in [('static','light'),('gtk','light')]:
                styled = copy.deepcopy(expected)
                styled['theme'].update(mode=theme_mode, variant=variant, gtk_name='')
                peer.keep(json.dumps(styled)); assert peer.action('apply')['state'] == 'succeeded'
                wait_for(lambda: probe(s, ipc)['style'] == ('gtk' if theme_mode == 'gtk' else variant))
                request(s, ipc, page='appearance'); ready(s, ipc)
                capture(s, 'appearance-real-' + theme_mode)
            app.stop(); clean(app)
            styled['font_size'] = 24; styled['theme'].update(mode='static', variant='dark')
            peer.keep(json.dumps(styled)); assert peer.action('apply')['state'] == 'succeeded'
            resize(s, rules, 480, 700)
            ipc.call('command', action='session.reload', fields={})
            app = s.child('settings-narrow',[args.settings,'--page','appearance'],G_DEBUG='fatal-warnings')
            app.expect('event=settings-window-created'); ready(s, ipc)
            time.sleep(.3); capture(s, 'appearance-real-narrow-initial')
            v = probe(s, ipc); assert v['narrow'] and v['width'] <= 480, v
            footer = v['footer_bounds']; assert footer['height'] > 0 and footer['y'] + footer['height'] <= v['height']
            click(s, ipc, 'motion'); ready(s, ipc)
            assert peer.state()['dirty']
            capture(s, 'appearance-real-narrow-large-text')
            click(s, ipc, 'discard'); wait_for(lambda: not peer.state()['dirty'])
            app.stop(); clean(app)
            resize(s, rules, 1040, 760)
            ipc.call('command', action='session.reload', fields={})
            app = s.child('settings-recovery',[args.settings,'--page','advanced'],G_DEBUG='fatal-warnings')
            app.expect('event=settings-window-created'); ready(s, ipc)
            passed('real-light-native-and-narrow-large-text-controls')

            # Backend loss retains the frontend copy and requires explicit review
            # after reconnect, rather than automatically replaying any mutation.
            raw(s, ipc, '{"font_size":22}'); ready(s, ipc)
            peer.close(); other.close(); shell.stop(); clean(shell)
            wait_for(lambda: not probe(s, ipc)['editor']['online'])
            app.proc.send_signal(__import__('signal').SIGTERM)
            wait_for(lambda: probe(s, ipc)['editor']['close_dialog'])
            capture(s, 'unavailable-close-retention')
            keys(s, 'Escape')
            shell = s.child('pearl-restarted', [args.pearl],G_DEBUG='fatal-warnings'); shell.expect('event=control-ready')
            click_widget(s, ipc, probe(s, ipc)['retry_bounds'])
            wait_for(lambda: probe(s, ipc)['editor']['online'] and probe(s, ipc)['editor']['ready'], 15)
            assert probe(s, ipc)['editor']['recovery'] and not probe(s, ipc)['editor']['can_apply']
            peer = EditorPeer(s, ipc); settled(peer)
            assert not peer.state()['dirty']
            for page in ('appearance', 'advanced'):
                request(s, ipc, page=page)
                wait_for(lambda: probe(s, ipc)['page'] == page)
                assert probe(s, ipc)['editor']['recovery'] and probe(s, ipc)['editor']['local']
            wait_for(lambda: not probe(s, ipc)['editor']['state']['busy'] and probe(s, ipc)['editor']['download'] == 'none')
            time.sleep(.3)  # Navigation and the recovery banner reallocate the fixed footer.
            capture(s, 'recovery-before-discard')
            (s.output/'recovery-probe.json').write_text(json.dumps(probe(s, ipc), indent=2))
            click(s, ipc, 'discard'); time.sleep(.3)
            wait_for(lambda: not probe(s, ipc)['editor']['recovery'])
            assert not peer.state()['dirty']
            passed('backend-restart-and-close-failure-never-replay-local-candidate')
            app.stop(); clean(app)
            peer.close(); shell.stop(); clean(shell)
        report['status'] = 'passed'
    finally:
        (args.output/'results.json').write_text(json.dumps(report, indent=2)+'\n')
    print(f"S3: {len(checks)} groups passed", flush=True)


if __name__ == '__main__':
    main()
