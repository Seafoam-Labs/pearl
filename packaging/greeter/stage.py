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
    p.add_argument('--system-package',action='store_true',help='Include install-time defaults and service integration for the standalone Arch package')
    args=p.parse_args();dest=args.dest.resolve()
    if dest.exists() or dest==Path('/'):
        p.error('destination must be a new staging directory')
    # Complete validation before creating any payload.
    binaries=('pearl-greeter','pearl-greeter-session','pearl-greeter-host','pearl-greeter-sync')
    for binary in binaries:
        if not (args.build/binary).is_file():p.error('missing production binary: '+binary)
        payload=(args.build/binary).read_bytes()
        if not payload.startswith(b'\x7fELF') or any(marker in payload for marker in (b'fixture-secret',b'PEARL_TEST_GREETER_CONFIG',b'PEARL_TEST_GREETER_CYCLES')):
            p.error('refusing non-production greeter binary: '+binary)
    files={}
    for binary in binaries:
        files[('usr/bin/' if binary=='pearl-greeter' else 'usr/lib/pearl/')+binary]=(args.build/binary,0o755)
    files['usr/share/polkit-1/actions/org.aqueous.Pearl.Greeter.Appearance.policy']=(ROOT/'packaging/greeter/org.aqueous.Pearl.Greeter.Appearance.policy',0o644)
    launchers=('pearl-greeter-x11','pearl-greeter-init')
    if not args.system_package:
        launchers+=('pearl-aqueous-session','pearl-aqueous-init')
    for name in launchers:
        files['usr/lib/pearl/'+name]=(ROOT/'packaging/greeter'/name,0o755)
    if not args.system_package:
        files['usr/share/wayland-sessions/pearl-aqueous.desktop']=(ROOT/'packaging/greeter/pearl-aqueous.desktop',0o644)
    else:
        files['etc/pearl/greeter.json']=(ROOT/'packaging/greeter/greeter.json',0o644)
        # greetd owns /etc/greetd/config.toml. The install hook backs up and
        # replaces it using this template, avoiding a pacman ownership conflict.
        files['usr/share/pearl-greeter/greetd.toml']=(ROOT/'packaging/greeter/greetd.toml',0o644)
        files['usr/lib/systemd/system/pearl-greeter.service']=(ROOT/'packaging/greeter/pearl-greeter.service',0o644)
        files['usr/lib/sysusers.d/pearl-greeter.conf']=(ROOT/'packaging/greeter/pearl-greeter.sysusers',0o644)
        files['usr/lib/tmpfiles.d/pearl-greeter.conf']=(ROOT/'packaging/greeter/pearl-greeter.tmpfiles',0o644)
        files['usr/lib/pearl/pearl-greeter-setup']=(ROOT/'packaging/greeter/setup.py',0o755)
        files['usr/share/doc/pearl-greeter/ARCH_PACKAGE.md']=(ROOT/'packaging/arch-greeter/README.md',0o644)
        for notice in (ROOT/'bindings/licenses').iterdir():
            if notice.is_file():
                files['usr/share/licenses/pearl-greeter/'+notice.name]=(notice,0o644)
    for name in ('greeter.json','greetd.toml.example','pearl-greeter.sysusers','pearl-greeter.tmpfiles'):
        files['usr/share/doc/pearl-greeter/examples/'+name]=(ROOT/'packaging/greeter'/name,0o644)
    for name in ('GREETER.md','GREETER_COMPATIBILITY.md','AQUEOUS_GREETER_REQUIREMENTS.md','FINGERPRINT_LOGIN.md','FINGERPRINT_LOGIN_IMPLEMENTATION_PLAN.md'):
        files['usr/share/doc/pearl-greeter/'+name]=(ROOT/'docs'/name,0o644)
    for name in ('greetd.example','pearl.example','pearl-fingerprint-auth.example'):
        files['usr/share/doc/pearl-greeter/examples/fingerprint/'+name]=(ROOT/'packaging/greeter/fingerprint'/name,0o644)
    for name in ('LICENSE','COPYING'):
        if (ROOT/name).is_file():files['usr/share/licenses/pearl-greeter/'+name]=(ROOT/name,0o644)
    for target,(source,mode) in files.items():
        path=dest/target;path.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,path);path.chmod(mode)
    gate={'schema':1,'production_accepted':False,'reason':'Real greetd lifecycle and desktop VM matrix remain unaccepted','activated_services':[], 'fingerprint':{'production_accepted':False,'reason':'Real reader, installed PAM policy, desktop and accessibility acceptance remain gated','pam_policy_installed':False}}
    gate_path=dest/('usr/share/pearl-greeter/release-gate.json' if args.system_package else 'greeter-release-gate.json')
    gate_path.parent.mkdir(parents=True,exist_ok=True)
    gate_path.write_text(json.dumps(gate,indent=2)+'\n')
    print(f'Staged {len(files)} files at {dest}; no service activation or host PAM changes.')


if __name__=='__main__':main()
