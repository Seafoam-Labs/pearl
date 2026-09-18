#!/usr/bin/env python3
"""Capture pinned master contracts in private sessions; no host configuration writes."""
import argparse,hashlib,json,re,sys,time,xml.etree.ElementTree as ET
from pathlib import Path
from pearl_session import PrivateSession,wait_for
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tests/integration'))
from test_surfaces import IPC
class CapturedIPC(IPC):
 def call(self,op,**params):
  value=super().call(op,**params)
  if op=='hello':self.hello=value
  return value
from aqueous_target import REV
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--prefix',type=Path,default=ROOT/'.cache/aqueous-activity-production');p.add_argument('--output',type=Path,default=ROOT/'artifacts/aqueous-082/contracts');a=p.parse_args();a.prefix=a.prefix.resolve();a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)
 meta=json.loads((a.prefix/'metadata.json').read_text());assert meta['status']=='passed' and meta['revision']==REV
 source=a.prefix/'source';fixtures=ROOT/'tests/fixtures/aqueous-master';fixtures.mkdir(parents=True,exist_ok=True)
 def save(name,v):
  (a.output/(name+'.json')).write_text(json.dumps(v,indent=2)+'\n')
 with PrivateSession(a.output/'session',tool_prefix=a.prefix) as s:
  ipc=CapturedIPC(s)
  def helper(op,req=None,flags=(),expect_ok=True):
   end=time.monotonic()+8
   while True:
    import subprocess
    c=[str(a.prefix/'bin/aqueous-config'),op,'--shell','none',*flags]+(['--request','-'] if req is not None else [])
    r=subprocess.run(c,input=json.dumps(req) if req is not None else None,env=s.env,text=True,capture_output=True,timeout=35)
    v=json.loads(r.stdout)
    if v.get('code')=='config_writer_busy' and op!='apply' and time.monotonic()<end:time.sleep(.1);continue
    if expect_ok:assert v.get('ok'),(op,v,r.stderr)
    return v
  version=helper('version');save('version',version)
  snap=helper('snapshot');save('snapshot',snap)
  native=ipc.call('display.snapshot');save('display',native)
  registry=s.run(['wayland-info']).stdout;(a.output/'registry.txt').write_text(registry);(fixtures/'registry.txt').write_text(registry)
  for name,text in {'offline':'[[output]]\nname="PEARL-OFFLINE"\nscale=1.5\n','disabled':'[[output]]\nname='+json.dumps(native['outputs'][0]['connector'])+'\nenabled=false\n','profile':'[display]\nfallback_profile="desk"\n[[display.profile]]\nname="desk"\n[[display.profile.output]]\nname="PEARL-OFFLINE"\nscale=1.25\n','unknown':'[unexpected]\nunknown=1\n','comments':'# preserved comment\n'}.items():
   req={'protocol':1,'expected_generation':snap['generation'],'raw_files':{'outputs':text}}
   save('candidate-'+name,helper('validate',req))
  rich={'protocol':1,'expected_generation':snap['generation'],'window_rule_changes':[{'op':'add','values':{'app_id':'pearl-test-*','floating':False,'opacity':0.8}}],'custom_keybind_changes':[{'op':'add','chord':'Super+F12','command':'spawn:never-executed'}],'snap_layouts':[{'id':'halves','zones':[{'id':'left','x':0,'y':0,'width':0.5,'height':1}]}],'default_snap_layout':'halves'}
  save('candidate-collections',helper('validate',rich))
  rich.update(collection_apply_version=1,protected_apply=True,collection_preconditions_v2=snap['collection_preconditions_v2'])
  save('candidate-protected-collections',helper('validate',rich))
  declaration={'protocol':1,'expected_generation':snap['generation'],'protected_apply':True,'display_declaration_changes':{'version':1,'sources':{'outputs':snap['display_source_ids']['outputs']},'operations':[{'op':'add','source':'outputs','kind':'profile','ref':'desk','set':{'name':'desk'}},{'op':'add','source':'outputs','kind':'output','parent':'new:desk','set':{'name':'PEARL-OFFLINE','enabled':False}}]}}
  save('candidate-declarations',helper('validate',declaration))
  save('candidate-rejected',helper('validate',{'protocol':1,'expected_generation':snap['generation'],'raw_files':{'outputs':'[[output]]\nname="BAD"\nscale=-10\n'}},expect_ok=False))
  save('candidate-stale',helper('validate',{'protocol':1,'expected_generation':'0'*16,'changes':[]},expect_ok=False))
  save('native-capabilities',ipc.hello)
  req={'protocol':1,'expected_generation':snap['generation'],'changes':[{'id':'layout.gaps_outer','value':9}],'protected_apply':True}
  operation=f'{int(time.time()):010d}-0123456789abcdef0123456789abcdef'
  save('apply-result',helper('apply',req,('--result','v1','--operation-id',operation)))
  save('receipt',helper('operation-status',flags=('--operation-id',operation)))
  ipc.close()
 for name,path in {'helper.schema.json':'settingsApplication/docs/aqueous-config-additions-v1.schema.json','display.schema.json':'compositor/protocol/aqueous-display-v1.schema.json','ipc.schema.json':'compositor/protocol/aqueous-ipc-v1.schema.json'}.items():(fixtures/name).write_bytes((source/path).read_bytes())
 # Source-derived schemas and private snapshots carry exact provenance, including temporary paths.
 for name in ('version','snapshot','display','candidate-offline','candidate-disabled','candidate-profile','candidate-unknown','candidate-comments','apply-result','receipt','candidate-collections','candidate-protected-collections','candidate-declarations','candidate-rejected','candidate-stale','native-capabilities'):(fixtures/(name+'.json')).write_bytes((a.output/(name+'.json')).read_bytes())
 meta['fixture_sha256']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in fixtures.iterdir() if p.is_file() and p.name!='provenance.json'}
 (fixtures/'provenance.json').write_text(json.dumps(meta,indent=2)+'\n');save('metadata',meta)
 print('Captured master helper/display contracts and durable apply receipt',flush=True)
if __name__=='__main__':main()
