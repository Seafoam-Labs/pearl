#!/usr/bin/env python3
"""Fail closed until automated evidence and explicit human release signoffs exist."""
import argparse, hashlib, json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
MANUAL=('direct-login','uwsm-login','visual-review','physical-displays','physical-security','hardware-services','accessibility','presentation-performance')
TARGETS={'unit','integration','test-components','test-adapter','test-surfaces','test-desktop','test-services','test-connectivity','test-session-services','test-preferences','test-aqueous-settings','test-security','test-lock','test-clipboard-capture','test-dock-islands','test-release'}
def read(path):
    try:return json.loads(path.read_text())
    except (OSError,ValueError):return {}

def evaluate(evidence,project=ROOT):
    checks={};package=read(evidence/'package/metadata.json');binary=package.get('binary_sha256',{})
    checks['package']=package.get('status')=='passed' and set(binary)=={'pearl','pearlctl','pearl-lock'}
    packaged=evidence/'package'/Path(package.get('package','missing')).name
    checks['package-hash']=packaged.is_file() and hashlib.sha256(packaged.read_bytes()).hexdigest()==package.get('sha256')
    functional=read(evidence/'functional/metadata.json');targets=functional.get('targets',{})
    checks['functional']=functional.get('status')=='passed' and TARGETS<=targets.keys() and all(targets[n].get('exit_code')==0 for n in TARGETS if n in targets)
    installed=read(evidence/'functional/test-release/metadata.json').get('binary_sha256',{})
    checks['tested-production-binaries']=bool(binary) and installed=={'pearl':binary.get('pearl'),'ctl':binary.get('pearlctl'),'locker':binary.get('pearl-lock')}
    performance=read(evidence/'performance/metadata.json')
    checks['performance-soak']=performance.get('status')=='passed' and performance.get('cycles',0)>=1000 and len(performance.get('idle_samples',[]))>=61 and performance.get('pearl_sha256')==binary.get('pearl') and bool(binary)
    repro=read(evidence/'reproducibility/metadata.json');runs=repro.get('runs',[])
    checks['reproducibility']=repro.get('status')=='passed' and len(runs)==2 and runs[0]==runs[1] and runs[0].get('binary_sha256')==binary and runs[0].get('source')==package.get('source')
    license_meta=read(project/'packaging/release.json').get('license','')
    checks['project-license']=(project/'LICENSE').is_file() and bool(license_meta) and 'Unlicensed' not in license_meta and license_meta in (project/'packaging/arch/PKGBUILD').read_text()
    signoff=read(evidence/'manual.json')
    for name in MANUAL:
        item=signoff.get('checks',{}).get(name,{})
        path=(evidence/item.get('evidence','missing')).resolve()
        checks[name]=bool(item.get('status')=='passed' and item.get('reviewer') and item.get('date') and item.get('machine') and item.get('notes') and signoff.get('binary_sha256')==binary and binary and path.is_relative_to(evidence.resolve()) and path.is_file() and item.get('evidence_sha256')==hashlib.sha256(path.read_bytes()).hexdigest())
    return {'release_ready':all(checks.values()),'checks':checks,'pending_or_failed':[n for n,ok in checks.items() if not ok],'binary_sha256':binary}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--evidence',type=Path,default=ROOT/'artifacts/t16');a=p.parse_args();a.evidence=a.evidence.resolve();result=evaluate(a.evidence);a.evidence.mkdir(parents=True,exist_ok=True);(a.evidence/'gate.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2));raise SystemExit(not result['release_ready'])
