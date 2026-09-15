#!/usr/bin/env python3
"""Run pinned upstream adversarial tests with matching private artifacts."""
import argparse,hashlib,json,os,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
from aqueous_target import REV
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--prefix',type=Path,default=ROOT/'.cache/aqueous-082');p.add_argument('--output',type=Path,default=ROOT/'artifacts/aqueous-082/upstream');a=p.parse_args();a.prefix=a.prefix.resolve();a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)
 source=a.prefix/'source';meta=json.loads((a.prefix/'metadata.json').read_text());assert meta['revision']==REV
 env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(ROOT/'.cache/zig'))
 report=dict(status='running',baseline=meta,checks={})
 try:
  with (a.output/'driver-build.log').open('w') as log:subprocess.run(['zig','build','test-driver','--prefix',str(a.prefix),'-Doptimize=ReleaseSafe'],cwd=source/'settingsApplication',env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
  transactions=source/'settingsApplication/tests/backend/test-transactions.py'
  with (a.output/'transactions.log').open('w') as log:subprocess.run([sys.executable,transactions,a.prefix/'bin/aqueous-config',a.prefix/'bin/aqueous-backend-test'],env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=300)
  report['checks']['canonical-journal-crash-recovery-replay-and-collection-preconditions']=True
  for suite in ('test-collection-impact.py','test-protected-collections.py','test-display-mutations.py'):
   with (a.output/(suite+'.log')).open('w') as log:subprocess.run([sys.executable,source/'settingsApplication/tests/backend'/suite,a.prefix/'bin/aqueous-config',a.prefix/'bin/aqueous-backend-test'],env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=300)
   report['checks'][suite]=True
  with (a.output/'scene-capture.log').open('w') as log:subprocess.run([sys.executable,source/'compositor/scripts/test-scene-capture.py','--compositor',a.prefix/'bin/aqueous','--ctl',a.prefix/'bin/aqueousctl'],env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=300)
  report['checks']['scene-capture']=True
  instrumented=a.prefix/'instrumented'
  build=['zig','build','--prefix',str(instrumented),'-Doutput-retry-testing=true','-Dvulkan-effects=true','-Dman-pages=false','-Doptimize=ReleaseSafe','-Dllvm']
  with (a.output/'compositor-test-build.log').open('w') as log:subprocess.run(build,cwd=source/'compositor',env=dict(env,PKG_CONFIG_PATH=meta['patched_wlroots_pkgconfig']),stdout=log,stderr=subprocess.STDOUT,check=True)
  report['instrumented_compositor']=dict(command=build,sha256=hashlib.sha256((instrumented/'bin/aqueous').read_bytes()).hexdigest(),production=False)
  preview=source/'compositor/scripts/test-display-preview.py';original=preview.read_text();script=original
  replacements={"str(ROOT/'.deps/wlroots-render-hook/lib')":repr(str(Path(meta['patched_wlroots_pkgconfig']).parent)),"source_revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()":'source_revision='+repr(meta['revision'])}
  for before,after in replacements.items():assert before in script;script=script.replace(before,after)
  # Only artifact locations and archive revision reporting differ from upstream.
  wrapper='import sys\nsys.path.insert(0,'+repr(str(preview.parent))+')\n__file__='+repr(str(preview))+'\n'+script
  harness=a.output/'preview-harness.py';harness.write_text(wrapper)
  report['preview_source_sha256']=hashlib.sha256(original.encode()).hexdigest();report['adapted_harness_sha256']=hashlib.sha256(wrapper.encode()).hexdigest()
  with (a.output/'preview.log').open('w') as log:subprocess.run([a.prefix/"test-venv/bin/python",harness],env=dict(env,AQUEOUS_COMPOSITOR_BIN=str(instrumented/'bin/aqueous'),AQUEOUS_CONFIG_HELPER=str(a.prefix/'bin/aqueous-config')),stdout=log,stderr=subprocess.STDOUT,check=True,timeout=300)
  report['checks']['native-lease-adversarial-upstream-suite']=True;report['status']='passed'
 except Exception as e:report.update(status='failed',error=str(e));raise
 finally:(a.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report,indent=2))
if __name__=='__main__':main()
