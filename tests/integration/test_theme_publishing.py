#!/usr/bin/env python3
"""Development-only tests of the native Zig publisher and schema-2 validator."""
import argparse, copy, hashlib, json, os, shutil, struct, subprocess, tempfile, zlib
from pathlib import Path
from test_theme_packages import fixture
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
        default=dict(id='seafoam-community',name='Pearl community themes',url='https://github.com/Seafoam-Labs/pearl-community-themes')
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
        package=root/'mist';manifest=fixture(package)
        manifest.update(schema_version=2, images=[dict(id='mist',path='mist.png')])
        manifest['requires']['style_api']=2
        (package/'theme.json').write_text(json.dumps(manifest))
        (package/'LICENSE').write_text('Original test fixture, dedicated to the public domain.')
        (package/'ATTRIBUTION.md').write_text('Original test fixture; no third party assets.')
        def chunk(kind,data):
            return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
        png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(b'\x00\xff\xff\xff\xff'))+chunk(b'IEND',b'')
        (package/'mist.png').write_bytes(png)
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
        bad=copy.deepcopy(manifest);bad['profiles']=['missing.json'];bad['requires']['profile_api']=1;(package/'theme.json').write_text(json.dumps(bad))
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
        # Native author commands, safe writes and palette-only publication.
        def author(*argv,valid=True):
            r=subprocess.run([tool,*map(str,argv)],env=env,cwd=root,text=True,capture_output=True,timeout=60)
            assert bool(r.returncode)==(not valid),(argv,r.stdout,r.stderr)
            return json.loads(r.stdout)
        created=author('init','meadow')
        local=Path(created['path']); original=local.read_bytes()
        assert created['dark']==created['light']
        assert author('init','meadow',valid=False)['diagnostic']['code']=='PaletteAlreadyExists'
        assert local.read_bytes()==original
        assert author('validate',local)['valid']
        imported=root/'Noctalia Palette.json'
        imported.write_text(json.dumps(dict(name='Imported',dark=dict(mSurface='#101c19',mOnSurface='#e8f4e9',mPrimary='#a4dfb0',mSecondary='#abcdef'))))
        assert author('validate',imported)['valid']
        imported_result=author('import',imported,'--name','noctalia')
        assert imported_result['source']['dark']['secondary']=='#abcdef'
        catalog=run('catalog')
        assert {e['id'] for e in catalog['entries'] if e['editable']}=={'local.palette.meadow','local.palette.noctalia'}
        assert all(e['fallback']=='dark' for e in catalog['entries'] if e['editable'])
        stale=run('palette_write',name='meadow',contents=original.decode(),expected='0'*64)
        assert not stale['valid'] and stale['diagnostic']['code']=='Conflict'
        assert local.read_bytes()==original
        invalid=dict(dark=dict(surface='#101c19',on_surface='#101c19',primary='#a4dfb0'))
        bad=run('palette_write',name='meadow',contents=json.dumps(invalid),expected=created['expected'])
        assert not bad['valid'] and bad['diagnostic']['suggested']=='#ffffff'
        assert local.read_bytes()==original
        publication=dict(id='org.example.meadow',author='Fixture author',license='CC0-1.0',source='https://example.org/meadow',version='1.0.0',license_text='Original test fixture, dedicated to the public domain.',attribution='Original test palette; no third party assets.')
        metadata=root/'metadata.json';metadata.write_text(json.dumps(publication))
        exported=author('export',local,'--output',root/'exported','--metadata',metadata)
        assert exported['manifest']['schema_version']==2
        assert run('validate',path=str(root/'exported'))['id']==publication['id']
        exported_hover=json.loads((root/'exported/palette-hover.json').read_text())
        assert exported_hover['dark']==exported_hover['light']
        compact=json.loads(local.read_text())|dict(publication=publication)
        local.write_text(json.dumps(compact))
        spec['packages']=[dict(path=str(local),url='https://example.org/meadow.tar.gz')]
        specpath.write_text(json.dumps(spec))
        for folder in ('compact-one','compact-two'):
            run('publish_build',path=str(specpath),output=str(root/folder))
        assert files(root/'compact-one')==files(root/'compact-two')
        receipt=run('import_archive',path=str(root/'compact-one/archives/org.example.meadow-1.0.0.tar.gz'))
        assert receipt['id']==publication['id']
        assert run('preview',theme=dict(mode='package',package_id=publication['id']))['palette_css']==run('preview',theme=dict(mode='package',package_id='local.palette.meadow'))['palette_css']
        assert not list((root/'compact-one').glob('.compiled-*'))
        print('PASS: editable palettes, import aliases, conflicts, exports, compact publication; schema-2 assets, deterministic multipage publication, archive hashes and source migration')
if __name__=='__main__':main()
