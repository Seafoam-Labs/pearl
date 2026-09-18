#!/usr/bin/env python3
"""Build the pinned upstream master into a private prefix without modifying upstream."""
import argparse,hashlib,io,json,os,shutil,subprocess,tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
from aqueous_target import REV
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',type=Path,default=Path('/home/zoey/RiderProjects/Aqueous'));p.add_argument('--prefix',type=Path,default=ROOT/'.cache/aqueous-activity-production');p.add_argument('--revision',default=REV);p.add_argument('--bootstrap-testing',action='store_true',help='Production policy with private instance name for systemd bootstrap test');p.add_argument('--activity-testing',action='store_true',help='Private pixman diagnostic build; never package');a=p.parse_args();revision=a.revision;assert not (a.activity_testing and a.bootstrap_testing);a.source=a.source.resolve();a.prefix=a.prefix.resolve()
 assert a.prefix.is_relative_to(ROOT/'.cache'),'Use a private workspace cache prefix'
 work=a.prefix/'source';a.prefix.mkdir(parents=True,exist_ok=True)
 if not work.exists():
  work.mkdir();data=subprocess.check_output(['git','-C',str(a.source),'archive',revision]);tarfile.open(fileobj=io.BytesIO(data)).extractall(work,filter='data')
  (work/'.pearl-revision').write_text(revision)
 assert (work/'.pearl-revision').read_text()==revision
 for part in ('compositor','settingsApplication'):
  cached=a.source/part/'zig-pkg'
  if cached.exists() and not (work/part/'zig-pkg').exists():shutil.copytree(cached,work/part/'zig-pkg')
 env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(ROOT/'.cache/zig'),PKG_CONFIG_PATH=str(work/'compositor/.deps/wlroots-render-hook/lib/pkgconfig'))
 commands={
 'compositor':['zig','build','--prefix',str(a.prefix),'-Dvulkan-effects='+('false' if a.activity_testing or a.bootstrap_testing else 'true'),'-Dinput-activity-testing='+str(a.activity_testing).lower(),'-Dxwayland='+str(a.activity_testing or a.bootstrap_testing).lower(),'-Dinstance-name='+('aqueous-activity-fixture' if a.bootstrap_testing else 'aqueous'),'-Dman-pages=false','-Doptimize=ReleaseSafe','-Dllvm'],
 'settingsApplication':['zig','build','config','--prefix',str(a.prefix),'-Doptimize=ReleaseSafe']}
 meta={'revision':revision,'input_activity_testing':a.activity_testing,'bootstrap_testing':a.bootstrap_testing,'status':'building','commands':commands,'patched_wlroots_pkgconfig':env['PKG_CONFIG_PATH'],'binary_sha256':{}}
 try:
  dependency=work/'compositor/.deps/wlroots-render-hook'
  patches={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((work/'compositor/patches/wlroots').glob('*.patch'))}
  stamp=dependency/'pearl-patches.json'
  prior=json.loads((a.prefix/'metadata.json').read_text()) if (a.prefix/'metadata.json').exists() else {}
  library=dependency/'lib/libwlroots-0.20.so'
  library_matches=library.exists() and prior.get('wlroots_sha256')==hashlib.sha256(library.read_bytes()).hexdigest()
  if not stamp.exists() or json.loads(stamp.read_text())!=patches or not library_matches:
   download=work/'compositor/.deps/downloads';download.mkdir(parents=True,exist_ok=True)
   cached=a.source/'compositor/.deps/downloads/wlroots-0.20.2.tar.gz'
   if cached.exists():shutil.copyfile(cached,download/cached.name)
   with (a.prefix/'wlroots-build.log').open('w') as log:subprocess.run(['bash',str(work/'compositor/scripts/build-wlroots-render-hook.sh'),str(dependency)],env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
   stamp.write_text(json.dumps(patches,indent=2)+'\n')
  meta['wlroots_patch_sha256']=patches
  for part,command in commands.items():
   print('Building '+part,flush=True)
   with (a.prefix/(part+'.log')).open('w') as log:subprocess.run(command,cwd=work/part,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
  for name in ('aqueous','aqueousctl','aqueous-config'):meta['binary_sha256'][name]=hashlib.sha256((a.prefix/'bin'/name).read_bytes()).hexdigest()
  launcher=a.prefix/'bin/aqueous-activity-launch'
  if launcher.exists():meta['activity_launcher_sha256']=hashlib.sha256(launcher.read_bytes()).hexdigest()
  meta['helper']=json.loads(subprocess.check_output([a.prefix/'bin/aqueous-config','version','--shell','none']))
  library=work/'compositor/.deps/wlroots-render-hook/lib/libwlroots-0.20.so'
  if library.exists():meta['wlroots_sha256']=hashlib.sha256(library.read_bytes()).hexdigest()
  meta['status']='passed'
 finally:(a.prefix/'metadata.json').write_text(json.dumps(meta,indent=2)+'\n')
 print(json.dumps(meta,indent=2))
if __name__=='__main__':main()
