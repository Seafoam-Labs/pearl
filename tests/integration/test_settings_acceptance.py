#!/usr/bin/env python3
"""S6 standalone acceptance and affected regressions, exclusively in private sessions."""
import argparse, concurrent.futures, hashlib, json, subprocess, sys, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]

def fingerprint():
    digest=hashlib.sha256()
    paths=[ROOT/'build.zig',ROOT/'build.zig.zon']
    for directory in ('src','resources','packaging','scripts','tests'):
        paths.extend(p for p in (ROOT/directory).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
    for path in sorted(paths):digest.update(str(path.relative_to(ROOT)).encode()+b'\0'+path.read_bytes()+b'\0')
    return digest.hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('pearl','production-pearl','ctl','settings','production-settings','spike','locker'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--output',type=Path,default=ROOT/'artifacts/settings-app/s6/acceptance')
    p.add_argument('--jobs',type=int,choices=range(1,5),default=3)
    p.add_argument('--resume',action='store_true',help='Reuse passed suites only when source and all executable hashes still match')
    args=p.parse_args()
    for name,value in vars(args).items():
        if isinstance(value,Path):setattr(args,name,value.resolve())
    args.output.mkdir(parents=True,exist_ok=True)
    binaries={name:hashlib.sha256(getattr(args,name).read_bytes()).hexdigest() for name in ('pearl','production_pearl','ctl','settings','production_settings','spike','locker')}
    initial=fingerprint();previous={}
    result_path=args.output/'results.json'
    if args.resume and result_path.exists():
        prior=json.loads(result_path.read_text())
        if prior.get('source_sha256')==initial and prior.get('binaries')==binaries:previous=prior.get('suites',{})
    report=dict(status='running',source_sha256=initial,binaries=binaries,suites={},manual_acceptance=False)
    common=['--ctl',args.ctl]
    front=['--settings',args.settings,'--pearl',args.production_pearl,*common]
    prod=['--pearl',args.production_pearl,*common]
    instrumented=['--pearl',args.pearl,*common]
    suites=[
        ('window','test_settings_app.py',front+['--production',args.production_settings],'results.json'),
        ('appearance','test_settings_appearance.py',front+['--spike',args.spike],'results.json'),
        ('boundary','test_settings_boundary.py',prod,'result.json'),
        ('services','test_settings_services.py',front+['--spike',args.spike],'report.json'),
        ('devices','test_settings_devices.py',['--settings',args.settings,*instrumented,'--spike',args.spike],'report.json'),
        ('presentation','test_settings_presentation.py',['--settings',args.settings,*instrumented],'results.json'),
        ('master-ui','test_master_ui.py',prod+['--settings',args.production_settings,'--keyboard-settings',args.settings],'metadata.json'),
        ('launch','test_settings_integration.py',instrumented+['--production-pearl',args.production_pearl,'--settings',args.settings,'--production-settings',args.production_settings,'--spike',args.spike,'--locker',args.locker],'results.json'),
        ('preferences','test_preferences.py',instrumented,'metadata.json'),
        ('audio-power','test_services.py',instrumented,'results.json'),
        ('connectivity','test_connectivity.py',instrumented,'result.json'),
        ('session-services','test_session_services.py',instrumented+['--production-pearl',args.production_pearl,'--spike',args.spike],'result.json'),
        ('aqueous','test_aqueous_master.py',prod,'metadata.json'),
        ('preview','test_aqueous_preview.py',prod,'metadata.json'),
        ('desktop','test_desktop.py',prod,'results.json'),
        ('surfaces','test_surfaces.py',prod+['--spike',args.spike],'results.json'),
        ('packaging','test_release.py',prod+['--settings',args.production_settings,'--locker',args.locker],'metadata.json'),
        ('compact-lifecycle','test_settings_lifecycle.py',instrumented+['--spike',args.spike],'results.json'),
    ]
    def run(item):
        name,script,arguments,filename=item
        evidence=args.output/name/filename
        if previous.get(name,{}).get('status')=='passed' and evidence.is_file() and hashlib.sha256(evidence.read_bytes()).hexdigest()==previous[name].get('report_sha256'):
            print('Reusing '+name,flush=True);return name,previous[name]
        command=list(map(str,[sys.executable,ROOT/'tests/integration'/script,*arguments,'--output',args.output/name]))
        print('Running '+name,flush=True);start=time.monotonic()
        try:
            with (args.output/(name+'.log')).open('w') as log:completed=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=900)
            receipt=json.loads(evidence.read_text()) if evidence.exists() else {}
            passed=completed.returncode==0 and receipt.get('status')=='passed'
            result=dict(status='passed' if passed else 'failed',exit_code=completed.returncode,seconds=round(time.monotonic()-start,2),groups=len(receipt.get('checks',{})),evidence=name+'/'+filename,command=command)
            if evidence.exists():result['report_sha256']=hashlib.sha256(evidence.read_bytes()).hexdigest()
        except Exception as error:result=dict(status='failed',error=repr(error),command=command)
        print(name+': '+result['status'],flush=True);return name,result
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for future in concurrent.futures.as_completed([pool.submit(run,item) for item in suites]):
            name,result=future.result();report['suites'][name]=result
            result_path.write_text(json.dumps(report,indent=2)+'\n')
    report['source_unchanged']=fingerprint()==initial
    report['status']='passed' if report['source_unchanged'] and all(r['status']=='passed' for r in report['suites'].values()) else 'failed'
    result_path.write_text(json.dumps(report,indent=2)+'\n')
    print('Standalone automated acceptance: '+report['status'],flush=True)
    raise SystemExit(report['status']!='passed')
if __name__=='__main__':main()
