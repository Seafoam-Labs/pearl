#!/usr/bin/env python3
"""Trusted catalog fixture coverage using the non-installed test executable."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('--greeter',type=Path,required=True); args=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='pearl-catalog-') as tmp:
        root=Path(tmp); high=root/'high'; low=root/'low'; x11=root/'x11'
        for d in (high,low,x11): d.mkdir()
        config=root/'greeter.json'
        value={'roots':[{'path':str(high),'type':'wayland'},{'path':str(low),'type':'wayland'},{'path':str(x11),'type':'x11'}]}
        config.write_text(json.dumps(value))
        def entry(path, name='Example', extra='', executable='/usr/bin/true'):
            path.write_text(f'[Desktop Entry]\nType=Application\nName={name}\nExec={executable}\n{extra}')
        entry(low/'masked.desktop'); (high/'masked.desktop').write_text('[Desktop Entry]\nHidden=true\n')
        entry(high/'example.desktop',extra='OnlyShowIn=GNOME;\n'); entry(x11/'example.desktop')
        entry(high/'hidden.desktop',extra='NoDisplay=true\n')
        entry(high/'missing.desktop',extra='TryExec=pearl-definitely-missing\n')
        entry(high/'malformed.desktop',executable='/usr/bin/true;touch /tmp/must-not-run')
        (high/'link.desktop').symlink_to(low/'masked.desktop')
        def catalog(ok=True):
            proc=subprocess.run([str(args.greeter.resolve()),'--catalog'],env=dict(os.environ,PEARL_TEST_GREETER_CONFIG=str(config)),capture_output=True,text=True,timeout=10)
            assert (proc.returncode==0)==ok,proc.stderr
            return json.loads(proc.stdout) if ok else None
        result=catalog(); entries={e['id']:e for e in result['sessions']}
        assert set(entries)=={'wayland:example.desktop','x11:example.desktop','wayland:missing.desktop'}, entries
        assert entries['wayland:example.desktop']['available']
        assert not entries['wayland:missing.desktop']['available'] and not entries['x11:example.desktop']['available']
        before=entries['wayland:example.desktop']['fingerprint']
        entry(high/'example.desktop',name='Changed'); after={e['id']:e for e in catalog()['sessions']}['wayland:example.desktop']['fingerprint']
        assert before!=after
        value['deny']=['wayland:example.desktop'];config.write_text(json.dumps(value));assert 'wayland:example.desktop' not in {e['id'] for e in catalog()['sessions']}
        for edid in (None, 'ab'*32, 'sha256:'+'AB'*32):
            value['preferred_output_edid']=edid;config.write_text(json.dumps(value));catalog()
        for edid in ('', 'DP-1', 'sha256:', 'g'*64, 'a'*63, 'a'*65, 123):
            value['preferred_output_edid']=edid;config.write_text(json.dumps(value));catalog(False)
        config.write_text('{"version":1,"version":1}');catalog(False)
        print('Catalog: precedence, masking, type identity, metadata, dependencies, Exec rejection, symlinks, fingerprint and policy passed')


if __name__=='__main__':main()
