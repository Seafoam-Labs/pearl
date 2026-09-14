#!/usr/bin/env python3
"""Pinned master settings transactions on private buses and virtual displays."""
import argparse, hashlib, json, os, sys, time, shutil, signal
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from pearl_session import PrivateSession,wait_for
from test_surfaces import ctl,IPC,clean
from test_aqueous_settings import state,settled,stage

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--pearl',type=Path,default=ROOT/'zig-out/bin/pearl');p.add_argument('--ctl',type=Path,default=ROOT/'zig-out/bin/pearlctl');p.add_argument('--prefix',type=Path,default=ROOT/'.cache/aqueous-master');p.add_argument('--output',type=Path,default=ROOT/'artifacts/aqueous-master/integration');args=p.parse_args();args.pearl=args.pearl.resolve();args.ctl=args.ctl.resolve();args.prefix=args.prefix.resolve();args.output=args.output.resolve();args.output.mkdir(parents=True,exist_ok=True)
 checks={};report=dict(status='running',checks=checks,pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(),baseline=json.loads((args.prefix/'metadata.json').read_text()))
 try:
  with PrivateSession(args.output/'session',tool_prefix=args.prefix) as s:
   fault=s.base/'helper-fault';fault.write_text('')
   calls=s.base/'helper-calls.jsonl';bin_dir=s.base/'bin';bin_dir.mkdir()
   wrapper=bin_dir/'aqueous-config';shutil.copyfile(ROOT/'tests/fixtures/aqueous_master_helper.py',wrapper);wrapper.chmod(0o700)
   s.env.update(PATH=str(bin_dir)+':'+s.env['PATH'],PEARL_MASTER_HELPER=str(args.prefix.resolve()/'bin/aqueous-config'),PEARL_MASTER_FAULT=str(fault),PEARL_MASTER_CALLS=str(calls))
   app=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready')
   ipc=IPC(s)
   ctl(s,args.ctl,'aqueous','show');v=settled(s,args.ctl);assert v['err'] is None,v
   assert v['capabilities']['apply'] and v['capabilities']['display'],v
   checks['matching-toolchain-negotiation']=True
   # Exercise the new bounded CLI entry point against authoritative IPC state.
   ws=next(e for e in ipc.state() if e['kind']=='workspace')
   ctl(s,args.ctl,'wm','action','--text',json.dumps(dict(workspace_rename=dict(id=ws['id'],name='Master test'))))
   wait_for(lambda:any(e['kind']=='workspace' and e['id']==ws['id'] and e['name']=='Master test' for e in ipc.state()))
   assert not ctl(s,args.ctl,'wm','action','--text',json.dumps(dict(window_fullscreen=dict(id='unknown',value=True))),code=4)['ok']
   assert not ctl(s,args.ctl,'wm','action','--text',json.dumps(dict(session_exit={})),code=4)['ok']
   checks['typed-cli-action-and-stale-target-rejection']=True
   generation=v['generation'];stage(s,args.ctl,changes=[dict(id='layout.gaps_outer',value=18)])
   ctl(s,args.ctl,'aqueous','validate');v=settled(s,args.ctl);assert v['outcome']=='validated' and v['generation']==generation,v
   review=state(s,args.ctl,'review')['value'];assert review['complete'] and review['effects']==['runtime_non_display'],review
   ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['outcome']=='saved' and v['reload']=='applied' and not v['unresolved'],v
   result=state(s,args.ctl,'operation')['value'];assert result['receipt']=='complete' and result['save']=='saved',result
   checks['structured-runtime-save-and-review']=True
   record=Path(s.env['XDG_STATE_HOME'])/'pearl/aqueous-operations/pending.json';assert json.loads(record.read_text())['pending'] is False
   checks['durable-pending-record-resolved']=True
   # A semantic no-change can still carry a comment which must be persisted.
   comments=state(s,args.ctl,'raw_files')['value']['outputs']+'\n# Pearl preserves comments\n'
   stage(s,args.ctl,raw_files={'outputs':comments})
   ctl(s,args.ctl,'aqueous','validate');assert settled(s,args.ctl)['outcome']=='validated'
   ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['outcome']=='saved' and not v['unresolved'],v
   assert state(s,args.ctl,'raw_files')['value']['outputs']==comments
   checks['comments-only-candidate-persists-through-structured-apply']=True
   output=ipc.call('display.snapshot')['outputs'][0];before=output['actual'];connector=output['connector']
   stage(s,args.ctl,monitor_changes=[dict(id='live:'+connector,name=connector,x=100,y=20,scale=1,transform='normal')])
   ctl(s,args.ctl,'aqueous','apply');v=wait_for(lambda:(lambda v:v if v['display_preview']=='pending' or not v['busy'] else False)(state(s,args.ctl)),15);assert v['display_preview']=='pending',v
   ctl(s,args.ctl,'aqueous','revert');v=settled(s,args.ctl);assert v['outcome']=='reverted' and v['draft'],v
   wait_for(lambda:ipc.call('display.snapshot')['outputs'][0]['actual']==before)
   checks['native-preview-revert-no-persistence']=True
   ctl(s,args.ctl,'aqueous','apply');v=wait_for(lambda:(lambda v:v if v['display_preview']=='pending' or not v['busy'] else False)(state(s,args.ctl)),15);assert v['display_preview']=='pending',v
   ctl(s,args.ctl,'aqueous','keep');v=settled(s,args.ctl);assert v['outcome']=='saved' and not v['draft'] and not v['unresolved'],v
   result=state(s,args.ctl,'operation')['value'];assert result['display']=='kept' and result['receipt']=='complete',result
   checks['native-keep-durable-receipt']=True
   stage(s,args.ctl,raw_files={'outputs':'[unexpected]\nunknown=1\n'})
   ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['err']=='UnclassifiedCandidate' and not v['unresolved'],v
   checks['incomplete-impact-blocks-raw-save']=True
   ctl(s,args.ctl,'aqueous','discard')
   stage(s,args.ctl,raw_files={'outputs':'[[output]]\nname='+json.dumps(connector)+'\nhdr=true\n'})
   ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['err'] is not None and not v['unresolved'] and v['draft'],v
   checks['hardware-only-color-change-gated']=True
   ctl(s,args.ctl,'aqueous','discard')
   for failure,expected in [('missing-capability','HelperUpgradeRequired'),('wrong-impact-version','UnsupportedContractVersion'),('wrong-digest','CandidateMismatch'),('unknown-effect','UnclassifiedCandidate')]:
    stage(s,args.ctl,changes=[dict(id='layout.gaps_outer',value=24)])
    fault.write_text(failure);ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['err']==expected and not v['unresolved'],v
    ctl(s,args.ctl,'aqueous','discard')
   fault.write_text('');checks['capability-version-digest-and-additive-effect-gates']=True
   for failure,value in [('lost',25),('lost-and-unqueryable',26)]:
    count=lambda:sum(json.loads(line)['op']=='apply' for line in calls.read_text().splitlines())
    before_count=count();stage(s,args.ctl,changes=[dict(id='layout.gaps_outer',value=value)])
    fault.write_text(failure);ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert count()==before_count+1,v
    if failure=='lost':assert v['outcome']=='saved' and v['reload']=='applied' and not v['unresolved'],v
    else:
     assert v['unresolved'] and json.loads(record.read_text())['pending'],v
     ctl(s,args.ctl,'aqueous','discard');assert not ctl(s,args.ctl,'aqueous','reload',code=4)['ok']
     ctl(s,args.ctl,'quit');app.proc.wait(timeout=10);clean(app)
     fault.write_text('');app=s.child('pearl-recovery',[args.pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready')
     ctl(s,args.ctl,'aqueous','show');v=settled(s,args.ctl);assert not v['unresolved'] and v['save']=='saved' and v['receipt']=='complete',v
     assert count()==before_count+1 and json.loads(record.read_text())['pending'] is False
   fault.write_text('');checks['lost-apply-reply-queries-receipt-without-second-write']=True;checks['restart-reconciles-pending-operation']=True
   for failure,value in [('nonzero-saved',27),('saved-no-snapshot',28),('lost-recovered',29)]:
    stage(s,args.ctl,changes=[dict(id='layout.gaps_outer',value=value)]);fault.write_text(failure)
    ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['outcome']=='saved' and not v['unresolved'],v
    if failure=='nonzero-saved':assert v['reload']=='failed' and v['err']=='HelperRejected',v
    elif failure=='saved-no-snapshot':assert v['draft'],v
    else:assert v['draft'] and v['receipt']=='recovered' and v['reload']=='unknown' and v['toolkit']=='unknown',v
    fault.write_text('');ctl(s,args.ctl,'aqueous','refresh');settled(s,args.ctl);ctl(s,args.ctl,'aqueous','discard')
   checks['nonzero-structured-save-preserves-independent-reload-failure']=True
   checks['missing-snapshot-retains-draft-and-recovered-effects-remain-unknown']=True
   generation=state(s,args.ctl)['generation'];before_count=count()
   stage(s,args.ctl,changes=[dict(id='layout.gaps_outer',value=30)]);fault.write_text('early-failure')
   ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl)
   assert v['outcome']=='failed' and v['err']=='HelperRejected' and v['draft'] and not v['unresolved'],v
   result=state(s,args.ctl,'operation')['value']
   assert result['save']=='failed' and result['receipt']=='complete' and result['before_generation'] is None and result['candidate_digest'] is None,result
   assert v['generation']==generation and count()==before_count+1 and not json.loads(record.read_text())['pending']
   fault.write_text('');ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl)
   assert v['outcome']=='saved' and not v['unresolved'] and count()==before_count+2,v
   checks['durable-early-rejection-resolves-pending-and-allows-explicit-retry']=True
   # Rules, shortcuts and named/legacy zones all use the same protected pipeline.
   for patch,key in [
    (dict(window_rule_changes=[dict(op='add',values=dict(app_id='pearl-test-*',floating=False,opacity=0.8))]),'window_rules'),
    (dict(custom_keybind_changes=[dict(op='add',chord='Super+F12',command='spawn:touch '+str(s.base/'must-not-run'))]),'custom_keybinds'),
    (dict(snap_layouts=[dict(id='halves',name='Halves',padding=4,zones=[dict(id='left',x=0,y=0,width=0.5,height=1),dict(id='right',x=0.5,y=0,width=0.5,height=1)])],default_snap_layout='halves'),'snap_layouts'),
    (dict(snap_zone_changes=[dict(id='a',x=0,y=0,width=0.5,height=1)]),'snap_zones')]:
    stage(s,args.ctl,**patch);ctl(s,args.ctl,'aqueous','validate');v=settled(s,args.ctl);assert v['outcome']=='validated', (key,v)
    ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl)
    # Master's classifier has no collection schema coverage yet. Never bypass unknown.
    assert v['err']=='UnclassifiedCandidate' and not v['unresolved'] and v['draft'],(key,v)
    ctl(s,args.ctl,'aqueous','discard')
   assert not (s.base/'must-not-run').exists();checks['structured-collections-validate-but-unclassified-save-is-gated']=True
   stage(s,args.ctl,snap_zone_changes=[dict(id='a',x=0.9,y=0,width=0.5,height=1)])
   ctl(s,args.ctl,'aqueous','validate');v=settled(s,args.ctl);assert v['err'] and v['draft'],v
   ctl(s,args.ctl,'aqueous','discard');checks['invalid-snap-geometry-rejected']=True
   # Unconfirmed owner destruction must roll back without writing.
   output=ipc.call('display.snapshot')['outputs'][0];before=output['actual'];connector=output['connector'];gen=state(s,args.ctl)['generation']
   stage(s,args.ctl,monitor_changes=[dict(id='live:'+connector,name=connector,x=250,y=40,scale=1,transform='normal')])
   ctl(s,args.ctl,'aqueous','apply');wait_for(lambda:state(s,args.ctl)['display_preview']=='pending',15)
   app.proc.kill();app.proc.wait(timeout=10)
   wait_for(lambda:ipc.call('display.snapshot')['outputs'][0]['actual']==before)
   app=s.child('pearl-after-preview-crash',[args.pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready');ctl(s,args.ctl,'aqueous','show');v=settled(s,args.ctl);assert v['generation']==gen and not v['unresolved'],v
   checks['owner-crash-rolls-back-without-persistence']=True
   ipc.close();ctl(s,args.ctl,'quit');app.proc.wait(timeout=10);clean(app)
  report['status']='passed'
 except Exception as e:report.update(status='failed',error=str(e));raise
 finally:(args.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report,indent=2))
if __name__=='__main__':main()
