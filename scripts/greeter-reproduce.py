#!/usr/bin/env python3
"""Build greeter ReleaseSafe artifacts in two fresh source/build roots and compare."""
import argparse,hashlib,json,os
from pathlib import Path
import shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,default=ROOT/'artifacts/greeter/latest/reproducibility.json');p.add_argument('--include-locker',action='store_true');args=p.parse_args()
    results=[]
    with tempfile.TemporaryDirectory(prefix='pearl-reproduce-') as tmp:
        for i in range(2):
            work=Path(tmp)/str(i);work.mkdir()
            for name in ('src','bindings','resources','tests','spikes'):
                shutil.copytree(ROOT/name,work/name,ignore=shutil.ignore_patterns('__pycache__'))
            for name in ('build.zig','build.zig.zon','.zigversion'):shutil.copyfile(ROOT/name,work/name)
            # Pinned dependency sources are reused; compiler outputs/build caches are fresh.
            (work/'zig-pkg').symlink_to(ROOT/'zig-pkg',target_is_directory=True)
            with (work/'build.log').open('w') as log:
                subprocess.run(['zig','build','build-greeter',*(['build-locker'] if args.include_locker else []),'-Doptimize=ReleaseSafe','-Drelease=true','--global-cache-dir',str(work/'global-cache')],cwd=work,env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(work/'global-cache')),stdout=log,stderr=subprocess.STDOUT,check=True)
            binaries={name:sha(work/'zig-out/greeter/bin'/name) for name in ('pearl-greeter','pearl-greeter-session','pearl-greeter-host','pearl-greeter-sync')}
            if args.include_locker:binaries['pearl-lock']=sha(work/'zig-out/bin/pearl-lock')
            results.append(binaries)
        assert results[0]==results[1],results
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps({'status':'passed','fresh_build_roots':2,'compiler':'0.16.0','optimize':'ReleaseSafe','stripped':True,'binaries':results[0],'production_accepted':False},indent=2)+'\n')
    print(args.output)
if __name__=='__main__':main()
