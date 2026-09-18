#!/usr/bin/env python3
"""Pearl lifecycle against separately instrumented native display transactions."""
import argparse,hashlib,json,socket,sys,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'scripts'))
from pearl_session import PrivateSession,wait_for
from test_surfaces import IPC,ctl,clean
from test_aqueous_settings import state,settled,stage

def main():
 p=argparse.ArgumentParser()
 p.add_argument('--pearl',type=Path,default=ROOT/'zig-out/bin/pearl');p.add_argument('--ctl',type=Path,default=ROOT/'zig-out/bin/pearlctl')
 p.add_argument('--prefix',type=Path,default=ROOT/'.cache/aqueous-activity-production');p.add_argument('--output',type=Path,default=ROOT/'artifacts/aqueous-082/preview')
 a=p.parse_args();a.pearl=a.pearl.resolve();a.ctl=a.ctl.resolve();a.prefix=a.prefix.resolve();a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)
 binary=a.prefix/'instrumented/bin/aqueous'
 report=dict(status='running',production=False,checks={},pearl_sha256=hashlib.sha256(a.pearl.read_bytes()).hexdigest(),compositor_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
 try:
  with PrivateSession(a.output/'session',aqueous=binary,tool_prefix=a.prefix) as s:
   ipc=IPC(s);connector=ipc.call('display.snapshot')['outputs'][0]['connector']
   def fault(action,**args):
    with socket.socket(socket.AF_UNIX) as channel:
     channel.settimeout(5);channel.connect(str(s.runtime/'aqueous/outputd.sock'));channel.sendall(json.dumps(dict(op='test_output_retry',name=connector,action=action,**args)).encode()+b'\n')
     reply=json.loads(channel.makefile().readline());assert reply['ok'],reply
   def start(label):
    app=s.child(label,[a.pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready');ctl(s,a.ctl,'aqueous','refresh');settled(s,a.ctl);return app
   app=start('pearl')
   def begin(x):
    stage(s,a.ctl,monitor_changes=[dict(id='live:'+connector,name=connector,x=x,y=0,scale=1,transform='normal')]);ctl(s,a.ctl,'aqueous','apply')
   def phase(name):return wait_for(lambda:state(s,a.ctl)['preview_state']==name,10)
   fault('preview_hold_completion',hold=True);begin(40);phase('applying')
   assert not state(s,a.ctl)['display_preview']=='pending'
   fault('preview_hold_completion',hold=False);phase('previewing')
   ctl(s,a.ctl,'aqueous','revert');v=settled(s,a.ctl);assert v['outcome']=='reverted',v
   preview=state(s,a.ctl,'preview')['value'];assert preview['state']=='reverted' and all(o['restored'] and o['hardware_matches'] for o in preview['affected_outputs']),preview
   report['checks']['keep-waits-for-presentation-and-revert-waits-for-hardware']=True
   begin(50);phase('previewing');fault('preview_session_inactive',inactive=True);phase('waiting_session')
   assert not ctl(s,a.ctl,'aqueous','keep',code=4)['ok']
   fault('preview_session_inactive',inactive=False);v=settled(s,a.ctl);assert v['outcome']=='invalidated' and not v['unresolved'],v
   report['checks']['inactive-session-blocks-keep-and-resumes-rollback']=True
   begin(60);phase('previewing');fault('preview_session_inactive',inactive=True);phase('waiting_session')
   # Kill the GUI while rollback cannot run; its token must survive independently.
   pending=Path(s.env['XDG_STATE_HOME'])/'pearl/aqueous-operations/pending.json.preview';assert json.loads(pending.read_text())['pending']
   app.proc.kill();app.proc.wait(timeout=10)
   fault('preview_session_inactive',inactive=False)
   app=start('pearl-recovery');v=state(s,a.ctl)
   assert v['outcome'] in ('invalidated','reverted') and not v['unresolved'] and not json.loads(pending.read_text())['pending'],v
   report['checks']['restart-reconciles-durable-preview-token']=True
   ctl(s,a.ctl,'quit');app.proc.wait(timeout=10);clean(app);ipc.close()
  report['status']='passed'
 except Exception as e:report.update(status='failed',error=str(e));raise
 finally:(a.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report,indent=2))
if __name__=='__main__':main()
