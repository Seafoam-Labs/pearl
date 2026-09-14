#!/usr/bin/env python3
"""Real pinned pam_fprintd + synthetic fprintd on a private bus, no real reader."""
import argparse,hashlib,json,os,subprocess,sys,tempfile,time
from pathlib import Path
from test_fingerprint import pam_conversation,ROOT

def wait(check):
    end=time.monotonic()+5
    while time.monotonic()<end:
        if check():return
        time.sleep(.025)
    raise AssertionError('private fprintd condition timed out')
def state(path):
    try:return json.loads(path.read_text())
    except (FileNotFoundError,json.JSONDecodeError):return {}
def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('locker','pam-module','fprintd-module'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--output',type=Path,default=ROOT/'artifacts/fingerprint/latest/upstream.json');args=p.parse_args()
    args.locker=args.locker.resolve();args.pam_module=args.pam_module.resolve();args.fprintd_module=args.fprintd_module.resolve()
    report={'status':'running','real_device':False,'real_login':False,'evidence':'upstream pam_fprintd 1.94.5 with private mock fprintd; no polkit or hardware acceptance','module_sha256':hashlib.sha256(args.fprintd_module.read_bytes()).hexdigest(),'checks':[]}
    for mode in ('success','no_match','no_scan','no_device','unenrolled','busy','cancel','account_denied'):
        with tempfile.TemporaryDirectory(prefix='pearl-dev-fprintd-') as tmp:
            root=Path(tmp);status=root/'state.json'
            daemon=subprocess.Popen(['dbus-daemon','--session','--nofork',f'--address=unix:path={root}/bus','--print-address=1'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
            address=daemon.stdout.readline().strip();assert address.startswith('unix:path='+str(root))
            env=dict(os.environ,DBUS_SYSTEM_BUS_ADDRESS=address)
            service=subprocess.Popen([sys.executable,str(ROOT/'tests/fixtures/fingerprint/fprintd_service.py'),'success' if mode=='account_denied' else mode,str(status)],env=env,stderr=subprocess.PIPE)
            try:
                wait(lambda:state(status).get('ready'))
                # Only this unprivileged helper receives the private bus address.
                previous=os.environ.get('DBUS_SYSTEM_BUS_ADDRESS');os.environ['DBUS_SYSTEM_BUS_ADDRESS']=address
                (root/'pearl').write_text(f'auth [success=done default=ignore] {args.fprintd_module} max-tries=3 timeout=1 debug=off\nauth required {args.pam_module} fingerprint-fallback\naccount required {args.pam_module} policy-{"denied" if mode=="account_denied" else "success"}\n')
                start=time.monotonic()
                try:result,kinds,_=pam_conversation(args.locker,root,cancel=mode=='cancel')
                finally:
                    if previous is None:os.environ.pop('DBUS_SYSTEM_BUS_ADDRESS',None)
                    else:os.environ['DBUS_SYSTEM_BUS_ADDRESS']=previous
                elapsed=time.monotonic()-start
                assert result is None if mode=='cancel' else (result==0)==(mode!='account_denied'),(mode,result)
                wait(lambda:not state(status).get('claimed',True))
                record=state(status)
                if mode in ('success','account_denied'):assert 1 not in kinds and record['starts']==1 and record['disconnect_cleanup']==1,record
                if mode=='no_match':assert record['starts']==3 and record['stops']==3 and record['releases']==1,record
                if mode=='no_scan':assert record['starts']==1 and record['stops']==1 and elapsed<4,record
                if mode=='cancel':assert record['disconnect_cleanup']==1,record
                if mode in ('no_device','unenrolled'):assert record['claims']==0,record
                report['checks'].append({'case':mode,'status':'passed','seconds':elapsed,'device_fixture':record})
            finally:
                service.terminate();service.wait(timeout=3);daemon.terminate();daemon.wait(timeout=3)
                service.stderr.close();daemon.stdout.close()
    report['status']='passed';args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2)+'\n')
    print('Pinned upstream pam_fprintd: eight private-bus cases passed. Hardware and real login remain unverified.')
if __name__=='__main__':main()
