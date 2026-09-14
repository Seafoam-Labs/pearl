#!/usr/bin/env python3
"""Optional payload and export boundary checks; never install on the host."""
import argparse,json,os
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
def run(*args,ok=True):
    p=subprocess.run(args,cwd=ROOT,text=True,capture_output=True,timeout=20)
    assert (p.returncode==0)==ok,(args,p.stderr)
    return p

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--build',type=Path,default=ROOT/'zig-out/greeter/bin');args=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='pearl-package-') as tmp:
        root=Path(tmp);stage=root/'stage'
        run('python3','packaging/greeter/stage.py','--build',str(args.build),'--dest',str(stage))
        paths={str(p.relative_to(stage)) for p in stage.rglob('*') if p.is_file()}
        assert 'usr/bin/pearl-greeter' in paths and 'usr/lib/pearl/pearl-greeter-session' in paths
        assert not any(p.startswith(('etc/pam.d/','etc/greetd/','usr/lib/systemd/system/')) for p in paths)
        assert not any('test' in Path(p).name for p in paths)
        assert json.loads((stage/'greeter-release-gate.json').read_text())['production_accepted'] is False
        assert json.loads((stage/'greeter-release-gate.json').read_text())['fingerprint']['pam_policy_installed'] is False
        for name in ('greetd','pearl','pearl-fingerprint-auth'):
            assert 'usr/share/doc/pearl-greeter/examples/fingerprint/'+name+'.example' in paths
        assert not any(p.endswith('pam_fprintd.so') or p.startswith('etc/pam.d/') for p in paths)
        policy=(stage/'usr/share/doc/pearl-greeter/examples/fingerprint/pearl-fingerprint-auth.example').read_text()
        assert 'max-tries=3 timeout=15 debug=off' in policy and 'nullok' not in '\n'.join(line for line in policy.splitlines() if not line.startswith('#'))
        run('python3','packaging/greeter/stage.py','--build',str(args.build),'--dest',str(stage),ok=False)
        for name in ('pearl-greeter','pearl-greeter-host','pearl-greeter-session'):
            run(str(args.build/name),'--version')
        run(str(args.build/'pearl-greeter'),'--probe',ok=False)
        run(str(args.build/'pearl-greeter-host'),ok=False)
        linked=run('ldd',str(args.build/'pearl-greeter')).stdout
        assert all(lib not in linked for lib in ('libpam.so','libpulse.so','libpolkit-agent'))
        prefs=root/'preferences.json';prefs.write_text(json.dumps({'theme':{'mode':'gtk','gtk_name':'Adwaita:dark'},'font_size':18,'exports':[{'command':'must-not-export','secret':'credential-marker'}],'unrelated':'discard'}))
        bundle=root/'bundle'
        run('python3','scripts/export-greeter-appearance.py','--preferences',str(prefs),'--output',str(bundle))
        output=(bundle/'greeter-appearance.json').read_text();assert 'credential-marker' not in output and 'must-not-export' not in output
        assert json.loads(output)['gtk_theme']=='Adwaita:dark'
        prefs.write_text(json.dumps({'theme':{'mode':'gtk','gtk_name':'$(must-not-run)'}}))
        run('python3','scripts/export-greeter-appearance.py','--preferences',str(prefs),'--output',str(root/'rejected'),ok=False)
        assert not (root/'rejected').exists()
        print('Optional package, closed deployment gate, production hook exclusion, linkage and appearance export checks passed.')
if __name__=='__main__':main()
