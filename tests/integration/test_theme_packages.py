#!/usr/bin/env python3
"""Test the compiled Zig theme tool; Python is test infrastructure only."""
import argparse
import copy
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tarfile
import tempfile
import threading

PALETTE = dict(surface='#101c19', low='#162822', container='#1c3028', high='#263d32', text='#e8f4e9', secondary='#c5d8c9', primary='#a4dfb0', on_primary='#10391d', primary_container='#285b37', on_container='#d3f8dc', outline='#82998a', error_color='#ffb4ab', error_container='#601410')

def fixture(root, key='org.example.sample', version='1.0.0'):
    root.mkdir(parents=True, exist_ok=True)
    manifest = dict(schema_version=1, id=key, name='Sample Theme', author='Fixture author', license='CC0-1.0', source='https://example.org/sample', asset_version=version, requires=dict(palette_api=1, style_api=1), palettes=dict(dark='dark.json'), style=dict(tokens='tokens.json', css='extra.css'))
    (root / 'theme.json').write_text(json.dumps(manifest))
    (root / 'dark.json').write_text(json.dumps(PALETTE))
    (root / 'tokens.json').write_text(json.dumps(dict(card_radius=4, control_radius=3)))
    (root / 'extra.css').write_text('button:hover { background-color: $primary$; color: $on_primary$; }')
    return manifest

def archive(root, destination):
    with tarfile.open(destination, 'w:gz', format=tarfile.USTAR_FORMAT) as tar:
        for f in sorted(root.rglob('*')):
            tar.add(f, arcname=f.relative_to(root), recursive=False)
    return destination.read_bytes()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tool', type=Path, required=True)
    parser.add_argument('--suite', choices=['packages', 'repository'], default='packages')
    args = parser.parse_args()
    tool = args.tool.resolve()
    with tempfile.TemporaryDirectory(prefix='pearl-theme-test-') as tmp:
        root = Path(tmp)
        env = os.environ | {f'XDG_{kind}_HOME': str(root / kind.lower()) for kind in ['CONFIG','DATA','STATE','CACHE']}
        env['XDG_DATA_DIRS'] = str(root / 'system')
        env['HOME'] = str(root / 'home')
        def run(action, error=None, **kw):
            p = subprocess.run([str(tool), json.dumps(dict(action=action, **kw))], env=env, capture_output=True, text=True, timeout=60)
            if error:
                assert p.returncode != 0 and error in p.stderr, (action, p.returncode, p.stdout, p.stderr)
                return
            assert p.returncode == 0, (action, p.stdout, p.stderr)
            return json.loads(p.stdout)
        package = root / 'source'
        m = fixture(package)
        bundle = root / 'sample.tar.gz'
        data = archive(package, bundle)
        if args.suite == 'packages':
            assert run('validate', path=str(package))['id'] == m['id']
            packed = root/'native.tar.gz'
            details = run('pack',path=str(package),output=str(packed))
            assert details['sha256']==hashlib.sha256(packed.read_bytes()).hexdigest()
            assert details['size']==packed.stat().st_size
            run('pack',error='Conflict',path=str(package),output=str(packed))
            run('pack',path=str(package),output=str(root/'native-again.tar.gz'))
            assert packed.read_bytes()==(root/'native-again.tar.gz').read_bytes()
            bundle = packed
            receipt = run('import_archive', path=str(bundle))
            assert receipt['version'] == '1.0.0'
            installed = Path(env['XDG_DATA_HOME']) / 'pearl/themes' / m['id']
            catalog = run('catalog')
            assert len(catalog['entries']) == 1
            theme = dict(mode='package', package_id=m['id'], catalog_revision=catalog['revision'])
            preview = run('preview', theme=theme)
            assert preview['palette'] == PALETTE and preview['tokens']['card_radius'] == 4
            assert run('preview_render',theme=theme)['palette']==PALETTE
            assert '.pearl-root.$scope button:hover' in preview['css']
            run('preview', error='ThemeVariantUnavailable', theme=theme | dict(variant='light'))
            run('preview', error='ThemeCatalogChanged', theme=theme | dict(catalog_revision='0'*64))
            # A new, arbitrary ID becomes visible with no compiled list.
            second = root / 'second'; fixture(second, 'new.author.theme', '1.0.0')
            archive(second, root / 'second.tar.gz'); run('import_archive', path=str(root / 'second.tar.gz'))
            assert {e['id'] for e in run('catalog')['entries']} == {m['id'], 'new.author.theme'}
            # Fixed values survive cross-package style/palette selection.
            result = run('preview', theme=dict(mode='package', package_id=m['id'], palette_id='new.author.theme', style_id='pearl.default'))
            assert result['palette'] == PALETTE and result['css'] == ''
            dynamic = run('preview', theme=dict(mode='dynamic', style_id=m['id']))
            assert dynamic['palette'] is None and dynamic['tokens']['card_radius']==4
            # Duplicate IDs in system/manual packages never shadow one another.
            duplicate = Path(env['XDG_DATA_DIRS'])/'pearl/themes/duplicate'
            shutil.copytree(package,duplicate)
            run('preview',error='DuplicateThemeId',theme=dict(mode='package',package_id=m['id']))
            assert any(e['error_code']=='DuplicateThemeId' for e in run('catalog')['entries'])
            shutil.rmtree(duplicate)
            # Installed metadata is paginated, with a stable catalog revision.
            extra=[]
            for i in range(17):
                p=Path(env['XDG_DATA_HOME'])/f'pearl/themes/page-{i:02}'
                fixture(p,f'page-{i:02}');extra.append(p)
            first=run('catalog');assert len(first['entries'])==16 and len(first['ids'])==19
            second_page=run('catalog',offset=first['next_offset'],revision=first['revision'])
            assert len(second_page['entries'])==3 and second_page['next_offset'] is None
            for p in extra:shutil.rmtree(p)
            fixture(package, version='2.0.0'); archive(package, bundle)
            assert run('import_archive', path=str(bundle))['version'] == '2.0.0'
            assert run('rollback', id=m['id'])['version'] == '1.0.0'
            original = (installed/'tokens.json').read_bytes()
            (installed/'tokens.json').write_text('{"card_radius":8}')
            run('remove', error='ThemeEdited', id=m['id'])
            run('import_archive', error='ThemeEdited', path=str(bundle))
            (installed/'tokens.json').write_bytes(original)
            # Directory and asset symlinks are rejected.
            linked = root / 'linked'; shutil.copytree(package, linked)
            (linked/'dark.json').unlink(); (linked/'dark.json').symlink_to(package/'dark.json')
            run('validate', error='ThemeSpecialFile', path=str(linked))
            # Theme asset paths are not constrained to plugin identifiers.
            path_fixture=root/'paths';shutil.copytree(package,path_fixture)
            long_name='Palette with spaces '+('x'*70)+'.json'
            (path_fixture/'dark.json').rename(path_fixture/long_name)
            manifest=json.loads((path_fixture/'theme.json').read_text());manifest['palettes']['dark']=long_name
            (path_fixture/'theme.json').write_text(json.dumps(manifest))
            run('validate',path=str(path_fixture))
            # Missing/unknown roles, low contrast, unsupported schema/CSS.
            bad = root/'bad'; shutil.copytree(package, bad)
            (bad/'dark.json').write_text(json.dumps(PALETTE | dict(text=PALETTE['surface'])))
            run('validate', error='InsufficientContrast', path=str(bad))
            fixture(bad); (bad/'extra.css').write_text('* { color: #ffffff; }')
            run('validate', error='UnsupportedThemeSelector', path=str(bad))
            fixture(bad);(bad/'tokens.json').write_text('{"shadow":{"blur":255}}')
            run('validate',error='InvalidStyleToken',path=str(bad))
            fixture(bad);(bad/'extra.css').write_text('@import "extra.css";')
            run('validate',error='ThemeCssImportCycle',path=str(bad))
            fixture(bad); b = json.loads((bad/'theme.json').read_text()); b['requires']['style_api']=2; (bad/'theme.json').write_text(json.dumps(b))
            run('validate', error='UnsupportedStyleApi', path=str(bad))
            # Extraction never follows links or writes traversal paths.
            for name, kind, expected in [('../escaped', tarfile.REGTYPE, 'InvalidThemePath'), ('link', tarfile.SYMTYPE, 'ThemeArchiveSpecialFile')]:
                malicious = root/'bad.tar.gz'
                with tarfile.open(malicious, 'w:gz') as tar:
                    member = tarfile.TarInfo(name); member.type = kind
                    if kind == tarfile.SYMTYPE: member.linkname = '/tmp'
                    tar.addfile(member, io.BytesIO(b''))
                run('import_archive', error=expected, path=str(malicious))
            assert not (root/'escaped').exists()
            # Crash before/after atomic publish and receipt persistence, then
            # start another writer to exercise durable journal recovery.
            for point in ['journal', 'publish', 'receipt']:
                fixture(package, version='3.0.0'); archive(package, bundle)
                before = run('catalog')['entries'][0]['digest']
                p = subprocess.run([str(tool), json.dumps(dict(action='import_archive',path=str(bundle)))], env=env | dict(PEARL_TEST_THEME_CRASH=point), capture_output=True, timeout=60)
                assert p.returncode == 87, (point,p.stderr)
                run('source_remove', id='absent')
                assert not (Path(env['XDG_STATE_HOME'])/'pearl/themes/journal.json').exists()
                assert run('preview', theme=dict(mode='package',package_id=m['id']))['palette']==PALETTE
            for point in ['remove-journal','remove-publish']:
                run('import_archive',path=str(bundle))
                p = subprocess.run([str(tool), json.dumps(dict(action='remove',id=m['id']))], env=env | dict(PEARL_TEST_THEME_CRASH=point), capture_output=True, timeout=60)
                assert p.returncode == 87, (point,p.stderr)
                run('source_remove',id='absent')
                assert installed.exists() == (point == 'remove-journal')
            run('import_archive',path=str(bundle))
            run('remove', id=m['id'])
            assert not installed.exists()
            assert not (Path(env['XDG_CONFIG_HOME'])/'pearl/preferences.json').exists()
            print('PASS native palette/style validation, discovery, installation, rollback, ownership and hostile archives')
        else:
            cert, key = root/'cert.pem', root/'key.pem'
            subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            env['PEARL_TEST_THEME_CA'] = str(cert)
            class Handler(http.server.SimpleHTTPRequestHandler):
                def __init__(self, *a, **kw): super().__init__(*a, directory=str(root), **kw)
                def log_message(self, *args): pass
                def do_GET(self):
                    if self.path=='/insecure-redirect':
                        self.send_response(302);self.send_header('Location','http://localhost/index.json');self.end_headers()
                    else:super().do_GET()
            server = http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key)
            server.socket = ctx.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            base = f'https://localhost:{server.server_port}'
            release = {k:m[k] for k in ['id','name','author','license','source','requires']} | dict(version='1.0.0', url=base+'/sample.tar.gz', sha256=hashlib.sha256(data).hexdigest(), size=len(data), variants=['dark'], style=True)
            index = dict(schema_version=1, repository_id='fixture', releases=[release])
            (root/'index.json').write_text(json.dumps(index))
            try:
                run('source_add', id='fixture', name='Fixture community', url=base+'/index.json')
                assert run('refresh', id='fixture')['index']['releases'][0]['id'] == m['id']
                req = dict(repository='fixture', id=m['id'], version='1.0.0', sha256=release['sha256'])
                assert run('install', **req)['version'] == '1.0.0'
                run('refresh',error='ThemeDownloadFailed',id='fixture',url=base+'/insecure-redirect')
                # An arbitrary new package is published on a second page.
                fresh=root/'fresh';new=fixture(fresh,'org.newauthor.community')
                fresh_bytes=archive(fresh,root/'fresh.tar.gz')
                fresh_release=release | {k:new[k] for k in ['id','name','author','license','source','requires']}
                fresh_release.update(url=base+'/fresh.tar.gz',sha256=hashlib.sha256(fresh_bytes).hexdigest(),size=len(fresh_bytes))
                (root/'next.json').write_text(json.dumps(index | dict(releases=[fresh_release])))
                (root/'index.json').write_text(json.dumps(index | dict(next=base+'/next.json')))
                next_url=run('refresh',id='fixture')['index']['next']
                assert run('refresh',id='fixture',url=next_url)['index']['releases'][0]['id']==new['id']
                assert run('install',repository='fixture',url=next_url,id=new['id'],version='1.0.0',sha256=fresh_release['sha256'])['id']==new['id']
                (root/'other.json').write_text(json.dumps(index | dict(repository_id='other')))
                run('source_add',id='other',name='Other repository',url=base+'/other.json')
                run('refresh',id='other')
                run('install',error='ThemeRepositoryConflict',**(req | dict(repository='other')))
                run('install', error='ThemeReleaseChanged', **(req | dict(sha256='0'*64)))
                # Altered bytes are never installed even if the URL stays the same.
                (root/'sample.tar.gz').write_bytes(b'bad')
                run('install', error='ThemeDownloadDigestMismatch', **req)
                (root/'sample.tar.gz').write_bytes(data)
                changed = copy.deepcopy(index); changed['releases'][0]['sha256']='0'*64
                # Deleting a release and reintroducing it on a different page
                # does not erase its durable immutable identity.
                (root/'index.json').write_text(json.dumps(index | dict(releases=[])))
                run('refresh',id='fixture')
                (root/'page2.json').write_text(json.dumps(changed))
                run('refresh',error='MutableThemeRelease',id='fixture',url=base+'/page2.json')
                (root/'index.json').write_text(json.dumps(changed))
                run('refresh', error='MutableThemeRelease', id='fixture')
                (root/'index.json').write_text(json.dumps(index))
                run('refresh', id='fixture')
                # Production requires authenticated HTTPS; test hooks only inject trust.
                run('source_add', error='HttpsRequired', id='http', name='No TLS', url='http://localhost/index.json')
            finally:
                server.shutdown(); server.server_close(); thread.join()
            page = run('refresh', id='fixture')
            assert page['offline'] and page['index']['releases'][0]['id']==m['id']
            assert run('catalog')['entries'][0]['id']==m['id']
            run('source_remove', id='fixture')
            assert run('catalog')['entries'][0]['id']==m['id']
            print('PASS native HTTPS repository, pinned release download, digest failures, immutable versions and offline cache')

if __name__ == '__main__': main()
