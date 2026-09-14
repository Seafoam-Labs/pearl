#!/usr/bin/env python3
"""Build the pinned upstream master into a private prefix without modifying upstream."""
import argparse,hashlib,io,json,os,shutil,subprocess,tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
REV='1d038dc3bafa0044d9599f8f51f84105a6a85bb3'
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',type=Path,default=Path('/home/zoey/RiderProjects/Aqueous'));p.add_argument('--prefix',type=Path,default=ROOT/'.cache/aqueous-master');a=p.parse_args();a.source=a.source.resolve();a.prefix=a.prefix.resolve()
 assert a.prefix.is_relative_to(ROOT/'.cache'),'Use a private workspace cache prefix'
 work=a.prefix/'source';a.prefix.mkdir(parents=True,exist_ok=True)
 if not work.exists():
  work.mkdir();data=subprocess.check_output(['git','-C',str(a.source),'archive',REV]);tarfile.open(fileobj=io.BytesIO(data)).extractall(work,filter='data')
  (work/'.pearl-revision').write_text(REV)
 assert (work/'.pearl-revision').read_text()==REV
 for part in ('compositor','settingsApplication'):
  cached=a.source/part/'zig-pkg'
  if cached.exists() and not (work/part/'zig-pkg').exists():shutil.copytree(cached,work/part/'zig-pkg')
 env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(ROOT/'.cache/zig'),PKG_CONFIG_PATH=str(a.source/'compositor/.deps/wlroots-render-hook/lib/pkgconfig'))
 commands={
 'compositor':['zig','build','--prefix',str(a.prefix),'-Dvulkan-effects=true','-Dman-pages=false','-Doptimize=ReleaseSafe','-Dllvm'],
 'settingsApplication':['zig','build','config','--prefix',str(a.prefix),'-Doptimize=ReleaseSafe']}
 meta={'revision':REV,'status':'building','commands':commands,'patched_wlroots_pkgconfig':env['PKG_CONFIG_PATH'],'binary_sha256':{}}
 try:
  for part,command in commands.items():
   print('Building '+part,flush=True)
   with (a.prefix/(part+'.log')).open('w') as log:subprocess.run(command,cwd=work/part,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
  for name in ('aqueous','aqueousctl','aqueous-config'):meta['binary_sha256'][name]=hashlib.sha256((a.prefix/'bin'/name).read_bytes()).hexdigest()
  meta['helper']=json.loads(subprocess.check_output([a.prefix/'bin/aqueous-config','version','--shell','none']))
  library=a.source/'compositor/.deps/wlroots-render-hook/lib/libwlroots-0.20.so'
  if library.exists():meta['wlroots_sha256']=hashlib.sha256(library.read_bytes()).hexdigest()
  meta['status']='passed'
 finally:(a.prefix/'metadata.json').write_text(json.dumps(meta,indent=2)+'\n')
 print(json.dumps(meta,indent=2))
if __name__=='__main__':main()
