#!/usr/bin/env python3
"""Direct GitHub themes: private HTTPS API/raw fixtures, no index or archives."""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading
from urllib.parse import unquote, urlsplit
from test_theme_packages import fixture, PALETTE

REPO = 'Seafoam-Labs/pearl-community-themes'
URL = 'https://github.com/' + REPO
LEGACY = 'https://raw.githubusercontent.com/' + REPO + '/main/index.json'
REVISION = 'a' * 40


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tool', type=Path, required=True)
    parser.add_argument("--default-enabled", action="store_true")
    args = parser.parse_args()
    tool = args.tool.resolve()
    with tempfile.TemporaryDirectory(prefix='pearl-github-test-') as tmp:
        root = Path(tmp)
        env = os.environ | {f'XDG_{kind}_HOME': str(root / kind.lower()) for kind in ['CONFIG', 'DATA', 'STATE', 'CACHE']}
        env['XDG_DATA_DIRS'] = str(root/'system')
        routes, requests, folders = {}, [], []
        for i in range(17):
            folder = f'themes/sample-{i:02}'
            package = root/folder
            manifest = fixture(package, key=f'community.sample-{i:02}')
            # Raw URLs must correctly encode asset names with spaces and #.
            if i == 0:
                (package/'dark.json').rename(package/'dark #1.json')
                manifest['palettes']['dark'] = 'dark #1.json'
                (package/'theme.json').write_text(json.dumps(manifest))
            (package/'LICENSE').write_text('CC0-1.0')
            (package/'ATTRIBUTION.md').write_text('Original test fixture')
            entries = []
            for file in sorted(package.iterdir()):
                data = file.read_bytes()
                sha = hashlib.sha1(f'blob {len(data)}\0'.encode()+data).hexdigest()
                entries.append(dict(path=file.name, type='blob', mode='100644', sha=sha, size=len(data)))
                routes[f'/raw/{REPO}/{REVISION}/{folder}/{file.name}'] = data
            tree_sha = hashlib.sha1(json.dumps(entries).encode()).hexdigest()
            routes[f'/api/repos/{REPO}/git/trees/{tree_sha}'] = dict(sha=tree_sha, truncated=False, tree=entries)
            folders.append(dict(path=folder, type='tree', mode='040000', sha=tree_sha))
            folders.extend(dict(entry, path=folder+'/'+entry['path']) for entry in entries)
        routes[f'/api/repos/{REPO}/commits/HEAD'] = dict(sha=REVISION, ignored_field='API evolution')
        tree_route = f'/api/repos/{REPO}/git/trees/{REVISION}'
        routes[tree_route] = dict(sha='b'*40, truncated=False, tree=folders)
        cert, key = root/'cert.pem', root/'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        env['PEARL_TEST_THEME_CA'] = str(cert)
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                requests.append(self.path)
                path = unquote(urlsplit(self.path).path)
                data = routes.get(path)
                if data is None:
                    self.send_error(404)
                    return
                if not isinstance(data, bytes): data = json.dumps(data).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env['PEARL_TEST_GITHUB_BASE'] = f'https://localhost:{server.server_port}'
        def run(action, error=None, **fields):
            result = subprocess.run([tool, json.dumps(dict(action=action, **fields))], env=env, capture_output=True, text=True, timeout=60)
            if error:
                assert result.returncode and error in result.stderr, (action, result.stdout, result.stderr)
                return
            assert result.returncode == 0, (action, result.stdout, result.stderr)
            return json.loads(result.stdout)
        try:
            default = dict(id='seafoam-community', name='Pearl community themes', url=URL)
            assert run('catalog')['sources'] == ([default] if args.default_enabled else [])
            if not args.default_enabled: run('source_add', **default)
            assert not requests, 'Catalog must not perform startup network access'
            spec = root/'publication.json'
            spec.write_text(json.dumps(dict(schema_version=1, repository_id='archive-test', index_url='https://example.org/index.json', packages=[dict(path=str(root/'themes/sample-00'), url='https://example.org/sample.tar.gz')])))
            run('publish_build', path=str(spec), output=str(root/'publication'))
            published = json.loads((root/'publication/index.json').read_text())
            assert published['schema_version'] == 2 and 'github' not in published['releases'][0]
            first = run('refresh', id='seafoam-community')['index']
            assert len(first['releases']) == 16 and first['next'] == URL+f'?ref={REVISION}&offset=16'
            # A moving HEAD cannot change the next page of this catalog snapshot.
            routes[f'/api/repos/{REPO}/commits/HEAD'] = dict(sha='c'*40)
            second = run('refresh', id='seafoam-community', url=first['next'])['index']
            assert len(second['releases']) == 1 and second['next'] is None
            release = first['releases'][0]
            request = dict(repository='seafoam-community', id=release['id'], version=release['version'], sha256=release['sha256'])
            assert run('install', **request)['id'] == release['id']
            assert run('preview', theme=dict(mode='package', package_id=release['id']))['palette'] == PALETTE
            installed = root/'data/pearl/themes'/release['id']
            assert (installed/'dark #1.json').is_file()
            assert not any('index.json' in r or '.tar.gz' in r or '/releases/' in r for r in requests)
            # Altering a raw asset is caught even if its byte length is unchanged.
            asset = f'/raw/{REPO}/{REVISION}/themes/sample-00/dark #1.json'
            original = routes[asset]
            routes[asset] = original.replace(b'#101c19', b'#101c18')
            run('install', error='ThemeDownloadDigestMismatch', **request)
            assert (installed/'dark #1.json').read_bytes() == original
            assert not list((root/'cache/pearl/theme-downloads').iterdir())
            routes[asset] = original
            # A symlink/submodule or traversal cannot enter staging.
            subtree = routes[f'/api/repos/{REPO}/git/trees/{release["github"]["tree"]}']
            for mode, kind, expected in [('120000', 'blob', 'ThemeSpecialFile'), ('160000', 'commit', 'ThemeSpecialFile')]:
                old_mode, old_type = subtree['tree'][0]['mode'], subtree['tree'][0]['type']
                subtree['tree'][0].update(mode=mode, type=kind)
                run('install', error=expected, **request)
                subtree['tree'][0].update(mode=old_mode, type=old_type)
            old_path = subtree['tree'][0]['path']
            subtree['tree'][0]['path'] = '../escape'
            run('install', error='InvalidThemePath', **request)
            subtree['tree'][0]['path'] = old_path
            routes[f'/api/repos/{REPO}/commits/HEAD'] = dict(sha=REVISION)
            routes[tree_route]['truncated'] = True
            run('refresh', id='seafoam-community', error='GithubTreeLimit')
            routes[tree_route]['truncated'] = False
            # A changed theme requires a new asset_version, even across refreshes.
            old_sha = folders[0]['sha']
            folders[0]['sha'] = 'd'*40
            run('refresh', id='seafoam-community', error='MutableThemeRelease')
            folders[0]['sha'] = old_sha
            # Previously recommended raw URL now uses discovery instead of a missing index.
            run('source_add', id='legacy', name='Legacy URL', url=LEGACY)
            # Existing archive metadata uses a different hash scheme. Its history
            # must not prevent the one-time move to direct GitHub files.
            old_release = dict(release, github=None, sha256='0'*64)
            old_index = dict(schema_version=2, repository_id='legacy', releases=[old_release])
            cache = root/'cache/pearl/theme-repositories'/('legacy-'+hashlib.sha256(LEGACY.encode()).hexdigest()+'.json')
            cache.write_text(json.dumps(old_index))
            history = root/'state/pearl/theme-repository-history'/hashlib.sha256(LEGACY.encode()).hexdigest()
            history.mkdir(parents=True)
            (history/(release['id']+'-'+release['version']+'.sha256')).write_text('0'*64)
            legacy = run('refresh', id='legacy')
            assert legacy['index']['releases'][0]['github']['repository'] == REPO
            # Failures reuse validated metadata; no failed download alters installed files.
            del routes[f'/api/repos/{REPO}/commits/HEAD']
            offline = run('refresh', id='seafoam-community')
            assert offline['offline'] and offline['index'] == first
            run('source_remove', id='seafoam-community')
            assert all(s['id'] != 'seafoam-community' for s in run('catalog')['sources'])
            print('PASS direct GitHub discovery, pinned pagination, raw installation, preview, integrity, hostile entries, legacy URL, offline cache and default removal')
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__': main()
