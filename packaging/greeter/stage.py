#!/usr/bin/env python3
"""Stage the optional greeter into a new directory. Never activate host services."""
import argparse
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[2]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--build',type=Path,default=ROOT/'zig-out/greeter/bin')
    p.add_argument('--dest',type=Path,required=True)
    args=p.parse_args();dest=args.dest.resolve()
    if dest.exists() or dest==Path('/'):
        p.error('destination must be a new staging directory')
    # Complete validation before creating any payload.
    binaries=('pearl-greeter','pearl-greeter-session','pearl-greeter-host')
    for binary in binaries:
        if not (args.build/binary).is_file():p.error('missing production binary: '+binary)
        payload=(args.build/binary).read_bytes()
        if not payload.startswith(b'\x7fELF') or any(marker in payload for marker in (b'fixture-secret',b'PEARL_TEST_GREETER_CONFIG',b'PEARL_TEST_GREETER_CYCLES')):
            p.error('refusing non-production greeter binary: '+binary)
    files={}
    for binary in binaries:
        files[('usr/bin/' if binary=='pearl-greeter' else 'usr/lib/pearl/')+binary]=(args.build/binary,0o755)
    for name in ('pearl-greeter-x11','pearl-aqueous-session','pearl-aqueous-init'):
        files['usr/lib/pearl/'+name]=(ROOT/'packaging/greeter'/name,0o755)
    files['usr/share/wayland-sessions/pearl-aqueous.desktop']=(ROOT/'packaging/greeter/pearl-aqueous.desktop',0o644)
    for name in ('greeter.json','greetd.toml.example','pearl-greeter.sysusers','pearl-greeter.tmpfiles'):
        files['usr/share/doc/pearl-greeter/examples/'+name]=(ROOT/'packaging/greeter'/name,0o644)
    for name in ('GREETER.md','GREETER_COMPATIBILITY.md','AQUEOUS_GREETER_REQUIREMENTS.md'):
        files['usr/share/doc/pearl-greeter/'+name]=(ROOT/'docs'/name,0o644)
    for name in ('LICENSE','COPYING'):
        if (ROOT/name).is_file():files['usr/share/licenses/pearl-greeter/'+name]=(ROOT/name,0o644)
    for target,(source,mode) in files.items():
        path=dest/target;path.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,path);path.chmod(mode)
    gate={'schema':1,'production_accepted':False,'reason':'Restricted Aqueous host and real desktop VM matrix remain gated','activated_services':[]}
    (dest/'greeter-release-gate.json').write_text(json.dumps(gate,indent=2)+'\n')
    print(f'Staged {len(files)} files at {dest}; no service activation or host PAM changes.')


if __name__=='__main__':main()
