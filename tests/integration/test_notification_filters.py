#!/usr/bin/env python3
"""Notification rules through the native Settings editor and real private D-Bus."""
import argparse
import copy
import hashlib
import json
import time
from pathlib import Path
from test_settings_app import ROOT, PrivateSession, IPC, wait_for, ctl, capture, clean, request, probe, keys, resize
from test_settings_appearance import ready, click, type_text
from test_settings_services import Peer
from test_session_services import state, closed, records, action, FIX
from test_services import command


def notified(s, fixture, **kw):
    # Commands can repeat; the fixture's log marker alone may match an earlier
    # command. Wait for this Notify reply by counting recorded responses.
    count = sum(row['kind'] == 'notification' for row in records(s))
    command(fixture, notify=kw)
    values = wait_for(lambda: (rows if len(rows) == count + 1 else False)
                      if (rows := [row for row in records(s) if row['kind'] == 'notification']) else False)
    return values[-1]['id']


def dialog_state(s, ipc):
    return probe(s, ipc)['notification_filters']


def dialog_click(s, ipc, field):
    for _ in range(45):
        info = dialog_state(s, ipc)
        target = next(c for c in info['controls'] if c['field'] == field)
        rect = target['bounds']
        assert rect, (field, target)
        win = next(w for w in ipc.state() if w['kind'] == 'window' and 'notification filter' in w.get('title', '').lower())['geometry']
        body = info['body']
        if field in ('filters.rule.save', 'filters.rule.cancel', 'filters.rule.delete') or (rect['y'] >= body['y'] and rect['y'] + rect['height'] <= body['y'] + body['height']):
            s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
            s.run(['wlrctl', 'pointer', 'move', str(round(win['x'] + rect['x'] + rect['width']/2)), str(round(win['y'] + rect['y'] + rect['height']/2))])
            s.run(['wlrctl', 'pointer', 'click'])
            time.sleep(.15)
            return
        below = rect['y'] > body['y']
        distance = rect['y'] + rect['height'] - body['y'] - body['height'] if below else body['y'] - rect['y']
        s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
        s.run(['wlrctl', 'pointer', 'move', str(round(win['x']+body['x']+body['width']/2)), str(round(win['y']+body['y']+body['height']/2))])
        s.run(['wlrctl', 'pointer', 'scroll', str(min(160, max(10, distance+5)) * (1 if below else -1)), '0'])
        time.sleep(.12)
    raise AssertionError(('unreachable dialog control', field, info))


def apply_filters(s, ipc, peer):
    # A file-monitor reload may race the click. Retain the draft and explicitly
    # retry that user action only after a terminal Busy response (never replay
    # an uncertain operation). This is the existing preference writer contract.
    for attempt in range(3):
        ready(s, ipc)
        wait_for(lambda:probe(s,ipc)['editor']['can_apply'])
        click(s,ipc,'apply')
        outcome=wait_for(lambda: 'saved' if not peer.state()['dirty'] else 'busy' if probe(s,ipc)['editor']['error_code']=='Busy' else False)
        if outcome=='saved':
            ready(s,ipc)
            return
        wait_for(lambda:not peer.state()['busy'])
    raise AssertionError(('Apply remained Busy',probe(s,ipc)['editor']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('settings', 'pearl', 'ctl'):
        parser.add_argument('--'+name, required=True, type=Path)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/notification-filters')
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
            s.env['PEARL_TEST_SESSION_LOG'] = str(s.output/'clients.jsonl')
            Path(s.env['PEARL_TEST_SESSION_LOG']).write_text('')
            ipc = IPC(s)
            output = next(iter(ipc.outputs().values()))
            s.run(['wlr-randr','--output',output['name'],'--custom-mode','1600x1100@60Hz'])
            window_rules = Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
            resize(s, window_rules, 1100, 960)
            ipc.call('command',action='session.reload',fields={})
            clients = s.child('clients',['python3',FIX],input_pipe=True)
            clients.expect('event=ready')
            shell = s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings')
            shell.expect('event=control-ready')
            peer = Peer(s, ipc)
            peer.enter('notifications')
            wait_for(lambda:not peer.state()['busy'])
            wait_for(lambda:state(s,args.ctl)['notifications']['available'])
            app = s.child('settings',[args.settings,'--page','notifications'],G_DEBUG='fatal-warnings')
            app.expect('event=settings-window-created')
            ready(s, ipc)
            wait_for(lambda:probe(s,ipc)['page']=='notifications')
            wait_for(lambda:probe(s,ipc)['width']==1100)
            time.sleep(.3)
            assert json.loads(peer.document())['notifications']['rules'] == []
            capture(s, 'native-initial', output['name'])
            click(s, ipc, 'filters.add')
            wait_for(lambda:dialog_state(s, ipc)['dialog'])
            type_text(s, 'Finished downloads')
            dialog_click(s, ipc, 'filters.condition.0.value')
            type_text(s, 'Firefox')
            dialog_click(s, ipc, 'filters.condition.add')
            type_text(s, 'download complete')
            capture(s, 'native-rule-editor', output['name'])
            dialog_click(s, ipc, 'filters.rule.save')
            wait_for(lambda:not dialog_state(s, ipc)['dialog'])
            ready(s, ipc)
            rule = json.loads(peer.document())['notifications']['rules'][0]
            rid = rule['id']
            assert rule['name']=='Finished downloads' and len(rule['conditions'])==2, rule
            assert rule['conditions'][1]['operator']=='contains', rule
            assert peer.state()['dirty'] and json.loads(peer.document('committed'))['notifications']['rules']==[]
            passed('native-add-multiple-conditions-retains-shared-draft')
            before = state(s,args.ctl)['notifications']['count']
            st = peer.state()
            test_params=dict(view=peer.view,draft_revision=st['draft_revision'],revision=st['revision'],sample_serial='1',sample=dict(app_name='Firefox',summary='Download complete',body='',desktop_entry='',urgency='normal'))
            tested = peer.call('notifications.test',**test_params)
            assert tested['ok'] and tested['result']['decision']=='block' and tested['result']['dirty'], tested
            assert state(s,args.ctl)['notifications']['count']==before
            bad = peer.call('notifications.test',**(test_params|{'draft_revision':'999999'}))
            assert not bad['ok'], bad
            bad = peer.call('notifications.test',**(test_params|{'sample':test_params['sample']|{'unexpected':True}}))
            assert not bad['ok'], bad
            passed('read-only-draft-tester-rejects-stale-and-unknown-fields')
            # Exercise the frontend's asynchronous read-only request too.
            click(s, ipc, 'filters.tester')
            click(s, ipc, 'filters.sample.app_name'); type_text(s, 'Firefox')
            click(s, ipc, 'filters.sample.summary'); type_text(s, 'Download complete')
            click(s, ipc, 'filters.test')
            wait_for(lambda:'Blocked' in dialog_state(s, ipc)['test_result'])
            capture(s, 'native-tester', output['name'])
            passed('native-tester-displays-authoritative-match')
            apply_filters(s, ipc, peer)
            wait_for(lambda:not peer.state()['dirty'])
            id1 = notified(s,clients,app='Firefox',summary='Download complete',urgency=2,resident=True)
            wait_for(lambda:closed(s,id1,4))
            assert id1>0 and all(r['id']!=id1 for r in state(s,args.ctl)['notifications']['records'])
            sequence=records(s)
            received=next(i for i,v in enumerate(sequence) if v['kind']=='notification' and v['id']==id1)
            signal=next(i for i,v in enumerate(sequence) if v['kind']=='notification-signal' and v['signal']=='NotificationClosed' and v['args']==[id1,4])
            assert received<signal, sequence
            assert sum(v['kind']=='notification-signal' and v['signal']=='NotificationClosed' and v['args']==[id1,4] for v in sequence)==1
            normal = notified(s,clients,app='Firefox',summary='Meeting in 5 minutes')
            assert any(r['id']==normal for r in state(s,args.ctl)['notifications']['records'])
            assert notified(s,clients,app='Firefox',summary='Download complete',replaces=normal)==normal
            wait_for(lambda:closed(s,normal,4))
            assert all(r['id']!=normal for r in state(s,args.ctl)['notifications']['records'])
            passed('block-hides-critical-arrivals-and-active-replacements-with-one-directed-close')
            # Add History only through the native form.
            click(s, ipc, 'filters.add'); wait_for(lambda:dialog_state(s, ipc)['dialog'])
            type_text(s, 'Quiet software updates')
            dialog_click(s, ipc, 'filters.rule.action'); keys(s,'End','Return')
            dialog_click(s, ipc, 'filters.condition.0.value'); type_text(s, 'Software')
            dialog_click(s, ipc, 'filters.rule.save'); wait_for(lambda:not dialog_state(s, ipc)['dialog']); ready(s, ipc)
            added = json.loads(peer.document())['notifications']['rules']
            assert any(r['name']=='Quiet software updates' and r['action']=='history_only' and r['conditions'][0]['value']=='Software' for r in added), added
            apply_filters(s, ipc, peer)
            quiet = notified(s,clients,app='Software',summary='Ready to update',resident=True)
            row=next(r for r in state(s,args.ctl)['notifications']['records'] if r['id']==quiet)
            assert row['active'] and not row['toast'] and row['actions']==1, row
            action(s,args.ctl,'invoke',notification=quiet,text='default')
            wait_for(lambda:any(r['kind']=='notification-signal' and r['signal']=='ActionInvoked' and r['args']==[quiet,'default'] for r in records(s)))
            assert any(r['id']==quiet and r['active'] for r in state(s,args.ctl)['notifications']['records'])
            command(clients,close=quiet)
            wait_for(lambda:closed(s,quiet,3))
            transient = notified(s,clients,app='Software',transient=True,timeout=100)
            wait_for(lambda:closed(s,transient,1))
            assert all(r['id']!=transient for r in state(s,args.ctl)['notifications']['records'])
            passed('history-only-retains-actions-and-protocol-expiry')
            # Master switch stays a preference; DND remains immediate.
            click(s, ipc, 'filters.enabled'); ready(s, ipc)
            still_blocked = notified(s,clients,app='Firefox',summary='Download complete')
            wait_for(lambda:closed(s,still_blocked,4))
            click(s, ipc, 'discard'); ready(s, ipc)
            assert json.loads(peer.document())['notifications']['filters_enabled']
            click(s, ipc, 'filters.toggle.'+rid); ready(s, ipc)
            apply_filters(s, ipc, peer)
            unblocked = notified(s,clients,app='Firefox',summary='Download complete')
            assert any(r['id']==unblocked for r in state(s,args.ctl)['notifications']['records'])
            command(clients,close=unblocked)
            click(s, ipc, 'filters.toggle.'+rid); ready(s, ipc)
            apply_filters(s, ipc, peer)
            click(s, ipc, 'notifications/dnd')
            wait_for(lambda:state(s,args.ctl)['notifications']['dnd'])
            assert not peer.state()['dirty']
            passed('master-discard-individual-toggle-apply-and-immediate-dnd')
            # Dialog edits survive external changes but cannot overwrite them.
            click(s, ipc, 'filters.edit.'+rid); wait_for(lambda:dialog_state(s, ipc)['dialog'])
            type_text(s, 'Retained local name')
            concurrent = json.loads(peer.document())
            concurrent['notifications']['rules'][0]['name']='Changed elsewhere'
            peer.keep(json.dumps(concurrent))
            expected=hashlib.sha256(peer.document().encode()).hexdigest()
            wait_for(lambda:probe(s,ipc)['editor']['sha256']==expected)
            ready(s, ipc)
            dialog_click(s, ipc, 'filters.rule.save')
            wait_for(lambda:'changed elsewhere' in dialog_state(s, ipc)['error_text'])
            assert dialog_state(s, ipc)['dialog']
            keys(s,'Escape'); wait_for(lambda:not dialog_state(s, ipc)['dialog'])
            click(s, ipc, 'discard'); ready(s, ipc)
            passed('open-editor-conflict-retains-input-and-refuses-overwrite')
            click(s, ipc, 'filters.edit.'+rid); wait_for(lambda:dialog_state(s, ipc)['dialog'])
            dialog_click(s, ipc, 'filters.rule.delete'); ready(s, ipc)
            assert all(r['id']!=rid for r in json.loads(peer.document())['notifications']['rules'])
            click(s, ipc, 'discard'); ready(s, ipc)
            assert any(r['id']==rid for r in json.loads(peer.document())['notifications']['rules'])
            passed('delete-is-reversible-through-discard')
            # Exact Desktop ID, Unicode and overlap are exercised on real Notify.
            saved = json.loads(peer.document('committed'))
            extra = copy.deepcopy(saved)
            extra['notifications']['rules'] += [dict(id='unicode',name='Unicode identity',enabled=True,action='block',match='all',conditions=[dict(field='desktop_entry',operator='equals',value='org.example.Test.desktop',case_sensitive=True),dict(field='summary',operator='contains',value='STRASSE CAFÉ',case_sensitive=False)])]
            peer.keep(json.dumps(extra)); assert peer.action('apply')['state']=='succeeded'; ready(s, ipc)
            matched = notified(s,clients,app='Software',desktop_entry='org.example.Test',summary='Straße Cafe\u0301')
            wait_for(lambda:closed(s,matched,4))
            absent = notified(s,clients,app='Software',summary='Straße Café')
            assert any(r['id']==absent and not r['toast'] for r in state(s,args.ctl)['notifications']['records'])
            command(clients,close=absent)
            passed('desktop-hint-unicode-normalization-and-block-over-history-precedence')
            # Capture real themes and narrow layouts using existing presentation paths.
            for theme, variant in [('static','dark'),('static','light'),('gtk','light')]:
                candidate=copy.deepcopy(saved); candidate['theme'].update(mode=theme,variant=variant)
                peer.keep(json.dumps(candidate)); assert peer.action('apply')['state']=='succeeded'; ready(s,ipc)
                request(s,ipc,page='notifications'); ready(s,ipc)
                capture(s,'native-'+theme+'-'+variant,output['name'])
            for width in (560,390):
                resize(s,window_rules,width,780); ipc.call('command',action='session.reload',fields={}); ready(s,ipc)
                wait_for(lambda:probe(s,ipc)['width']==width)
                click(s,ipc,'filters.add'); wait_for(lambda:dialog_state(s,ipc)['dialog'])
                capture(s,'native-editor-'+str(width),output['name'])
                dialog_click(s,ipc,'filters.rule.save')
                assert dialog_state(s,ipc)['error_text']
                keys(s,'Escape'); wait_for(lambda:not dialog_state(s,ipc)['dialog'])
                capture(s,'native-'+str(width),output['name'])
            passed('dark-light-gtk-and-narrow-native-dialog-validation')
            resize(s,window_rules,560,500); ipc.call('command',action='session.reload',fields={})
            wait_for(lambda:probe(s,ipc)['height']==500)
            candidate=copy.deepcopy(saved); candidate['font']='Sans'; candidate['font_size']=20
            peer.keep(json.dumps(candidate)); assert peer.action('apply')['state']=='succeeded'; ready(s,ipc)
            click(s,ipc,'filters.edit.'+rid); wait_for(lambda:dialog_state(s,ipc)['dialog'])
            dialog_click(s,ipc,'filters.rule.cancel')
            wait_for(lambda:not dialog_state(s,ipc)['dialog'])
            wait_for(lambda:next(c for c in probe(s,ipc)['controls'] if c['field']=='filters.edit.'+rid)['focused'])
            capture(s,'native-large-text-short',output['name'])
            passed('large-text-short-window-editor-cancel-and-focus-restoration')
            peer.keep(json.dumps(saved)); assert peer.action('apply')['state']=='succeeded'; ready(s,ipc)
            path=Path(ctl(s,args.ctl,'preferences','status')['result']['path'])
            assert json.loads(path.read_text())['notifications']==saved['notifications']
            # External valid edits publish a new policy; malformed reloads retain it.
            changed=copy.deepcopy(saved)
            changed['notifications']['filters_enabled']=False
            temporary=path.with_suffix('.new')
            temporary.write_text(json.dumps(changed)); temporary.replace(path)
            wait_for(lambda:not peer.state()['busy'] and not json.loads(peer.document('committed'))['notifications']['filters_enabled'])
            external=notified(s,clients,app='Firefox',summary='Download complete')
            assert any(r['id']==external for r in state(s,args.ctl)['notifications']['records'])
            command(clients,close=external)
            temporary.write_text(json.dumps(saved)); temporary.replace(path)
            wait_for(lambda:not peer.state()['busy'] and json.loads(peer.document('committed'))['notifications']['filters_enabled'])
            temporary.write_text('{invalid json'); temporary.replace(path)
            wait_for(lambda:peer.state()['error_code'] is not None)
            retained=notified(s,clients,app='Firefox',summary='Download complete')
            wait_for(lambda:closed(s,retained,4))
            temporary.write_text(json.dumps(saved)); temporary.replace(path)
            wait_for(lambda:not peer.state()['busy'] and peer.state()['error_code'] is None)
            passed('external-reload-publishes-valid-rules-and-retains-policy-on-invalid-input')
            app.stop(); clean(app); peer.close()
            ctl(s,args.ctl,'quit'); clean(shell)
            shell=s.child('pearl-restarted',[args.pearl],G_DEBUG='fatal-warnings'); shell.expect('event=control-ready')
            wait_for(lambda:state(s,args.ctl)['notifications']['available'])
            after_restart=notified(s,clients,app='Firefox',summary='Download complete')
            wait_for(lambda:closed(s,after_restart,4))
            assert state(s,args.ctl)['notifications']['count']==0
            app=s.child('settings-reopened',[args.settings,'--page','notifications'],G_DEBUG='fatal-warnings'); app.expect('event=settings-window-created'); ready(s,ipc)
            passed('persisted-rules-active-before-first-arrival-after-restart')
            app.stop();clean(app);ctl(s,args.ctl,'quit');clean(shell)
            clients.stop()
            foreign=s.child('foreign-owner',['python3',FIX,'--conflict'],input_pipe=True); foreign.expect('event=ready')
            shell=s.child('pearl-with-foreign-owner',[args.pearl],G_DEBUG='fatal-warnings'); shell.expect('event=control-ready')
            peer=Peer(s,ipc); peer.enter('notifications'); wait_for(lambda:not peer.state()['busy'])
            assert not state(s,args.ctl)['notifications']['available']
            page=peer.page()['live']
            assert 'Filters apply when Pearl handles' in page['summary']
            assert all(not c['enabled'] for r in page['rows'] for c in r['controls'])
            app=s.child('settings-foreign-owner',[args.settings,'--page','notifications'],G_DEBUG='fatal-warnings'); app.expect('event=settings-window-created'); ready(s,ipc)
            click(s,ipc,'filters.add'); wait_for(lambda:dialog_state(s,ipc)['dialog'])
            dialog_click(s,ipc,'filters.rule.cancel'); wait_for(lambda:not dialog_state(s,ipc)['dialog'])
            capture(s,'native-foreign-owner',output['name'])
            foreign.stop()
            wait_for(lambda:state(s,args.ctl)['notifications']['available'])
            clients=s.child('clients-after-owner',['python3',FIX],input_pipe=True); clients.expect('event=ready')
            reclaimed=notified(s,clients,app='Firefox',summary='Download complete')
            wait_for(lambda:closed(s,reclaimed,4))
            assert state(s,args.ctl)['notifications']['count']==0
            passed('foreign-owner-keeps-preferences-editable-and-name-acquisition-retains-filters')
            app.stop(); clean(app); peer.close(); ctl(s,args.ctl,'quit'); clean(shell); ipc.close()
        report['status']='passed'
    except Exception as exc:
        report['status']='failed';report['error']=str(exc)
        raise
    finally:
        (args.output/'verification.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':
    main()
