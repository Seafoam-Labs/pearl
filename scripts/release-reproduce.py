#!/usr/bin/env python3
"""Compare deterministic archives and stripped binaries from distinct fresh roots."""
import argparse, hashlib, json, os, shutil, subprocess, tarfile, tempfile
from pathlib import Path
import importlib.util
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('release_source',ROOT/'scripts/release-source.py');source=importlib.util.module_from_spec(spec);spec.loader.exec_module(source)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,default=ROOT/'artifacts/aqueous-master/reproducibility');a=p.parse_args();a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)
    report={'status':'running','runs':[],'method':'Two source archives and two distinct extracted roots, fresh local build caches, common content-addressed dependency cache, stripped ReleaseSafe binaries.'}
    try:
        with tempfile.TemporaryDirectory(prefix='pearl-reproduce-') as temp:
            for index in range(2):
                out=Path(temp)/str(index);meta=source.archive(ROOT,out)
                with tarfile.open(out/meta['archive']) as tar:tar.extractall(out,filter='data')
                root=out/('pearl-'+json.loads((ROOT/'packaging/release.json').read_text())['arch_pkgver'])
                if (ROOT/'zig-pkg').is_dir():shutil.copytree(ROOT/'zig-pkg',root/'zig-pkg')
                print(f'Building fresh root {index+1}',flush=True)
                env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(ROOT/'.cache/zig'),SOURCE_DATE_EPOCH=str(meta['source_date_epoch']))
                with (a.output/f'build-{index}.log').open('w') as log:subprocess.run(['zig','build','-Drelease=true','-Doptimize=ReleaseSafe','--summary','all'],cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=600)
                binaries={n:hashlib.sha256((root/'zig-out/bin'/n).read_bytes()).hexdigest() for n in ('pearl','pearlctl','pearl-lock')}
                report['runs'].append({'source':meta,'binary_sha256':binaries})
            assert report['runs'][0]==report['runs'][1],report
            report['status']='passed'
    except Exception as error:report.update(status='failed',error=str(error));raise
    finally:(a.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
