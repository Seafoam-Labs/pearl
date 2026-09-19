#!/usr/bin/env python3
"""Development-only tests of the native Zig publisher and schema-2 validator."""
import argparse, copy, hashlib, json, os, shutil, struct, subprocess, tempfile, zlib
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]

def main():
    p=argparse.ArgumentParser(); p.add_argument('--tool',type=Path,required=True); p.add_argument('--default-enabled',action='store_true'); args=p.parse_args()
    tool=args.tool.resolve()
    with tempfile.TemporaryDirectory(prefix='pearl-publishing-') as temp:
        root=Path(temp)
        env=os.environ | {'HOME':str(root/'home'),'XDG_DATA_DIRS':str(root/'system')}
        env.update({f'XDG_{kind}_HOME':str(root/kind.lower()) for kind in ['CONFIG','DATA','STATE','CACHE']})
        def run(action,error=None,**kw):
            r=subprocess.run([tool,json.dumps(dict(action=action,**kw))],env=env,cwd=root,text=True,capture_output=True,timeout=60)
            if error:
                assert r.returncode and error in r.stderr,(action,r.stdout,r.stderr);return
            assert r.returncode==0,(action,r.stdout,r.stderr)
            return json.loads(r.stdout)
        default=dict(id='seafoam-community',name='Pearl community themes',url='https://raw.githubusercontent.com/Seafoam-Labs/pearl-community-themes/main/index.json')
        assert run('catalog')['sources']==([default] if args.default_enabled else [])
        sources=root/'config/pearl/theme-repositories.json';sources.parent.mkdir(parents=True,exist_ok=True)
        sources.write_text('{"schema_version":1,"sources":[]}')
        assert run('catalog')['sources']==[]
        if args.default_enabled:
            assert run('source_default')['sources']==[default]
            run('source_default',error='ThemeRepositoryAlreadyConfigured')
            run('source_remove',id=default['id'])
            assert run('catalog')['sources']==[]
        else:run('source_default',error='DefaultRepositoryNotLaunched')
        run('source_add',id='custom',name='Custom',url='https://example.org/index.json')
        assert run('catalog')['sources'][0]['id']=='custom'
        package=root/'mist';shutil.copytree(ROOT/'community-repository/themes/seafoam.mist',package)
        manifest=json.loads((package/'theme.json').read_text())
        assert run('validate',path=str(package))['schema_version']==2
        original=(package/'mist.png').read_bytes()
        # CRC-valid APNG control chunk is rejected before image decode.
        payload=struct.pack('>II',1,0);kind=b'acTL'
        chunk=struct.pack('>I',len(payload))+kind+payload+struct.pack('>I',zlib.crc32(kind+payload))
        (package/'mist.png').write_bytes(original[:33]+chunk+original[33:])
        run('validate',path=str(package),error='AnimatedThemeImage')
        (package/'mist.png').write_bytes(original[:-1]);run('validate',path=str(package),error='InvalidThemeImage')
        (package/'mist.png').write_bytes(original)
        bad=copy.deepcopy(manifest);bad['images'][0]['path']='../escape.png';(package/'theme.json').write_text(json.dumps(bad))
        run('validate',path=str(package),error='InvalidThemePath')
        bad=copy.deepcopy(manifest);bad['profiles']=['missing.json'];(package/'theme.json').write_text(json.dumps(bad))
        run('validate',path=str(package),error='ThemeAssetMissing')
        (package/'theme.json').write_text(json.dumps(manifest))
        packages=[]
        for i in range(17):
            dest=root/f'package-{i}';shutil.copytree(package,dest)
            m=dict(manifest,id=f'community.arbitrary-{i}');(dest/'theme.json').write_text(json.dumps(m))
            packages.append(dict(path=str(dest),url=f'https://example.org/releases/{m["id"]}.tar.gz'))
        spec=dict(schema_version=1,repository_id='test-community',index_url='https://example.org/index.json',packages=packages)
        specpath=root/'publication.json';specpath.write_text(json.dumps(spec))
        first=run('publish_build',path=str(specpath),output=str(root/'one'))
        # Input order cannot change the publication identity.
        spec['packages'].reverse();specpath.write_text(json.dumps(spec))
        second=run('publish_build',path=str(specpath),output=str(root/'two'))
        assert first==second and first['pages']==2
        files=lambda path:{str(f.relative_to(path)):hashlib.sha256(f.read_bytes()).hexdigest() for f in path.rglob('*') if f.is_file()}
        assert files(root/'one')==files(root/'two')
        page=json.loads((root/'one/index.json').read_text());assert len(page['releases'])==16
        assert first['generation'] in page['next']
        tail=json.loads((root/'one/indexes'/first['generation']/'page-1.json').read_text());assert len(tail['releases'])==1 and tail['next'] is None
        for release in page['releases']+tail['releases']:
            data=(root/'one/archives'/f'{release["id"]}-{release["version"]}.tar.gz').read_bytes()
            assert len(data)==release['size'] and hashlib.sha256(data).hexdigest()==release['sha256']
        run('publish_build',path=str(specpath),output=str(root/'one'),error='PublicationOutputExists')
        spec['packages'].append(spec['packages'][0]);specpath.write_text(json.dumps(spec))
        run('publish_build',path=str(specpath),output=str(root/'duplicate'),error='DuplicateThemeRelease')
        print('PASS: schema-2 assets, deterministic multipage publication, archive hashes and source migration')
if __name__=='__main__':main()
