#!/usr/bin/env python3
"""T11 replacement settings; all configuration and displays are private."""
import argparse, hashlib, json, os, sys, time, signal, shutil
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from test_surfaces import ctl, status, capture, clean
from test_session_services import key
from types import SimpleNamespace
from t00 import Session as T00Session

def state(s, b, field=None):
    return ctl(s, b, 'aqueous', 'status', *(['--text', field] if field else []))['result']
def settled(s, b, timeout=50):
    return wait_for(lambda: (lambda v: v if not v['busy'] else False)(state(s,b)), timeout)
def stage(s,b,**patch):
    v=state(s,b)
    request=dict(protocol=1, expected_generation=v['generation'], changes=[], raw_files={}, **patch) if 'changes' not in patch and 'raw_files' not in patch else dict(protocol=1, expected_generation=v['generation'], **patch)
    ctl(s,b,'aqueous','draft','--text',json.dumps(request))
    return request
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl',type=Path,required=True);parser.add_argument('--ctl',type=Path,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'artifacts/t11/latest');args=parser.parse_args()
    args.pearl=args.pearl.resolve();args.ctl=args.ctl.resolve();args.output=args.output.resolve();args.output.mkdir(parents=True,exist_ok=True)
    checks={};report=dict(status='running',checks=checks,pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(),ctl_sha256=hashlib.sha256(args.ctl.read_bytes()).hexdigest())
    try:
        with PrivateSession(args.output/'session') as s:
            # The helper's canonical layout vocabulary excludes the compositor's
            # legacy "floating" startup alias. Keep this fixture canonical.
            wm=Path(s.env['AQUEOUS_CONFIG']);wm.write_text(wm.read_text().replace('"floating"','"stacking"') + '\n[keybinds.custom]\n"Super+F12" = "spawn:touch ' + str(s.base/'shortcut-fired') + '"\n')
            s.env['GSETTINGS_BACKEND']='memory'
            s.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous');T00Session.input_fixture(s)
            snapshot=json.loads(s.run(['aqueous-config','snapshot','--shell','none']).stdout)
            (args.output/'schema.json').write_text(json.dumps(snapshot,indent=2)+'\n')
            fault=s.base/'fault';fault.write_text('')
            bin_dir=s.base/'bin';bin_dir.mkdir()
            for target,source in [('aqueous-config','aqueous_config.py'),('aqueousctl','aqueous_ctl.py')]:
                shutil.copyfile(ROOT/'tests/fixtures'/source,bin_dir/target);(bin_dir/target).chmod(0o700)
            calls=s.base/'helper-calls.jsonl'
            s.env.update(PATH=str(bin_dir)+':'+s.env['PATH'],PEARL_AQUEOUS_FAULT_FILE=str(fault),PEARL_AQUEOUS_CALLS=str(calls))
            app=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready')
            ctl(s,args.ctl,'session','action','--command','dnd_on')
            ctl(s,args.ctl,'aqueous','show');v=settled(s,args.ctl)
            assert v['fields']>=221 and v['err'] is None,v
            out=status(s,args.ctl)['outputs'][0];time.sleep(.5);capture(s,'aqueous-appearance-dark',out['connector'])
            checks['helper-discovery-schema-and-replacement-ui']=True
            prefs=ctl(s,args.ctl,'preferences','status')['result']
            for mode,variant,label in [('static','light','light'),('gtk','light','gtk'),('static','dark','dark-restored')]:
                prefs=wait_for(lambda:(lambda p:p if not p['busy'] else False)(ctl(s,args.ctl,'preferences','status')['result']))
                p=prefs['preferences'];p['theme'].update(mode=mode,variant=variant)
                ctl(s,args.ctl,'preferences','apply','--revision',str(prefs['revision']),'--text',json.dumps(p))
                wait_for(lambda:not ctl(s,args.ctl,'preferences','status')['result']['busy'])
                time.sleep(.25);capture(s,'aqueous-appearance-'+label,out['connector'])
            for page in ['layouts','input','rules','advanced']:
                ctl(s,args.ctl,'aqueous','show','--text',page);time.sleep(.2);capture(s,'aqueous-'+page,out['connector'])
            checks['replacement-pages-follow-material-and-native-gtk-themes']=True
            base=v['generation'];request=stage(s,args.ctl,changes=[dict(id='layout.gaps_outer',value=18)])
            ctl(s,args.ctl,'aqueous','validate');v=settled(s,args.ctl);assert v['outcome']=='validated' and v['generation']==base and v['draft'],v
            ctl(s,args.ctl,'popup','hide');assert state(s,args.ctl)['draft']
            ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl)
            assert v['outcome']=='saved' and not v['draft'] and v['generation']!=base and v['reload']=='applied',v
            assert state(s,args.ctl,'layout.gaps_outer')['value']==18
            checks['validate-retains-generation-and-apply-acknowledges-reload']=True
            stage(s,args.ctl,changes=[dict(id='layout.gaps_outer',value=99999)])
            ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['outcome']=='failed' and v['draft'],v
            assert state(s,args.ctl,'layout.gaps_outer')['value']==18
            checks['invalid-values-retain-draft-and-disk']=True
            ctl(s,args.ctl,'aqueous','discard')
            stage(s,args.ctl,changes=[dict(id='layout.gaps_outer',value=20)],raw_files={'layout':'[layout]\ngaps_outer=21\n'})
            ctl(s,args.ctl,'aqueous','validate');v=settled(s,args.ctl);assert v['err']=='ConflictingEdits' and v['draft'],v
            checks['raw-structured-overlap-rejected']=True
            ctl(s,args.ctl,'aqueous','discard')
            # Raw properties absent from the helper's projection cannot bypass protection.
            stage(s,args.ctl,raw_files={'outputs':'[[output]]\nname="'+out['connector']+'"\nenabled=false\n'})
            ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl)
            assert v['err']=='ProtectedDisplayPreviewRequired' and v['draft'] and not v['unresolved'],v
            ctl(s,args.ctl,'aqueous','discard')
            checks['raw-unprojected-display-fields-cannot-bypass-preview']=True
            stage(s,args.ctl,changes=[dict(id='layout.gaps_outer',value=22)])
            wm.write_text(wm.read_text()+'\n# external edit\n')
            ctl(s,args.ctl,'aqueous','refresh');v=settled(s,args.ctl);assert v['draft'] and v['conflict'],v
            assert ctl(s,args.ctl,'aqueous','apply',code=4)['ok'] is False
            checks['external-refresh-preserves-stale-draft']=True
            ctl(s,args.ctl,'aqueous','rebase');assert not state(s,args.ctl)['conflict']
            ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['outcome']=='saved',v
            checks['independent-draft-rebase']=True
            ctl(s,args.ctl,'aqueous','discard')
            ctl(s,args.ctl,'aqueous','show');time.sleep(.3)
            ctl(s,args.ctl,'aqueous','record','--text','spawn_terminal')
            wait_for(lambda:state(s,args.ctl)['recording'])
            key(s,'-M','logo','-k','F12','-m','logo')
            wait_for(lambda:not state(s,args.ctl)['recording']);assert state(s,args.ctl)['draft'];assert not (s.base/'shortcut-fired').exists()
            # Validation proves the recorded chord uses Aqueous's accepted syntax.
            ctl(s,args.ctl,'aqueous','validate');v=settled(s,args.ctl);assert v['outcome']=='validated',v
            ctl(s,args.ctl,'aqueous','record','--text','spawn_terminal');wait_for(lambda:state(s,args.ctl)['recording'])
            ctl(s,args.ctl,'popup','hide');assert not state(s,args.ctl)['recording']
            key(s,'-M','logo','-k','F12','-m','logo');wait_for(lambda:(s.base/'shortcut-fired').exists())
            checks['shortcut-recording-inhibition-and-popup-cleanup']=True
            ctl(s,args.ctl,'aqueous','discard')
            # A rejected apply is reconciled without replaying its write.
            before=state(s,args.ctl)['generation'];fault.write_text('reject')
            stage(s,args.ctl,changes=[dict(id='layout.gaps_outer',value=25)])
            ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl)
            assert v['outcome']=='failed' and v['draft'] and not v['unresolved'] and v['generation']==before,v
            checks['rejected-save-reconciles-with-unchanged-files']=True
            fault.write_text('lost');ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl)
            assert v['outcome']=='saved' and v['draft'] and v['reload']=='unknown' and v['toolkit']=='unknown',v
            assert state(s,args.ctl,'layout.gaps_outer')['value']==25
            checks['lost-apply-reply-readback-without-blind-retry']=True
            fault.write_text('');ctl(s,args.ctl,'aqueous','discard')
            fault.write_text('reload-failed');stage(s,args.ctl,changes=[dict(id='layout.gaps_outer',value=26)])
            ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['outcome']=='saved' and v['reload']=='failed',v
            fault.write_text('');ctl(s,args.ctl,'aqueous','reload');wait_for(lambda:state(s,args.ctl)['reload']=='applied')
            checks['reload-failure-does-not-undo-confirmed-save']=True
            fault.write_text('slow');stage(s,args.ctl,changes=[dict(id='layout.gaps_outer',value=27)])
            ctl(s,args.ctl,'aqueous','apply');assert state(s,args.ctl)['busy']
            stage(s,args.ctl,changes=[dict(id='layout.gaps_inner',value=6)])
            v=settled(s,args.ctl);assert v['draft'] and v['conflict'] and v['outcome']=='saved',v
            fault.write_text('');ctl(s,args.ctl,'aqueous','rebase');ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl)
            assert state(s,args.ctl,'layout.gaps_outer')['value']==27 and state(s,args.ctl,'layout.gaps_inner')['value']==6
            checks['concurrent-edit-retained-and-independent-rebase']=True
            # Another writer between validate and apply cannot be overwritten.
            fault.write_text('race');stage(s,args.ctl,changes=[dict(id='layout.gaps_outer',value=28)])
            ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['unresolved'] and v['draft'],v
            assert ctl(s,args.ctl,'aqueous','apply',code=4)['ok'] is False
            fault.write_text('');ctl(s,args.ctl,'aqueous','refresh');settled(s,args.ctl);ctl(s,args.ctl,'aqueous','rebase')
            ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['outcome']=='saved',v
            checks['uncertain-external-race-requires-refresh-and-explicit-review']=True
            # Native sync failure is separate from canonical save/reload.
            gtk4=Path(s.env['XDG_CONFIG_HOME'])/'gtk-4.0';gtk4.mkdir(exist_ok=True);(gtk4/'settings.ini').mkdir()
            stage(s,args.ctl,sync_typography=True)
            ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['outcome']=='saved' and v['toolkit']=='partial',v
            (gtk4/'settings.ini').rmdir()
            checks['toolkit-sync-failure-separated-from-save']=True
            # A raw edit in a non-display file preserves unknown fields/comments.
            raw=state(s,args.ctl,'raw:layout')['value']+'\n# Pearl keeps this comment\n[pearl_test_unknown]\nvalue="preserved"\n'
            stage(s,args.ctl,raw_files={'layout':raw})
            ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl)
            assert v['outcome']=='saved' and 'value="preserved"' in state(s,args.ctl,'raw:layout')['value'],v
            checks['raw-edit-preserves-unknown-settings-and-comments']=True
            before=state(s,args.ctl)['generation']
            stage(s,args.ctl,changes=[dict(id='layout.gaps_outer',value=29),dict(id='input.repeat_rate',value=40)])
            ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['outcome']=='saved',v
            backup=Path(s.env['XDG_STATE_HOME'])/'pearl/aqueous-backups'/before
            assert len(list(backup.glob('*.toml')))>=2
            checks['multi-file-apply-backs-up-original-generation']=True
            (args.output/'helper-calls.jsonl').write_text(calls.read_text())
            def displays(): return {v['name']:v for v in json.loads(s.run(['wlr-randr','--json']).stdout)}
            baseline=displays();name=out['connector'];target=baseline[name]
            def preview():
                settled(s,args.ctl)
                ctl(s,args.ctl,'aqueous','discard');ctl(s,args.ctl,'aqueous','refresh');settled(s,args.ctl)
                stage(s,args.ctl,monitor_changes=[dict(id='live:'+name,name=name,x=target['position']['x'],y=target['position']['y'],scale=1.25,transform='normal')])
                ctl(s,args.ctl,'aqueous','apply')
                def pending():
                    v=state(s,args.ctl)
                    assert v['busy'],v
                    return v['display_preview']=='pending'
                wait_for(pending,45)
            ctl(s,args.ctl,'aqueous','show','--text','displays')
            preview();assert displays()[name]['scale']==1.25
            time.sleep(.4);capture(s,'display-protected-preview',name)
            ctl(s,args.ctl,'aqueous','revert');v=settled(s,args.ctl);assert not v['unresolved'],v
            assert displays()[name]['scale']==target['scale'];checks['display-test-preview-explicit-revert']=True
            preview();started=time.monotonic();v=settled(s,args.ctl,25)
            assert time.monotonic()-started>=14 and displays()[name]['scale']==target['scale'],v
            checks['display-timeout-restores-without-canonical-save']=True
            preview();other=next(n for n in baseline if n!=name)
            s.run(['wlr-randr','--output',other,'--off']);v=settled(s,args.ctl)
            assert displays()[name]['scale']==target['scale'] and not displays()[other]['enabled'],v
            s.run(['wlr-randr','--output',other,'--on']);target=displays()[name]
            checks['output-removal-invalidates-lease-preserves-other-head-state']=True
            preview();wm.write_text(wm.read_text()+'\n# edited during preview\n')
            ctl(s,args.ctl,'aqueous','keep');v=settled(s,args.ctl)
            assert v['outcome']=='failed' and not v['unresolved'] and displays()[name]['scale']==target['scale'],v
            checks['competing-canonical-edit-before-keep-reverts-without-overwrite']=True
            preview();ctl(s,args.ctl,'aqueous','keep');v=settled(s,args.ctl);assert v['outcome']=='saved' and not v['draft'],v
            assert displays()[name]['scale']==1.25;checks['display-keep-persists-after-confirmation']=True
            # A competing live setting invalidates the lease and must survive rollback.
            target=displays()[name];target['scale']=1.25
            def candidate(scale):
                settled(s,args.ctl)
                ctl(s,args.ctl,'aqueous','discard');ctl(s,args.ctl,'aqueous','refresh');settled(s,args.ctl)
                monitors=state(s,args.ctl,'monitors')['value'];monitor=next(v for v in monitors if v['name']==name)
                stage(s,args.ctl,monitor_changes=[dict(id=monitor['id'],name=name,x=target['position']['x'],y=target['position']['y'],scale=scale,transform='normal')])
                ctl(s,args.ctl,'aqueous','apply');wait_for(lambda:state(s,args.ctl)['display_preview']=='pending',45)
            candidate(1.5);s.run(['wlr-randr','--output',name,'--scale','1.75']);v=settled(s,args.ctl)
            assert displays()[name]['scale']==1.75,v
            checks['competing-live-display-edit-survives-rollback']=True
            # UI death must not kill the guardian before it restores the baseline.
            candidate(1.5);os.kill(app.proc.pid,signal.SIGKILL);app.wait()
            wait_for(lambda:displays()[name]['scale']==1.75,8)
            assert not any(word in line for line in app.lines for word in ('CRITICAL','WARNING','panic:','General protection','Segmentation fault'))
            checks['ui-sigkill-independent-rollback']=True
        report['status']='passed'
    finally:
        (args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__': main()
