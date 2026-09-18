#!/usr/bin/env python3
"""Pinned master settings transactions on private buses and virtual displays."""
import argparse, hashlib, json, os, sys, time, shutil, signal, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from pearl_session import PrivateSession,wait_for
from test_surfaces import ctl,IPC,clean
from test_aqueous_settings import state,settled,stage

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--pearl',type=Path,default=ROOT/'zig-out/bin/pearl');p.add_argument('--ctl',type=Path,default=ROOT/'zig-out/bin/pearlctl');p.add_argument('--prefix',type=Path,default=ROOT/'.cache/aqueous-activity-production');p.add_argument('--output',type=Path,default=ROOT/'artifacts/aqueous-082/integration');args=p.parse_args();args.pearl=args.pearl.resolve();args.ctl=args.ctl.resolve();args.prefix=args.prefix.resolve();args.output=args.output.resolve();args.output.mkdir(parents=True,exist_ok=True)
 checks={};report=dict(status='running',checks=checks,pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(),baseline=json.loads((args.prefix/'metadata.json').read_text()))
 tools=tempfile.TemporaryDirectory(prefix='pearl-instance-tools-');tool_dir=Path(tools.name)
 shutil.copy2(args.prefix/'bin/aqueous',tool_dir/'aqueous')
 wrapper=tool_dir/'aqueous-config';shutil.copyfile(ROOT/'tests/fixtures/aqueous_master_helper.py',wrapper);wrapper.chmod(0o700)
 try:
  with PrivateSession(args.output/'session',tool_prefix=args.prefix,aqueous=tool_dir/'aqueous') as s:
   fault=s.base/'helper-fault';fault.write_text('')
   calls=s.base/'helper-calls.jsonl';bin_dir=s.base/'bin';bin_dir.mkdir()
   decoy=bin_dir/'aqueous-config';decoy.write_text('#!/bin/sh\nexit 99\n');decoy.chmod(0o700)
   s.env.update(PATH=str(bin_dir)+':'+s.env['PATH'],PEARL_MASTER_HELPER=str(args.prefix.resolve()/'bin/aqueous-config'),PEARL_MASTER_FAULT=str(fault),PEARL_MASTER_CALLS=str(calls))
   wrong=s.base/'wrong-config';wrong.mkdir();wrong_wm=wrong/'wm.toml';wrong_wm.write_text('[layout]\ngaps_outer = 97\n')
   app=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings',XDG_CONFIG_HOME=str(wrong),AQUEOUS_CONFIG=str(wrong_wm),AQUEOUS_LAYOUT=str(wrong/'layout.toml'),AQUEOUS_OUTPUTS=str(wrong/'outputs.toml'));app.expect('event=control-ready')
   ipc=IPC(s)
   ctl(s,args.ctl,'aqueous','refresh');v=settled(s,args.ctl);assert v['err'] is None,v
   assert v['helper']==str(wrapper),v
   files=state(s,args.ctl,'files')['value']
   assert files['wm']['path']==s.env['AQUEOUS_CONFIG'],files
   assert all(str(wrong) not in f['path'] for f in files.values()),files
   checks['helper-and-config-bound-to-compositor-despite-conflicting-pearl-environment']=True
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
   assert wrong_wm.read_text()=='[layout]\ngaps_outer = 97\n'
   assert not (wrong/'layout.toml').exists() and not (wrong/'outputs.toml').exists()
   assert state(s,args.ctl,'layout.gaps_outer')['value']==18
   checks['save-leaves-other-instance-config-untouched']=True
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
     ctl(s,args.ctl,'aqueous','refresh');v=settled(s,args.ctl);assert not v['unresolved'] and v['save']=='saved' and v['receipt']=='complete',v
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
    assert v['outcome']=='saved' and not v['unresolved'] and not v['draft'],(key,v)
    assert state(s,args.ctl,key)['value'],key
    ctl(s,args.ctl,'aqueous','discard')
   assert not (s.base/'must-not-run').exists();checks['protected-collections-save-and-roundtrip']=True
   stage(s,args.ctl,snap_zone_changes=[dict(id='a',x=0.9,y=0,width=0.5,height=1)])
   ctl(s,args.ctl,'aqueous','validate');v=settled(s,args.ctl);assert v['err'] and v['draft'],v
   ctl(s,args.ctl,'aqueous','discard');checks['invalid-snap-geometry-rejected']=True
   # Opaque display IDs/source tokens survive a full structured Keep round trip.
   def display_save(operations, **mixed):
    tokens=state(s,args.ctl,'display_source_ids')['value']
    stage(s,args.ctl,display_declaration_changes=dict(version=1,sources={op['source']:tokens[op['source']] for op in operations},operations=operations),**mixed)
    ctl(s,args.ctl,'aqueous','apply')
    v=wait_for(lambda:(lambda v:v if v['display_preview']=='pending' or not v['busy'] else False)(state(s,args.ctl)),15)
    if v['display_preview']=='pending':ctl(s,args.ctl,'aqueous','keep');v=settled(s,args.ctl)
    assert v['outcome']=='saved' and not v['unresolved'],v
   display_save([
    dict(op='add',source='outputs',kind='profile',ref='desk',set=dict(name='pearl-desk')),
    dict(op='add',source='outputs',kind='output',parent='new:desk',set=dict(name='PEARL-OFFLINE',enabled=False,scale=1.25,primary=False))],
    window_rule_changes=[dict(op='add',values=dict(app_id='pearl-mixed-*',floating=True))])
   def declaration(kind):return next(d for d in state(s,args.ctl,'display_declarations')['value'] if d['kind']==kind)
   member=declaration('member')
   display_save([dict(op='update',source='outputs',id=member['id'],set=dict(primary=False,position=[-100,20]),unset=['scale'])])
   text=state(s,args.ctl,'raw:outputs')['value'];assert "PEARL-OFFLINE" in text and 'position' in text,text
   member=declaration('member')
   display_save([dict(op='move',source='outputs',id=member['id'],parent=None)])
   profile=declaration('profile')
   display_save([dict(op='update',source='outputs',id=profile['id'],set=dict(name='pearl-renamed'))])
   profile=declaration('profile')
   display_save([dict(op='delete',source='outputs',id=profile['id'],members='delete')])
   assert not any(d['kind']=='profile' for d in state(s,args.ctl,'display_declarations')['value'])
   checks['structured-display-profile-member-inheritance-move-delete-and-mixed-save']=True
   tokens=state(s,args.ctl,'display_source_ids')['value']
   stage(s,args.ctl,display_declaration_changes=dict(version=1,sources={'outputs':tokens['outputs']},operations=[dict(op='add',source='outputs',kind='output',parent=None,set=dict(name='PEARL-CAPABILITY-TEST'))]))
   fault.write_text('missing-display-capability');ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl)
   assert v['err']=='DisplayMutationCapabilityUnavailable' and not v['unresolved'],v
   fault.write_text('');ctl(s,args.ctl,'aqueous','discard');checks['display-mutations-require-fresh-negotiated-capability']=True
   # A previously reviewed full digest cannot be silently replaced after an external edit.
   stage(s,args.ctl,window_rule_changes=[dict(op='add',values=dict(app_id='pearl-reviewed-*',floating=True))])
   ctl(s,args.ctl,'aqueous','validate');assert settled(s,args.ctl)['outcome']=='validated'
   input_file=Path(s.env['XDG_CONFIG_HOME'])/'aqueous/input.toml';input_file.write_text('# new candidate baseline\n')
   ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['err']=='CandidateReviewChanged' and not v['unresolved'],v
   ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['outcome']=='saved',v
   checks['changed-reviewed-digest-requires-explicit-second-apply']=True
   # Unrelated source changes may rebase collection IDs; touched-source changes may not.
   stage(s,args.ctl,window_rule_changes=[dict(op='add',values=dict(app_id='pearl-rebased-*',floating=True))])
   input_file=Path(s.env['XDG_CONFIG_HOME'])/'aqueous/input.toml';input_file.write_text('# unrelated input source edit\n')
   ctl(s,args.ctl,'aqueous','refresh');settled(s,args.ctl)
   assert state(s,args.ctl)['conflict']
   ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['outcome']=='saved',v
   stage(s,args.ctl,window_rule_changes=[dict(op='add',values=dict(app_id='must-conflict',floating=True))])
   rules_file=Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml';rules_file.write_text(rules_file.read_text()+'\n# competing source edit\n')
   ctl(s,args.ctl,'aqueous','apply');v=settled(s,args.ctl);assert v['err'] and v['draft'] and not v['unresolved'],v
   ctl(s,args.ctl,'aqueous','refresh');settled(s,args.ctl);ctl(s,args.ctl,'aqueous','discard')
   checks['collection-rebase-only-for-untouched-source']=True
   s.run(['aqueousctl','session','reload','--json'])
   wait_for(lambda:ipc.call('display.snapshot')['config_generation']==state(s,args.ctl)['generation'])
   # Unconfirmed owner destruction must roll back without writing.
   output=ipc.call('display.snapshot')['outputs'][0];before=output['actual'];connector=output['connector'];gen=state(s,args.ctl)['generation']
   declaration=next(d for d in state(s,args.ctl,'display_declarations')['value'] if any(connector in e['raw'] for e in d['entries'] if e['key']=='name'))
   tokens=state(s,args.ctl,'display_source_ids')['value']
   stage(s,args.ctl,display_declaration_changes=dict(version=1,sources={declaration['source']:tokens[declaration['source']]},operations=[dict(op='update',source=declaration['source'],id=declaration['id'],set=dict(position=[250,40]))]))
   ctl(s,args.ctl,'aqueous','apply');v=wait_for(lambda:(lambda v:v if v['display_preview']=='pending' or not v['busy'] else False)(state(s,args.ctl)),15);assert v['display_preview']=='pending',v
   app.proc.kill();app.proc.wait(timeout=10)
   wait_for(lambda:ipc.call('display.snapshot')['outputs'][0]['actual']==before)
   app=s.child('pearl-after-preview-crash',[args.pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready');ctl(s,args.ctl,'aqueous','refresh');v=settled(s,args.ctl);assert v['generation']==gen and not v['unresolved'],v
   checks['owner-crash-rolls-back-without-persistence']=True
   ipc.close();ctl(s,args.ctl,'quit');app.proc.wait(timeout=10);clean(app)
  report['status']='passed'
 except Exception as e:report.update(status='failed',error=str(e));raise
 finally:
  tools.cleanup()
  (args.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report,indent=2))
if __name__=='__main__':main()
