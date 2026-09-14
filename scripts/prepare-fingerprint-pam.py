#!/usr/bin/env python3
"""Compile pinned upstream pam_fprintd for private tests only; no download/install."""
import argparse,hashlib,json,subprocess,tarfile,tempfile
from pathlib import Path

ARCHIVE_SHA='a026ef34c31b25975275cc29a5e4eba2b54524769672095a5228098a08acd82c'
SOURCE_SHA='480d336b4ff022ac39f7d680888135f5fb0af8103f90cea8c4b84bffd2252d1c'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--archive',type=Path,required=True);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    if sha(args.archive)!=ARCHIVE_SHA:p.error('archive does not match pinned v1.94.5 source')
    if args.output.exists():p.error('output directory must be new')
    args.output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='pearl-fprintd-build-') as tmp:
        work=Path(tmp)
        with tarfile.open(args.archive) as archive:archive.extractall(work,filter='data')
        source=work/'fprintd-v1.94.5/pam/pam_fprintd.c';assert sha(source)==SOURCE_SHA
        (work/'config.h').write_text('#define GETTEXT_PACKAGE "fprintd"\n#define LOCALEDIR "/nonexistent/pearl-fingerprint-test"\n')
        flags=subprocess.check_output(['pkg-config','--cflags','--libs','libsystemd'],text=True).split()
        subprocess.run(['cc','-shared','-fPIC','-O2','-I'+str(work),str(source),'-o',str(args.output/'pam_fprintd.so'),'-lpam',*flags],check=True)
    (args.output/'provenance.json').write_text(json.dumps({'version':'1.94.5','source_url':'https://gitlab.freedesktop.org/libfprint/fprintd/-/archive/v1.94.5/fprintd-v1.94.5.tar.gz','archive_sha256':ARCHIVE_SHA,'source_sha256':SOURCE_SHA,'binary_sha256':sha(args.output/'pam_fprintd.so'),'use':'non-installed upstream test dependency; not a Pearl C bridge','compiler':subprocess.check_output(['cc','--version'],text=True).splitlines()[0],'libsystemd':subprocess.check_output(['pkg-config','--modversion','libsystemd'],text=True).strip()},indent=2)+'\n')
    print(args.output/'pam_fprintd.so')
if __name__=='__main__':main()
