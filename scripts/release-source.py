#!/usr/bin/env python3
"""Make a deterministic worktree source archive and checksum-locked Arch recipe."""
import argparse, gzip, hashlib, io, json, os, tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def archive(root, output):
    meta=json.loads((root/'packaging/release.json').read_text())
    epoch=int(os.environ.get('SOURCE_DATE_EPOCH',meta['source_date_epoch']))
    version=meta['arch_pkgver']; output.mkdir(parents=True,exist_ok=True)
    paths=[]
    for name in ('build.zig','build.zig.zon','.zigversion','README.md','LICENSE','src','spikes','plugins','bindings','resources','scripts','packaging','tests','docs'):
        path=root/name
        if path.is_file():paths.append(path)
        elif path.is_dir():paths.extend(p for p in path.rglob('*') if p.is_file() and not {'__pycache__', '.zig-cache', 'target'}.intersection(p.relative_to(path).parts) and not p.name.endswith('.pyc'))
    target=output/f'pearl-{version}.tar.gz'
    with target.open('wb') as raw, gzip.GzipFile(filename='',fileobj=raw,mode='wb',mtime=epoch) as compressed, tarfile.open(fileobj=compressed,mode='w|',format=tarfile.PAX_FORMAT) as tar:
        for p in sorted(paths):
            if p.is_symlink():raise ValueError(f'Source symlink must be reviewed: {p}')
            data=p.read_bytes();info=tarfile.TarInfo(f'pearl-{version}/{p.relative_to(root)}')
            info.size=len(data);info.mode=0o755 if p.stat().st_mode&0o111 else 0o644
            info.uid=info.gid=0;info.uname=info.gname='';info.mtime=epoch
            tar.addfile(info,io.BytesIO(data))
    digest=hashlib.sha256(target.read_bytes()).hexdigest()
    recipe=(root/'packaging/arch/PKGBUILD').read_text().replace('@SOURCE_SHA256@',digest)
    (output/'PKGBUILD').write_text(recipe)
    result={'archive':target.name,'sha256':digest,'source_date_epoch':epoch,'version':meta['version'],'files':len(paths)}
    (output/'source.json').write_text(json.dumps(result,indent=2)+'\n');return result
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);a=p.parse_args();print(json.dumps(archive(ROOT,a.output.resolve()),indent=2))
