#!/usr/bin/env python3
"""Native plugin review, discovery, filtering and responsive layout in private XDG roots."""
import argparse
import json
import shutil
import time
from pathlib import Path
from test_settings_app import ROOT, PrivateSession, IPC, ctl, wait_for, probe, capture, clean, keys, resize, windows
from test_settings_appearance import click, ready, type_text
from test_settings_services import Peer
from test_plugin_host import digest
from pearl_session import fixture_prefix


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('settings', 'pearl', 'ctl'):
        parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--examples', type=Path, default=ROOT/'.cache/plugin-examples')
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/plugins-layout/native')
    args = parser.parse_args()
    for name, value in vars(args).items():
        if isinstance(value, Path): setattr(args, name, value.resolve())
    report = {'status':'running', 'checks':[], 'captures':[]}
    args.output.mkdir(parents=True, exist_ok=True)
    try:
        with PrivateSession(args.output/'session', tool_prefix=fixture_prefix()) as s:
            s.env['GSETTINGS_BACKEND'] = 'memory'
            s.env['PEARL_SECURITY_LOG'] = str(s.output/'security.jsonl')
            s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path='+str(s.runtime/'system-bus')
            s.child('system-bus', ['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda: s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
            s.child('authority', ['python3',ROOT/'tests/fixtures/session_security.py'], input_pipe=True).expect('event=ready')
            packages = Path(s.env['XDG_DATA_HOME'])/'pearl/plugins'
            packages.mkdir(parents=True)
            for name in ('companion-c','timer-c','counter-zig','counter-rust'):
                shutil.copytree(args.examples/name, packages/name)
            for name in ('zz-one','zz-two'):
                target=packages/name
                shutil.copytree(args.examples/'counter-zig', target)
                manifest=json.loads((target/'plugin.json').read_text())
                manifest.update(id='pearl.'+name, name='Extra '+name)
                (target/'plugin.json').write_text(json.dumps(manifest))
            config=Path(s.env['XDG_CONFIG_HOME'])/'pearl/preferences.json'
            config.parent.mkdir(exist_ok=True);config.write_text('{}')
            ipc=IPC(s)
            output=next(iter(ipc.outputs().values()))
            s.run(['wlr-randr','--output',output['name'],'--custom-mode','1600x1100@60Hz'])
            rules=Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
            resize(s,rules,1200,960);ipc.call('command',action='session.reload',fields={})
            shell=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
            app=s.child('settings',[args.settings,'--page','plugins'],G_DEBUG='fatal-warnings');app.expect('event=settings-window-created')
            ready(s,ipc)
            peer=Peer(s,ipc);peer.enter('plugins')
            def state(): return probe(s,ipc)['plugins']
            def control(field): return next(c for c in probe(s,ipc)['controls'] if c['field']==field)
            def doc(): return json.loads(peer.document())
            def entry(id): return next(c for c in doc().get('plugins',{}).get('entries',[]) if c['id']==id)
            def wait_draft(): wait_for(lambda: peer.state()['dirty']);ready(s,ipc)
            def modal_action(field):
                wait_for(lambda: state()['review'])
                for _ in range(40):
                    if next(c for c in state()['controls'] if c['field']==field)['focused']: break
                    keys(s,'Tab')
                else: raise AssertionError('Could not focus '+field)
                keys(s,'space')
            def shot(name):
                time.sleep(.4);capture(s,name,output['name'])
                report['captures'].append('session/'+name+'.png')
            wait_for(lambda: len(state()['rows'])==4)
            assert all(not r['expanded'] for r in state()['rows'])
            assert not control('pearl.counter-zig/enabled')['enabled']
            shot('dark')
            report['checks'].append('collapsed-cards-and-approval-gate')

            before=peer.document()
            click(s,ipc,'pearl.counter-zig/approve')
            wait_for(lambda:state()['review']);shot('review')
            keys(s,'Escape');wait_for(lambda:not state()['review'])
            assert peer.document()==before
            assert control('pearl.counter-zig/approve')['focused']
            report['checks'].append('review-cancel-does-not-edit-and-restores-focus')
            click(s,ipc,'pearl.companion/approve')
            assert not next(c for c in state()['controls'] if c['field']=='plugins.review.activity')['selected']
            modal_action('plugins.review.activity')
            modal_action('plugins.review.overlay')
            modal_action('plugins.review.save')
            wait_for(lambda:not state()['review']);wait_draft()
            cat=entry('pearl.companion')
            assert cat['digest']==digest(packages/'companion-c') and not cat['enabled']
            assert cat['grants']['input_activity'] and cat['grants']['overlay']
            assert not json.loads(config.read_text()).get('plugins',{}).get('entries',[])
            peer.action('discard');ready(s,ipc)
            assert peer.document()==before
            report['checks'].append('review-stages-exact-fingerprint-and-grants-without-enabling-or-writing')

            click(s,ipc,'pearl.counter-zig/approve');modal_action('plugins.review.save')
            wait_for(lambda:not state()['review']);wait_draft()
            click(s,ipc,'pearl.counter-zig/enabled');wait_draft()
            assert entry('pearl.counter-zig')['enabled']
            assert 'plugin:pearl.counter-zig/main' in doc()['bar']['groups']['right']
            peer.action('apply');ready(s,ipc)
            assert next(c for c in json.loads(config.read_text())['plugins']['entries'] if c['id']=='pearl.counter-zig')['enabled']
            report['checks'].append('approval-enable-and-apply-preserve-native-bar-placement')

            before=peer.document()
            click(s,ipc,'plugins.search');type_text(s,'COUNTer (ZIG)')
            wait_for(lambda:len([r for r in state()['rows'] if r['visible']])==1)
            assert next(r for r in state()['rows'] if r['visible'])['id']=='pearl.counter-zig'
            type_text(s,'no-match');wait_for(lambda:not any(r['visible'] for r in state()['rows']))
            type_text(s,'')
            # Ctrl+A followed by Backspace clears with actual input events.
            keys(s,'BackSpace');wait_for(lambda:all(r['visible'] for r in state()['rows']))
            assert peer.document()==before
            click(s,ipc,'plugins.filter');keys(s,'Home','Down','Return')
            wait_for(lambda:len([r for r in state()['rows'] if r['visible']])==1)
            assert next(r for r in state()['rows'] if r['visible'])['id']=='pearl.counter-zig'
            click(s,ipc,'plugins.filter');keys(s,'End','Return')
            wait_for(lambda:all(r['visible']==bool(r['notice']) for r in state()['rows']))
            click(s,ipc,'plugins.filter');keys(s,'Home','Return')
            wait_for(lambda:all(r['visible'] for r in state()['rows']))
            assert peer.document()==before
            report['checks'].append('enabled-and-attention-filters-preserve-draft')
            click(s,ipc,'plugins.next');ready(s,ipc)
            wait_for(lambda:len(state()['rows'])==2)
            assert all(r['id'].startswith('pearl.zz-') for r in state()['rows'])
            click(s,ipc,'plugins.previous');ready(s,ipc)
            wait_for(lambda:len(state()['rows'])==4)
            report['checks'].append('case-insensitive-page-search-empty-results-and-pagination')

            click(s,ipc,'pearl.companion/approve')
            modal_action('plugins.review.activity');modal_action('plugins.review.overlay')
            modal_action('plugins.review.save');wait_for(lambda:not state()['review']);wait_draft()
            peer.action('apply');ready(s,ipc)
            assert entry('pearl.companion')['grants']['input_activity'] and entry('pearl.companion')['grants']['overlay']
            click(s,ipc,'pearl.companion/approve')
            wait_for(lambda:state()['review'])
            manifest_path=packages/'companion-c/plugin.json'
            manifest=json.loads(manifest_path.read_text());manifest['version']='0.2.0'
            manifest_path.write_text(json.dumps(manifest))
            ctl(s,args.ctl,'plugins','refresh')
            wait_for(lambda:not state()['review'],20)
            ready(s,ipc)
            click(s,ipc,'pearl.companion/approve')
            wait_for(lambda:state()['review'])
            assert not next(c for c in state()['controls'] if c['field']=='plugins.review.activity')['selected']
            assert not next(c for c in state()['controls'] if c['field']=='plugins.review.overlay')['selected']
            keys(s,'Escape')
            click(s,ipc,'pearl.companion/expand')
            click(s,ipc,'pearl.companion/activity');wait_draft()
            peer.action('discard');ready(s,ipc)
            click(s,ipc,'pearl.companion/approve');wait_for(lambda:state()['review'])
            assert not next(c for c in state()['controls'] if c['field']=='plugins.review.activity')['selected']
            assert not next(c for c in state()['controls'] if c['field']=='plugins.review.overlay')['selected']
            keys(s,'Escape')
            click(s,ipc,'pearl.companion/expand')
            report['checks'].append('package-replacement-closes-stale-review-and-resets-grants')
            report['checks'].append('discard-does-not-reuse-old-package-permissions')

            # Keep an expanded, focused sibling while another package changes.
            click(s,ipc,'pearl.counter-rust/expand')
            before=peer.document()
            manifest_path=packages/'timer-c/plugin.json';manifest=json.loads(manifest_path.read_text());manifest['version']='0.2.0'
            manifest_path.write_text(json.dumps(manifest));ctl(s,args.ctl,'plugins','refresh')
            time.sleep(1);ready(s,ipc)
            assert next(r for r in state()['rows'] if r['id']=='pearl.counter-rust')['expanded']
            assert peer.document()==before
            report['checks'].append('unrelated-row-expansion-and-draft-survive-discovery')

            invalid=packages/'invalid';invalid.mkdir();(invalid/'plugin.json').write_text('{')
            ctl(s,args.ctl,'plugins','refresh')
            wait_for(lambda:state()['discovery_issue'],20)
            assert 'rejected' in state()['discovery_issue']
            shutil.rmtree(invalid);ctl(s,args.ctl,'plugins','refresh')
            wait_for(lambda:not state()['discovery_issue'],20)
            report['checks'].append('discovery-errors-visible-without-expanding-diagnostics')

            shutil.rmtree(packages/'counter-zig');ctl(s,args.ctl,'plugins','refresh')
            wait_for(lambda:'missing' in next(r for r in state()['rows'] if r['id']=='pearl.counter-zig')['notice'].lower(),20)
            ready(s,ipc);click(s,ipc,'pearl.counter-zig/enabled');wait_draft()
            assert not entry('pearl.counter-zig')['enabled']
            peer.action('apply');ready(s,ipc)
            report['checks'].append('missing-package-retains-preferences-and-can-be-disabled')

            for theme,width,height,name in [('light',1200,960,'light'),('dark',560,850,'narrow'),('dark',390,720,'compact')]:
                document=doc();document.setdefault('theme',{})['variant']=theme
                peer.keep(json.dumps(document));peer.action('apply');ready(s,ipc)
                resize(s,rules,width,height);ipc.call('command',action='session.reload',fields={})
                wait_for(lambda:abs(probe(s,ipc)['width']-width)<=2)
                click(s,ipc,'plugins.search')
                v=probe(s,ipc);body=v['body_bounds']
                for field in ('plugins.search','plugins.filter'):
                    box=control(field)['bounds'];assert box['x']>=body['x']-1 and box['x']+box['width']<=body['x']+body['width']+1,(field,box,body)
                assert v['footer_bounds']['y']+v['footer_bounds']['height']<=v['height']+1
                shot(name)
            report['checks'].append('dark-light-560-390-layout-and-reachable-footer')
            click(s,ipc,'pearl.companion/approve');wait_for(lambda:state()['review']);shot('compact-review')
            modal_action('plugins.review.cancel');wait_for(lambda:not state()['review'])
            report['checks'].append('compact-review-keyboard-actions')
            peer.close();ctl(s,args.ctl,'quit');clean(shell);app.signal();app.wait(timeout=5);ipc.close()
            assert not any('WARNING' in line or 'CRITICAL' in line for line in app.lines)
            report['checks'].append('no-gtk-warnings-or-criticals')
        report['status']='passed'
    finally:
        (args.output/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__': main()
