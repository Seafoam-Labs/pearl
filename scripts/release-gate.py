#!/usr/bin/env python3
"""Fail closed until automated evidence and explicit human release signoffs exist."""
import argparse, hashlib, json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
MANUAL=('direct-login','uwsm-login','visual-review','physical-displays','physical-security','hardware-services','accessibility','presentation-performance')
TARGETS={'unit','integration','test-components','test-adapter','test-surfaces','test-desktop','test-services','test-connectivity','test-session-services','test-preferences','test-aqueous-settings','test-capture-master','test-security','test-lock','test-clipboard-capture','test-dock-islands','test-release'}
def read(path):
    try:return json.loads(path.read_text())
    except (OSError,ValueError):return {}

def evaluate(evidence,project=ROOT):
    checks={};package=read(evidence/'package/metadata.json');binary=package.get('binary_sha256',{})
    checks['package']=package.get('status')=='passed' and set(binary)=={'pearl','pearlctl','pearl-lock'}
    packaged=evidence/'package'/Path(package.get('package','missing')).name
    checks['package-hash']=packaged.is_file() and hashlib.sha256(packaged.read_bytes()).hexdigest()==package.get('sha256')
    functional=read(evidence/'functional/metadata.json');targets=functional.get('targets',{})
    checks['functional']=functional.get('status')=='passed' and functional.get('source_unchanged') is True and TARGETS<=targets.keys() and all(targets[n].get('exit_code')==0 for n in TARGETS if n in targets)
    installed=read(evidence/'functional/test-release/metadata.json').get('binary_sha256',{})
    checks['tested-production-binaries']=bool(binary) and installed=={'pearl':binary.get('pearl'),'ctl':binary.get('pearlctl'),'locker':binary.get('pearl-lock')}
    performance=read(evidence/'performance/metadata.json')
    checks['performance-soak']=performance.get('status')=='passed' and performance.get('cycles',0)>=1000 and len(performance.get('idle_samples',[]))>=61 and performance.get('pearl_sha256')==binary.get('pearl') and bool(binary) and performance.get('native_preview_revert_cycles',0)>=10 and performance.get('helper_contention_cycles',0)>=10
    repro=read(evidence/'reproducibility/metadata.json');runs=repro.get('runs',[])
    checks['reproducibility']=repro.get('status')=='passed' and len(runs)==2 and runs[0]==runs[1] and runs[0].get('binary_sha256')==binary and runs[0].get('source')==package.get('source')
    release=read(project/'packaging/release.json')
    master=read(evidence/'functional/test-aqueous-settings/metadata.json')
    capture=read(evidence/'functional/test-capture-master/metadata.json')
    upstream=read(evidence/'upstream/metadata.json')
    baseline=master.get('baseline',{})
    checks['matching-master-integration']=master.get('status')=='passed' and master.get('pearl_sha256')==binary.get('pearl') and bool(binary)
    checks['matching-master-capture']=capture.get('baseline')==baseline and capture.get('status')=='passed' and capture.get('pearl_sha256')==binary.get('pearl') and bool(binary)
    checks['matching-master-performance']=performance.get('baseline')==baseline and performance.get('status')=='passed'
    checks['upstream-adversarial']=upstream.get('status')=='passed' and upstream.get('baseline')==baseline
    checks['master-provenance']=baseline.get('revision')==release.get('aqueous_revision') and baseline.get('binary_sha256')=={'aqueous':release.get('aqueous_binary_sha256'),'aqueousctl':release.get('aqueousctl_binary_sha256'),'aqueous-config':release.get('aqueous_config_binary_sha256')} and baseline.get('wlroots_sha256')==release.get('aqueous_wlroots_sha256') and baseline.get('helper',{}).get('version')==release.get('aqueous_config_floor')
    coverage=read(project/'docs/aqueous-capabilities.json')
    rows=coverage.get('rows',[])
    ui=read(evidence/'ui/metadata.json')
    checks['master-ui']=ui.get('baseline')==baseline and ui.get('status')=='passed' and ui.get('quick') is False and ui.get('pearl_sha256')==binary.get('pearl') and bool(binary) and all(ui.get('checks',{}).get(k) for k in ('theme-dark','theme-light','theme-gtk-compact','theme-large-text','native-accessibility-names-and-roles','keyboard-rule-entry-and-shared-advanced-draft','custom-shortcut-recorder-cancellation','mixed-scale-display-page','settings-allocation-fits-default-and-large-text'))
    fixtures=project/'tests/fixtures/aqueous-master';provenance=read(fixtures/'provenance.json')
    checks['contract-fixture-hashes']=provenance.get('revision')==release.get('aqueous_revision') and bool(provenance.get('fixture_sha256')) and all((fixtures/name).is_file() and hashlib.sha256((fixtures/name).read_bytes()).hexdigest()==digest for name,digest in provenance.get('fixture_sha256',{}).items())
    checks['capability-inventory']=coverage.get('inventory_complete') is True and coverage.get('revision')==release.get('aqueous_revision') and len(rows)>=385 and all(all(row.get(key) for key in ('kind','name','source','consumer','entry','test','status')) for row in rows)
    license_meta=release.get('license','')
    checks['project-license']=(project/'LICENSE').is_file() and bool(license_meta) and 'Unlicensed' not in license_meta and license_meta in (project/'packaging/arch/PKGBUILD').read_text()
    signoff=read(evidence/'manual.json')
    for name in MANUAL:
        item=signoff.get('checks',{}).get(name,{})
        path=(evidence/item.get('evidence','missing')).resolve()
        checks[name]=bool(item.get('status')=='passed' and item.get('reviewer') and item.get('date') and item.get('machine') and item.get('notes') and signoff.get('binary_sha256')==binary and binary and path.is_relative_to(evidence.resolve()) and path.is_file() and item.get('evidence_sha256')==hashlib.sha256(path.read_bytes()).hexdigest())
    return {'release_ready':all(checks.values()),'checks':checks,'pending_or_failed':[n for n,ok in checks.items() if not ok],'binary_sha256':binary}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--evidence',type=Path,default=ROOT/'artifacts/aqueous-082');a=p.parse_args();a.evidence=a.evidence.resolve();result=evaluate(a.evidence);a.evidence.mkdir(parents=True,exist_ok=True);(a.evidence/'gate.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2));raise SystemExit(not result['release_ready'])
