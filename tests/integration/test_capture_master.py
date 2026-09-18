#!/usr/bin/env python3
"""Image-copy and color negotiation with real private Aqueous master sources."""
import argparse,hashlib,json,sys,time
from pathlib import Path
from PIL import Image,ImageChops,ImageStat
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'scripts'))
from pearl_session import PrivateSession,wait_for
from test_surfaces import ctl,status,IPC,clean,capture

def main():
 p=argparse.ArgumentParser(description=__doc__)
 for name in ('pearl','ctl'):p.add_argument('--'+name,type=Path,default=ROOT/'zig-out/bin'/('pearlctl' if name=='ctl' else 'pearl'))
 p.add_argument('--prefix',type=Path,default=ROOT/'.cache/aqueous-activity-production');p.add_argument('--output',type=Path,default=ROOT/'artifacts/aqueous-082/capture');args=p.parse_args();args.pearl=args.pearl.resolve();args.ctl=args.ctl.resolve();args.prefix=args.prefix.resolve();args.output=args.output.resolve();args.output.mkdir(parents=True,exist_ok=True)
 report=dict(status='running',checks={},baseline=json.loads((args.prefix/'metadata.json').read_text()),pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest());checks=report['checks']
 try:
  with PrivateSession(args.output/'session',tool_prefix=args.prefix) as s:
   s.env['DBUS_SYSTEM_BUS_ADDRESS']='unix:path='+str(s.runtime/'system-bus')
   s.child('system-bus',['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
   wait_for(lambda:s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
   s.env['PEARL_SECURITY_LOG']=str(s.output/'security.jsonl');Path(s.env['PEARL_SECURITY_LOG']).write_text('')
   authority=s.child('authority',['python3',ROOT/'tests/fixtures/session_security.py'],input_pipe=True);authority.expect('event=ready')
   app=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings',WAYLAND_DEBUG='client');app.expect('event=control-ready')
   def shot():return ctl(s,args.ctl,'capture','status')['result']
   wait_for(lambda:shot()['available'] and not shot()['locked'])
   assert shot()['isolated_window'] and shot()['color_metadata_required'],shot()
   output=status(s,args.ctl)['outputs'][0]
   rules=Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
   rules.write_text(''.join('[[window]]\napp_id='+json.dumps(name)+'\nfloating=true\nwidth=400\nheight=300\nx=200\ny=150\n' for name in ('org.pearl.CaptureSource','org.pearl.CaptureOverlap')))
   s.run(['aqueousctl','session','reload','--json'])
   fixture=s.child('source',['python3',ROOT/'tests/fixtures/capture_source.py','--id','org.pearl.CaptureSource']);fixture.expect('event=fixture-ready')
   time.sleep(.4)
   for transform in ['normal','90','180','270','flipped','flipped-90','flipped-180','flipped-270']:
    s.run(['wlr-randr','--output',output['connector'],'--transform',transform]);time.sleep(.4)
    ctl(s,args.ctl,'capture','output','--output',output['id']);v=wait_for(lambda:(lambda v:v if not v['pending'] else False)(shot()),10)
    assert v['ready'],v
    path=s.output/('native-'+transform+'.png');path.unlink(missing_ok=True);ctl(s,args.ctl,'capture','save','--generation',str(v['generation']),'--path',str(path))
    img=Image.open(path).convert('RGB');ref=capture(s,'reference-'+transform,output['connector'])
    assert img.size==ref.size,(transform,img.size,ref.size)
    # Master describes default output pixels as gamma22; Pearl exports sRGB.
    gamma=[round(255*(12.92*(i/255)**2.2 if (i/255)**2.2<=.0031308 else 1.055*((i/255)**2.2)**(1/2.4)-.055)) for i in range(256)]
    corrected=ref.point(gamma*3)
    diff=ImageStat.Stat(ImageChops.difference(img,corrected)).mean
    report.setdefault('orientation_error',{})[transform]=diff
    assert max(diff)<3,(transform,diff,v)
   checks['native-output-sdr-conversion-and-eight-transforms']=True
   s.run(['wlr-randr','--output',output['connector'],'--transform','normal']);time.sleep(.3)
   overlap=s.child('overlap',['python3',ROOT/'tests/fixtures/capture_source.py','--id','org.pearl.CaptureOverlap','--cover']);overlap.expect('event=fixture-ready')
   time.sleep(.3)
   ipc=IPC(s)
   native=[e for e in ipc.state() if e['kind']=='window' and e.get('app_id') in ('org.pearl.CaptureSource','org.pearl.CaptureOverlap')]
   assert len(native)==2 and native[0]['geometry']==native[1]['geometry'],native
   assert next(w for w in native if w['app_id']=='org.pearl.CaptureOverlap')['focused'],native
   report['overlapping_windows']=native
   ipc.close()
   def windows():return ctl(s,args.ctl,'capture','windows')['result']['windows']
   source=wait_for(lambda:next((w for w in windows() if w['app_id']=='org.pearl.CaptureSource'),None))
   ctl(s,args.ctl,'capture','window','--text',source['id']);v=wait_for(lambda:(lambda v:v if not v['pending'] else False)(shot()),10)
   report['isolated_source_result']=v
   assert v['ready'],v
   first=s.output/'isolated-overlapped.png';first.unlink(missing_ok=True)
   ctl(s,args.ctl,'capture','save','--generation',str(v['generation']),'--path',str(first))
   overlap.stop();time.sleep(.3)
   ctl(s,args.ctl,'capture','window','--text',source['id']);v=wait_for(lambda:(lambda v:v if not v['pending'] else False)(shot()),10)
   assert v['ready'],v
   second=s.output/'isolated-uncovered.png';second.unlink(missing_ok=True)
   ctl(s,args.ctl,'capture','save','--generation',str(v['generation']),'--path',str(second))
   x,y=Image.open(first).convert('RGB'),Image.open(second).convert('RGB')
   assert x.size==y.size and ImageChops.difference(x,y).getbbox() is None
   checks['native-isolated-source-exports-described-sdr-without-overlap']=True
   fixture.stop();wait_for(lambda:not any(w['id']==source['id'] for w in windows()))
   assert not ctl(s,args.ctl,'capture','window','--text',source['id'],code=4)['ok']
   checks['closed-source-identity-cannot-be-reused']=True
   assert not ctl(s,args.ctl,'capture','window','--text','unknown',code=4)['ok']
   ctl(s,args.ctl,'quit');app.proc.wait(timeout=10);clean(app)
   log='\n'.join(app.lines)
   assert 'ext_foreign_toplevel_image_capture_source_manager_v1' in log and '.get_frame_info(' in log and '.create_source(' in log
   checks['native-source-and-per-frame-color-protocol-used']=True
  report['status']='passed'
 except Exception as e:report.update(status='failed',error=str(e));raise
 finally:(args.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report,indent=2))
if __name__=='__main__':main()
