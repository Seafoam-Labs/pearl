#!/usr/bin/env python3
"""Native shared window-rule builder against a private Aqueous/D-Bus session."""
import argparse
import hashlib
import json
import time
from pathlib import Path
from test_settings_app import ROOT, PrivateSession, IPC, wait_for, capture, probe, keys, resize, clean, ctl
from test_settings_appearance import ready, click, type_text
from test_settings_services import Peer, aq_ready, navigate


def dialog(s, ipc):
    return probe(s, ipc)['window_rules']


def dialog_click(s, ipc, field):
    for _ in range(60):
        state = dialog(s, ipc)
        control = next(c for c in state['controls'] if c['field'] == field)
        rect, body = control['bounds'], state['body']
        window = next(w for w in ipc.state() if w['kind'] == 'window' and 'window rule' in w.get('title', '').lower())['geometry']
        assert rect and control['enabled'], (field, control)
        if field in ('rules.save', 'rules.cancel', 'rules.delete') or (rect['y'] >= body['y'] and rect['y'] + rect['height'] <= body['y'] + body['height']):
            s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
            s.run(['wlrctl', 'pointer', 'move', str(round(window['x']+rect['x']+rect['width']/2)), str(round(window['y']+rect['y']+rect['height']/2))])
            s.run(['wlrctl', 'pointer', 'click'])
            time.sleep(.15)
            return
        below = rect['y'] > body['y']
        distance = rect['y']+rect['height']-body['y']-body['height'] if below else body['y']-rect['y']
        s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
        s.run(['wlrctl', 'pointer', 'move', str(round(window['x']+body['x']+body['width']/2)), str(round(window['y']+body['y']+body['height']/2))])
        s.run(['wlrctl', 'pointer', 'scroll', str(min(160, max(10, distance+5))*(1 if below else -1)), '0'])
        time.sleep(.12)
    raise AssertionError(('unreachable', field, state))


def choose(s, ipc, field, index):
    dialog_click(s, ipc, field)
    keys(s, 'Home', *(['Down']*index), 'Return')


def add_field(s, ipc, base, key, configured):
    matchers = {'app_id', 'class', 'title', 'tag', 'content_type', 'window_type', 'scope'}
    condition = key in matchers
    available = [f['key'] for f in base['collection_schema']['window_rules']['fields']
                 if (f['key'] in matchers) == condition and f['key'] not in configured]
    choose(s, ipc, 'rules.condition' if condition else 'rules.setting', available.index(key))
    dialog_click(s, ipc, 'rules.add-condition' if condition else 'rules.add-setting')


def save(s, ipc, peer):
    dialog_click(s, ipc, 'rules.save')
    wait_for(lambda:not dialog(s, ipc)['dialog'])
    aq_ready(s, ipc, peer)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('settings', 'pearl', 'ctl'):
        parser.add_argument('--'+name, required=True, type=Path)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/window-rules')
    args = parser.parse_args()
    for name in ('settings', 'pearl', 'ctl', 'output'):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(status='running', checks={}, binaries={n:hashlib.sha256(getattr(args,n).read_bytes()).hexdigest() for n in ('settings','pearl','ctl')})
    def passed(name):
        report['checks'][name] = True
        print('PASS', name, flush=True)
    try:
      with PrivateSession(args.output/'session', tool_prefix=ROOT/'.cache/aqueous-activity-production') as s:
        s.env['GSETTINGS_BACKEND'] = 'memory'
        ipc = IPC(s)
        output = next(iter(ipc.outputs().values()))
        s.run(['wlr-randr','--output',output['name'],'--custom-mode','1600x1100@60Hz'])
        rule_file = Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
        resize(s, rule_file, 1040, 900)
        with rule_file.open('a') as f:
            f.write('\n[[window]]\napp_id="firefox"\nfloating=true\nopacity=0.8\n')
        ipc.call('command',action='session.reload',fields={})
        shell = s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings'); shell.expect('event=control-ready')
        app = s.child('settings',[args.settings,'--page','aqueous','--section','rules'],G_DEBUG='fatal-warnings'); app.expect('event=settings-window-created')
        peer = Peer(s, ipc)
        ready(s, ipc); aq_ready(s, ipc, peer)
        navigate(s, ipc, 'aqueous', 'rules')
        prefs = peer.document()
        base = peer.aq_document('committed')
        rid = next(r['id'] for r in base['window_rules'] if r['values'].get('app_id') == 'firefox')
        assert len([c for c in probe(s,ipc)['controls'] if c['field'].startswith('rules.edit.')]) == 2
        capture(s, 'native-rules', output['name'])
        navigate(s,ipc,'aqueous','layouts')
        click(s,ipc,'layout.gaps_outer'); type_text(s,'19'); keys(s,'Tab'); aq_ready(s,ipc,peer)
        navigate(s,ipc,'aqueous','rules')
        click(s, ipc, 'rules.add'); wait_for(lambda:dialog(s,ipc)['dialog'])
        dialog_click(s, ipc, 'rules.save')
        assert 'at least one condition' in dialog(s,ipc)['error_text']
        dialog_click(s, ipc, 'rules.add-condition')
        dialog_click(s, ipc, 'rules.save')
        assert 'helper treats a new empty value as removal' in dialog(s,ipc)['error_text']
        dialog_click(s, ipc, 'rules.value.app_id'); type_text(s, 'firefox')
        choose(s, ipc, 'rules.condition', 1)  # title, after Application ID is used
        dialog_click(s, ipc, 'rules.add-condition'); type_text(s, '*Picture-in-Picture*')
        choose(s, ipc, 'rules.setting', 3)  # layout, output, workspace, floating
        dialog_click(s, ipc, 'rules.add-setting')
        capture(s, 'native-editor', output['name'])
        save(s, ipc, peer)
        draft = peer.aq_document('draft')
        assert draft['window_rule_changes'][0] == dict(op='add', values=dict(app_id='firefox', title='*Picture-in-Picture*', floating=True)), draft
        assert any(c['id']=='layout.gaps_outer' and c['value']==19 for c in draft['changes']), draft
        assert peer.document() == prefs
        passed('native-create-multiple-conditions-and-typed-effect-separate-draft')
        navigate(s,ipc,'aqueous','input'); navigate(s,ipc,'aqueous','rules')
        click(s, ipc, 'rules.edit.new.0'); wait_for(lambda:dialog(s,ipc)['dialog'])
        choose(s, ipc, 'rules.value.floating', 1)
        add_field(s,ipc,base,'opacity',{'app_id','title','floating'})
        type_text(s,'2')
        dialog_click(s,ipc,'rules.save')
        assert 'Opacity: InvalidRuleValue' in dialog(s,ipc)['error_text']
        dialog_click(s,ipc,'rules.value.opacity'); type_text(s,'0')
        save(s, ipc, peer)
        assert peer.aq_document('draft')['window_rule_changes'][0]['values']['opacity'] == 0
        assert peer.aq_document('draft')['window_rule_changes'][0]['values']['floating'] is False
        click(s, ipc, 'rules.edit.new.0'); wait_for(lambda:dialog(s,ipc)['dialog'])
        dialog_click(s, ipc, 'rules.delete'); wait_for(lambda:not dialog(s,ipc)['dialog']); aq_ready(s,ipc,peer)
        assert peer.aq_document('draft')['window_rule_changes'] == []
        passed('pending-addition-edit-false-zero-bounds-and-delete-without-backend-id')
        peer.aq_action('discard'); aq_ready(s,ipc,peer)
        click(s, ipc, 'rules.edit.'+rid); wait_for(lambda:dialog(s,ipc)['dialog'])
        choose(s, ipc, 'rules.value.floating', 1); save(s,ipc,peer)
        click(s, ipc, 'rules.edit.'+rid); wait_for(lambda:dialog(s,ipc)['dialog'])
        dialog_click(s,ipc,'rules.remove.opacity'); save(s,ipc,peer)
        values = peer.aq_document('draft')['window_rule_changes'][0]['values']
        assert values == dict(floating=False, opacity=None), values
        passed('repeated-edit-merges-earlier-delta-and-emits-null-removal')
        click(s, ipc, 'rules.edit.'+rid); wait_for(lambda:dialog(s,ipc)['dialog'])
        candidate = peer.aq_document('draft')
        candidate['window_rule_changes'][0]['values']['title'] = '*external*'
        assert peer.aq_keep(candidate)['result']['state'] == 'succeeded'
        aq_ready(s,ipc,peer)
        dialog_click(s,ipc,'rules.save')
        assert dialog(s,ipc)['dialog'] and 'shared draft or snapshot changed' in dialog(s,ipc)['error_text']
        dialog_click(s,ipc,'rules.cancel'); wait_for(lambda:not dialog(s,ipc)['dialog'])
        assert peer.aq_document('draft')['window_rule_changes'][0]['values']['title'] == '*external*'
        passed('competing-draft-keeps-modal-input-and-rejects-stale-save')
        peer.aq_action('discard'); aq_ready(s,ipc,peer)
        click(s,ipc,'rules.up.'+rid); aq_ready(s,ipc,peer)
        draft = peer.aq_document('draft')
        assert draft['window_rule_changes'] == [dict(op='move',id=rid,direction=-1)], draft
        assert not next(c for c in probe(s,ipc)['controls'] if c['field']=='rules.add')['enabled']
        mixed = dict(draft, changes=[dict(id='layout.gaps_outer',value=19)])
        rejected = peer.aq_keep(mixed)
        assert not rejected['ok'] or rejected['result']['state']=='failed', rejected
        assert peer.aq_document('draft') == draft
        passed('move-projects-order-and-blocks-cross-page-mutations')
        peer.aq_action('discard'); aq_ready(s,ipc,peer)
        click(s,ipc,'rules.edit.'+rid); wait_for(lambda:dialog(s,ipc)['dialog'])
        choose(s,ipc,'rules.value.floating',1); save(s,ipc,peer)
        # Exercise the existing receipt/impact/protected apply route.
        for action, outcome in (('validate','validated'),('apply','saved')):
            click(s,ipc,'aqueous.'+action)
            try:
                wait_for(lambda:peer.aqueous()['outcome']==outcome and not peer.aqueous()['busy'],45)
            except TimeoutError:
                print('NATIVE ACTION FAILED',action,peer.aqueous(),probe(s,ipc)['aqueous'],flush=True)
                raise
            aq_ready(s,ipc,peer)
        assert next(r for r in peer.aq_document('committed')['window_rules'] if r['values'].get('app_id')=='firefox')['values']['floating'] is False
        assert not peer.aqueous()['draft'] and peer.document() == prefs
        passed('canonical-validate-apply-receipt-and-preference-isolation')
        for width in (560,390):
            resize(s,rule_file,width,720)
            ipc.call('command',action='session.reload',fields={})
            try:
                wait_for(lambda:probe(s,ipc)['width']==width)
            except TimeoutError:
                capture(s, 'resize-failed-'+str(width), output['name'])
                print('RESIZE FAILED', width, probe(s,ipc), flush=True)
                raise
            peer.aq_action('refresh'); aq_ready(s,ipc,peer)
            click(s,ipc,'rules.add'); wait_for(lambda:dialog(s,ipc)['dialog'])
            dialog_click(s,ipc,'rules.add-condition'); type_text(s,'firefox')
            choose(s,ipc,'rules.setting',3); dialog_click(s,ipc,'rules.add-setting')
            geometry = next(w['geometry'] for w in ipc.state() if w['kind']=='window' and 'window rule' in w.get('title','').lower())
            assert geometry['width'] <= width, geometry
            capture(s,'native-editor-'+str(width),output['name'])
            dialog_click(s,ipc,'rules.cancel'); wait_for(lambda:not dialog(s,ipc)['dialog'])
            wait_for(lambda:next(c for c in probe(s,ipc)['controls'] if c['field']=='rules.add')['focused'])
        passed('390-and-560-pixel-dialogs-with-reachable-actions')
        click(s,ipc,'rules.tester'); capture(s,'native-testing-unavailable',output['name'])
        passed('unsupported-authoritative-tester-explains-requirement')
        peer.close()
        app.stop(); clean(app); ctl(s,args.ctl,"quit"); clean(shell); ipc.close()
        report['status']='passed'
    except BaseException as exc:
        report['status']='failed'; report['error']=repr(exc)
        raise
    finally:
        (args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')

if __name__ == '__main__':
    main()
