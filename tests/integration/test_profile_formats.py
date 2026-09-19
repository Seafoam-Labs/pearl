#!/usr/bin/env python3
"""Development-only independent parsers check outputs produced by the Zig worker."""
import argparse, hashlib, json, os, shutil, subprocess, tempfile, tomllib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def main():
    p=argparse.ArgumentParser();p.add_argument('--tool',type=Path,required=True);args=p.parse_args()
    evidence=ROOT/'artifacts/theme-completion/profile-formats.json';checks=[]
    with tempfile.TemporaryDirectory(prefix='pearl-profile-formats-') as temporary:
        root=Path(temporary)
        env=os.environ|{'HOME':str(root),'XDG_CONFIG_HOME':str(root/'config'),'XDG_CACHE_HOME':str(root/'cache'),'XDG_DATA_HOME':str(root/'data'),'XDG_DATA_DIRS':str(root/'system')}
        for source in sorted((ROOT/'themes/profiles').glob('seafoam.*')):
            package=root/source.name;shutil.copytree(source,package)
            descriptor=json.loads((package/'profile.json').read_text())
            manifest=dict(schema_version=2,id='verify.'+descriptor['application'],name=descriptor['name'],author=descriptor['author'],license=descriptor['license'],source=descriptor['source'],asset_version='1.0.0',requires=dict(profile_api=1),profiles=['profile.json'])
            (package/'theme.json').write_text(json.dumps(manifest))
            output=root/(source.name+'-output')
            run=subprocess.run([args.tool.resolve(),json.dumps(dict(action='verify_profiles',path=str(package),output=str(output)))],env=env,capture_output=True,text=True,timeout=90)
            assert run.returncode==0,(descriptor['id'],run.stdout,run.stderr)
            for variant in descriptor['variants']:
                for template in descriptor['templates']:
                    file=output/descriptor['id']/variant/template['output'];text=file.read_text()
                    assert '{{' not in text
                    if file.suffix=='.json':
                        value=json.loads(text);assert {v['appearance'] for v in value['themes']}=={'dark','light'}
                    if file.suffix=='.toml':assert isinstance(tomllib.loads(text)['palettes'],dict)
                    checks.append(dict(profile=descriptor['id'],variant=variant,format=file.suffix,sha256=hashlib.sha256(file.read_bytes()).hexdigest()))
    evidence.parent.mkdir(parents=True,exist_ok=True);evidence.write_text(json.dumps(dict(status='passed',checks=checks),indent=2)+'\n')
    print('PASS native profile outputs: both Zed variants, Starship TOML, and resolved CSS')
if __name__=='__main__':main()
