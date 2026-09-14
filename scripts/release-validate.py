#!/usr/bin/env python3
"""Run the release regression matrix in private sessions; retain every exit/log."""
import argparse, datetime, json, os, subprocess, time, hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
TARGETS=('integration','test-components','test-adapter','test-surfaces','test-desktop','test-services','test-connectivity','test-session-services','test-preferences','test-aqueous-settings','test-capture-master','test-security','test-lock','test-clipboard-capture','test-dock-islands','test-release')
def fingerprint():
    paths=[ROOT/'build.zig',ROOT/'build.zig.zon']
    for folder in ('src','bindings','resources'):
        paths.extend(p for p in (ROOT/folder).rglob('*') if p.is_file())
    digest=hashlib.sha256()
    for path in sorted(paths):digest.update(str(path.relative_to(ROOT)).encode()+b'\0'+path.read_bytes()+b'\0')
    return digest.hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,default=ROOT/'artifacts/aqueous-master/functional');p.add_argument('--resume',action='store_true',help='Retain prior target results and log failed attempts when rerunning selected targets');p.add_argument('--targets',nargs='+',choices=TARGETS,default=TARGETS);a=p.parse_args()
    a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)
    report={'status':'running','started':datetime.datetime.now(datetime.timezone.utc).isoformat(),'targets':{}}
    if a.resume and (a.output/'metadata.json').is_file():
        report=json.loads((a.output/'metadata.json').read_text());report['status']='running'
    initial=fingerprint();report['source_fingerprint']=initial
    env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(ROOT/'.cache/zig'),PEARL_TEST_AQUEOUS_PREFIX=str(ROOT/'.cache/aqueous-master'))
    try:
        for target in ('unit',*a.targets):
            command=['zig','build',*(['test','test-adapter-unit','test-bindings','test-release-tools'] if target=='unit' else [target]),'-Doptimize=ReleaseSafe','-Drelease=true','--summary','all']
            if target!='unit':command+=['--','--output',str(a.output/target)]
            print('Running '+target,flush=True);start=time.monotonic()
            previous=report['targets'].get(target)
            if previous:
                attempts=report.setdefault('previous_attempts',{}).setdefault(target,[]);attempts.append(previous)
                old_log=a.output/(target+'.log')
                if old_log.exists():old_log.rename(a.output/f'{target}.attempt-{len(attempts)}.log')
            with (a.output/(target+'.log')).open('w') as log:
                result=subprocess.run(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=900)
            report['targets'][target]={'exit_code':result.returncode,'seconds':time.monotonic()-start,'command':command}
            (a.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
            print(f'{target}: exit {result.returncode}',flush=True)
        report['source_unchanged']=fingerprint()==initial
        report['status']='passed' if report['source_unchanged'] and all(v['exit_code']==0 for v in report['targets'].values()) else 'failed'
    except Exception as error:report.update(status='failed',error=str(error));raise
    finally:(a.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
    raise SystemExit(report['status']!='passed')
if __name__=='__main__':main()
