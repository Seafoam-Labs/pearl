"""Dependency diagnosis and workspace-only fixture preparation."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

from test_process import atomic_json, execute, sha
from test_suites import ROOT

PACKAGES = {
    'glib': ['glib-2.0'],
    'native': ['gtk4 >= 4.22.5', 'glib-2.0 >= 2.88.3', 'gtk4-layer-shell-0 >= 1.3.0',
               'libpulse >= 17.0', 'libpulse-mainloop-glib >= 17.0', 'polkit-agent-1 >= 127',
               'pam >= 1.7.2', 'wayland-client', 'libcurl', 'libarchive', 'libpng'],
    'aqueous-build': ['wayland-protocols >= 1.49', 'wayland-server', 'xkbcommon',
                      'libinput', 'libevdev', 'pixman-1', 'libdrm', 'libdisplay-info',
                      'libliftoff', 'lcms2', 'vulkan', 'gbm', 'libseat'],
    'qt': ['Qt5Widgets', 'Qt6Widgets >= 6.6'],
    'coral': ['gtksourceview-5', 'enchant-2'],
    'pam-upstream': ['libsystemd', 'pam'],
}
TOOLS = {
    'native': ['cc', 'glib-compile-resources'],
    'session': ['dbus-daemon', 'busctl', 'grim', 'wayland-scanner', 'cc', 'fc-match',
                'wlr-randr', 'wlrctl', 'wtype', 'wl-copy', 'wl-paste', 'gdbus',
                'pipewire', 'pipewire-pulse', 'pactl', 'pacat', 'pw-metadata',
                'desktop-file-validate', 'notify-send'],
    'bus': ['dbus-daemon', 'busctl'],
    'profile-formats': ['luac', 'nvim'],
    'gvfs': ['/usr/lib/gvfsd', '/usr/lib/gvfsd-metadata'],
    'aqueous-build': ['git', 'cc', 'curl', 'meson', 'ninja', 'patch', 'glslangValidator', 'Xwayland'],
    'plugins': ['cargo', 'rustc', 'rsvg-convert'],
    'previews': ['bwrap', 'pdftoppm', 'ffmpeg'],
    'tls': ['openssl'],
    'matugen': ['matugen'],
}
ARCH_PACKAGES = ('base-devel git zig python python-pillow python-gobject pkgconf gtk4 '
                 'gtk4-layer-shell libpulse pam polkit curl libarchive libpng dbus '
                 'grim wayland wayland-protocols ttf-dejavu matugen meson ninja '
                 'glslang vulkan-headers vulkan-icd-loader mesa libinput libevdev '
                 'libxkbcommon pixman libdrm libdisplay-info libliftoff lcms2 seatd '
                 'xorg-xwayland libxcb xcb-util-errors xcb-util-wm xcb-util-renderutil hwdata '
                 'python-pip wlr-randr wlrctl wtype wl-clipboard pipewire pipewire-pulse '
                 'libnotify desktop-file-utils at-spi2-core')


class PrerequisiteError(ValueError):
    pass


def capture(command, env=None, cwd=None):
    try:
        p = subprocess.run([str(v) for v in command], env=env, cwd=cwd,
                           capture_output=True, text=True, timeout=20)
        return p.returncode, (p.stdout + p.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        return 127, str(error)


class Environment:
    def __init__(self, args, root=ROOT):
        self.args, self.root = args, root
        self.cache = root / '.cache/test-runner'
        self.target = json.loads((root / 'scripts/aqueous-target.json').read_text())
        self.version = (root / '.zigversion').read_text().strip()
        self.downloads = json.loads((root / 'scripts/test-downloads.json').read_text())
        self.env = dict(os.environ)
        self.env['ZIG_GLOBAL_CACHE_DIR'] = str(root / '.cache/zig')
        self.env['PYTHONUNBUFFERED'] = '1'
        # Honor the interpreter that launches the runner, including a caller's venv.
        python = self.cache / 'python/bin/python3'
        self.python = str(python if python.exists() else Path(sys.executable).absolute())
        zigdir = self.cache / 'tools/zig'
        self.zig = str(zigdir / 'zig') if (zigdir / 'zig').exists() else 'zig'
        self.env['PATH'] = os.pathsep.join([str(Path(self.python).parent), str(zigdir), self.env.get('PATH', '')])
        state = self.cache / 'prepared.json'
        self.prepared = json.loads(state.read_text()) if state.exists() else {}
        self.check_cache = {}

    def prefix(self, variant='production'):
        if variant == 'production' and self.args.aqueous_prefix:
            return self.args.aqueous_prefix.resolve()
        path = self.prepared.get(variant, {}).get('prefix')
        return Path(path) if path else self.cache / 'aqueous' / variant

    def values(self, suite):
        prefix = self.prefix(suite.get('fixture') or 'production')
        return dict(root=str(self.root), python=self.python, zig=self.zig,
                    prefix=str(prefix), source=str(prefix / 'source'),
                    wasmtime=str(self.cache / 'tools/wasmtime'),
                    examples=str(self.cache / 'plugin-examples'))

    def suite_env(self, suite):
        env = dict(self.env)
        if suite.get('fixture'):
            prefix = self.prefix(suite['fixture'])
            env.update(PEARL_TEST_AQUEOUS_PREFIX=str(prefix),
                       PEARL_TEST_AQUEOUS_SOURCE=str(prefix / 'source'))
        env['PEARL_TEST_PYTHON'] = self.python
        return env

    def package_hint(self, caps):
        if caps <= {'python', 'zig', 'glib'}:
            return 'Ubuntu: sudo apt-get install libglib2.0-dev pkg-config python3 tzdata; then run prepare.'
        extra = ''
        if 'qt' in caps:
            extra += ' qt5-base qt6-base qtengine pearl-darkly-style'
        if 'plugins' in caps:
            extra += ' rust rust-wasm librsvg'
        if 'coral' in caps:
            extra += ' gtksourceview5 enchant hunspell hunspell-en_us'
        if 'previews' in caps:
            extra += ' bubblewrap poppler ffmpeg'
        if 'profile-formats' in caps:
            extra += ' lua neovim'
        if 'gvfs' in caps:
            extra += ' gvfs'
        return 'Arch-based Linux (review package availability): sudo pacman -S --needed ' + ARCH_PACKAGES + extra

    def check(self, suite, preparing=False):
        caps = set(suite['capabilities'])
        if preparing and suite.get('fixture'):
            caps.add('aqueous-build')
        issues, versions = [], {}
        if platform.system() != 'Linux' or platform.machine() not in ('x86_64', 'AMD64'):
            issues.append('The native runner currently supports x86_64 Linux.')
        if sys.version_info < (3, 12):
            issues.append('Python 3.12 or newer is required for the runner.')
        if not str(self.root).isascii() and 'zig' in caps:
            issues.append('Use an ASCII checkout path; pinned Zig header translation cannot handle this path.')
        declared = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', (self.root / 'build.zig.zon').read_text())
        if not declared or declared[1] != self.version:
            issues.append('.zigversion and build.zig.zon disagree; repair the toolchain pin.')
        if 'zig' in caps:
            code, found = capture([self.zig, 'version'], self.env)
            versions['zig'] = found
            if (code or found != self.version) and not preparing:
                issues.append(f'Zig {self.version} required; detected {found}. Run prepare for this selection.')
        for cap in sorted(caps):
            for tool in TOOLS.get(cap, []):
                if not shutil.which(tool, path=self.env['PATH']):
                    issues.append(f'Missing executable {tool} ({cap}).')
            for expression in PACKAGES.get(cap, []):
                if expression not in self.check_cache:
                    code, detail = capture(['pkg-config', '--print-errors', '--exists', expression], self.env)
                    _, version = capture(['pkg-config', '--modversion', expression.split()[0]], self.env)
                    self.check_cache[expression] = (code, detail, version)
                code, detail, version = self.check_cache[expression]
                versions[expression.split()[0]] = version
                if code:
                    issues.append(f'Required {expression}; {detail}')
        if caps & {'session', 'qt', 'previews', 'bus'}:
            imports = 'import PIL; import gi; gi.require_version("Gtk", "4.0"); from gi.repository import Gtk, Gio, GLib'
            code, detail = capture([self.python, '-c', imports], self.env)
            # PyGObject comes from the OS; only Pillow is bootstrapped by prepare.
            if code and not (preparing and 'No module named \'PIL\'' in detail):
                issues.append(f'Fixture Python imports failed ({self.python}): {detail}')
        if 'matugen' in caps:
            code, version = capture(['matugen', '--version'], self.env)
            versions['matugen'] = version
            match = re.search(r'(\d+)\.(\d+)', version)
            if code or not match or tuple(map(int, match.groups())) < (4, 2):
                issues.append('matugen >= 4.2 is required for this suite.')
        if 'qt' in caps:
            # Validate both plugin installations, rather than merely the Qt headers.
            for tool, subdirectory in (('qmake', 'qt'), ('qmake6', 'qt6')):
                code, path = capture([tool, '-query', 'QT_INSTALL_PLUGINS'], self.env)
                base = self.args.qt_prefix
                paths = [Path(path)] if not code else []
                if base:
                    paths = [base / 'lib' / subdirectory / 'plugins']
                if not any(list(p.glob('platformthemes/*qtengine*')) and list(p.glob('styles/*darkly*')) for p in paths):
                    issues.append(f'{tool}: install QtEngine and Darkly plugins or supply --qt-prefix.')
        if suite.get('fixture') and not preparing:
            issues.extend(self.validate_prefix(suite['fixture']))
        if 'plugins' in caps and not preparing:
            for path in ['tools/wasmtime/include/wasmtime.h', 'tools/wasmtime/lib/libwasmtime.a',
                         'plugin-examples/counter-rust/plugin.wasm', 'plugin-examples/activity-fixture/plugin.wasm']:
                if not (self.cache / path).exists():
                    issues.append(f'Missing {path}; run prepare --group plugins.')
        if 'plugins' in caps:
            code, directory = capture(['rustc', '--print', 'target-libdir', '--target', 'wasm32-wasip2'], self.env)
            if code or not list(Path(directory).glob('libcore-*.rlib')):
                issues.append('Rust wasm32-wasip2 standard library is missing; install rust-wasm or run rustup target add wasm32-wasip2.')
        if 'pam-upstream' in caps and not preparing and not (self.cache / 'fingerprint/pam_fprintd.so').exists():
            issues.append('Missing private pam_fprintd module; run prepare --group upstream.')
        if 'schema' in caps and not preparing:
            code, detail = capture([self.python, '-c', 'import jsonschema'], self.env)
            if code:
                issues.append('Missing jsonschema dependencies; run prepare --group upstream.')
        return dict(issues=list(dict.fromkeys(issues)), versions=versions, hint=self.package_hint(caps))

    def validate_prefix(self, variant):
        prefix = self.prefix(variant)
        try:
            meta = json.loads((prefix / 'metadata.json').read_text())
            if meta.get('status') != 'passed' or meta.get('revision') != self.target['revision']:
                raise ValueError('revision/status mismatch')
            if bool(meta.get('input_activity_testing')) != (variant == 'activity'):
                raise ValueError('diagnostic build variant mismatch')
            library = Path(meta['patched_wlroots_pkgconfig'])
            if not library.is_absolute():
                library = prefix / library
            library = library.parent / 'libwlroots-0.20.so'
            if sha(library) != meta['wlroots_sha256']:
                raise ValueError('wlroots hash mismatch')
            for name in ('aqueous', 'aqueousctl', 'aqueous-config'):
                if sha(prefix / 'bin' / name) != meta['binary_sha256'][name]:
                    raise ValueError(f'{name} hash mismatch')
            if (prefix / 'source/.pearl-revision').read_text() != self.target['revision']:
                raise ValueError('input fixture source mismatch')
            helper = meta.get('helper', {})
            version_tuple = lambda value: tuple(int(part) for part in value.split('.'))
            if version_tuple(helper.get('version', '0')) < version_tuple(self.target['helper']):
                raise ValueError('helper is older than the required version floor')
            required = {'protected_collection_apply_v1', 'display_declaration_mutations_v1'}
            if not required <= set(helper.get('capabilities', [])):
                raise ValueError('helper lacks required collection/display capabilities')
            recorded = self.prepared.get(variant, {})
            if not (variant == 'production' and self.args.aqueous_prefix) and recorded.get('inputs') != self.fixture_inputs(variant):
                raise ValueError('prepared toolchain, libraries, or builder changed')
            return []
        except (OSError, ValueError, KeyError) as error:
            return [f'{variant} Aqueous fixture is unavailable or incompatible at {prefix}: {error}. Run prepare.']

    def fixture_inputs(self, variant):
        libraries = {}
        for expression in PACKAGES['native'] + PACKAGES['aqueous-build']:
            name = expression.split()[0]
            _, libraries[name] = capture(['pkg-config', '--modversion', name], self.env)
        return dict(revision=self.target['revision'], zig=self.version, variant=variant,
                    machine=platform.machine(), libraries=libraries,
                    builder=sha(self.root / 'scripts/build-aqueous-master.py'),
                    preparer=sha(Path(__file__)))

    def smoke(self, variant, output, echo=True):
        """Use the same sanitized private session environment as actual suites."""
        script = (
            'import sys; from pathlib import Path; '
            f'sys.path.insert(0, {str(self.root / "scripts")!r}); '
            'from pearl_session import PrivateSession\n'
            f'with PrivateSession(Path({str(output / "session")!r}), '
            f'tool_prefix=Path({str(self.prefix(variant))!r})) as s:\n'
            ' s.run(["grim", str(s.output / "smoke.png")])\n'
            ' print("Private compositor and screenshot probe passed")\n'
        )
        return execute([self.python, '-c', script], self.root, self.env, output / 'smoke.log', 60, echo=echo)

    def fetch(self, name, output, logdir):
        spec = self.downloads[name]
        archive = self.cache / 'downloads' / spec['url'].rsplit('/', 1)[-1]
        archive.parent.mkdir(parents=True, exist_ok=True)
        if not archive.exists() or sha(archive) != spec['sha256']:
            if self.args.offline:
                raise PrerequisiteError(f'Offline cache missing or corrupt: {archive}')
            tmp = archive.with_suffix('.part')
            print('Downloading ' + spec['url'], flush=True)
            try:
                with urllib.request.urlopen(spec['url'], timeout=60) as response, tmp.open('wb') as dest:
                    shutil.copyfileobj(response, dest)
                if sha(tmp) != spec['sha256']:
                    raise PrerequisiteError(f'Checksum mismatch for {name}; cached archive was not replaced.')
                tmp.replace(archive)
            finally:
                tmp.unlink(missing_ok=True)
        if output:
            if output.exists():
                stamp = output / '.archive-sha256'
                manifest = output / '.files.json'
                if stamp.exists() and stamp.read_text() == spec['sha256'] and manifest.exists():
                    hashes = json.loads(manifest.read_text())
                    if all((output / p).is_file() and sha(output / p) == digest for p, digest in hashes.items()):
                        return output
                raise PrerequisiteError(f'Unrecognized tool directory {output}; move it aside before preparing.')
            output.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(dir=output.parent) as directory:
                with tarfile.open(archive) as source:
                    source.extractall(directory, filter='data')
                children = list(Path(directory).iterdir())
                if len(children) != 1 or not children[0].is_dir():
                    raise PrerequisiteError(f'Unexpected archive layout: {name}')
                (children[0] / '.archive-sha256').write_text(spec['sha256'])
                atomic_json(children[0] / '.files.json', {str(p.relative_to(children[0])): sha(p)
                            for p in children[0].rglob('*') if p.is_file()})
                children[0].rename(output)
        return archive if output is None else output

    def run_setup(self, command, name, logdir, cwd=None, env=None):
        print('Preparing ' + name, flush=True)
        code = execute(command, cwd or self.root, env or self.env, logdir / (name + '.log'), 3600)
        if code:
            raise PrerequisiteError(f'{name} failed (exit {code}); see {logdir / (name + ".log")}')

    def prepare(self, suites, logdir):
        caps = {cap for suite in suites for cap in suite['capabilities']}
        variants = sorted({s['fixture'] for s in suites if s.get('fixture')})
        problems = {s['id']: self.check(s, preparing=True)['issues'] for s in suites}
        problems = {k: v for k, v in problems.items() if v}
        if problems:
            raise PrerequisiteError(json.dumps(problems, indent=2) + '\n' + self.package_hint(caps))
        if 'zig' in caps:
            code, version = capture([self.zig, 'version'], self.env)
            if code or version != self.version:
                self.fetch('zig', self.cache / 'tools/zig', logdir)
                self.zig = str(self.cache / 'tools/zig/zig')
                code, version = capture([self.zig, 'version'], self.env)
                if code or version != self.version:
                    raise PrerequisiteError('Downloaded Zig does not match .zigversion; update the pinned download manifest.')
        if caps & {'session', 'qt', 'previews', 'schema', 'bus'}:
            if not (self.cache / 'python/bin/python3').exists():
                self.run_setup([sys.executable, '-m', 'venv', '--system-site-packages', str(self.cache / 'python')], 'python-environment', logdir)
            self.python = str(self.cache / 'python/bin/python3')
            self.env['PATH'] = str(Path(self.python).parent) + os.pathsep + self.env['PATH']
            requirements = ['tests/runner-requirements.txt']
            if 'schema' in caps:
                requirements.append('tests/fixtures/aqueous-master/schema-test-requirements.txt')
            for i, requirement in enumerate(requirements):
                command = [self.python, '-m', 'pip', 'install', '-r', str(self.root / requirement)]
                if self.args.offline:
                    command += ['--no-index', '--find-links', str(self.cache / 'wheels')]
                else:
                    self.run_setup([self.python, '-m', 'pip', 'download', '-r', str(self.root / requirement),
                                    '--dest', str(self.cache / 'wheels')], f'python-download-{i}', logdir)
                self.run_setup(command, f'python-dependencies-{i}', logdir)
        if variants:
            source = self.args.aqueous_source
            if source:
                source = source.resolve()
            elif any(v != 'production' or not self.args.aqueous_prefix for v in variants):
                source = self.cache / 'aqueous.git'
                if not source.exists():
                    if self.args.offline:
                        raise PrerequisiteError('Offline mode needs --aqueous-source or a prepared Git cache.')
                    self.run_setup(['git', 'init', '--bare', str(source)], 'aqueous-git-init', logdir)
            code, _ = capture(['git', '-C', source, 'cat-file', '-e', self.target['revision'] + '^{commit}']) if source else (0, '')
            if code:
                if self.args.offline or self.args.aqueous_source:
                    raise PrerequisiteError(f'{source} does not contain pinned commit {self.target["revision"]}. Fetch it first.')
                self.run_setup(['git', '-C', source, 'fetch', '--depth=1', self.target['source_url'], self.target['revision']], 'aqueous-fetch', logdir)
            for variant in variants:
                if variant == 'production' and self.args.aqueous_prefix:
                    errors = self.validate_prefix(variant)
                    if errors:
                        raise PrerequisiteError('\n'.join(errors))
                    continue
                inputs = self.fixture_inputs(variant)
                key = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()[:20]
                prefix = self.cache / 'aqueous' / (variant + '-' + key)
                self.prepared[variant] = dict(prefix=str(prefix), inputs=inputs)
                if self.validate_prefix(variant):
                    command = [self.python, 'scripts/build-aqueous-master.py', '--source', str(source), '--prefix', str(prefix), '--jobs', str(self.args.jobs)]
                    if self.args.offline:
                        command.append('--offline')
                    if variant != 'production':
                        command.append('--' + ('activity-testing' if variant == 'activity' else 'bootstrap-testing'))
                    self.run_setup(command, 'aqueous-' + variant, logdir)
                errors = self.validate_prefix(variant)
                if errors:
                    raise PrerequisiteError('\n'.join(errors))
        if 'plugins' in caps:
            for name in ('wasmtime', 'wit-bindgen', 'wasm-tools'):
                self.fetch(name, self.cache / 'tools' / name, logdir)
            cargo_env = dict(self.env, CARGO_HOME=str(self.cache / 'cargo'), CARGO_NET_OFFLINE=str(self.args.offline).lower())
            self.run_setup(['cargo', 'fetch', '--locked', *(['--offline'] if self.args.offline else []),
                            '--manifest-path', 'plugins/examples/counter-rust/Cargo.toml'], 'plugin-cargo', logdir, env=cargo_env)
            self.run_setup([self.python, 'plugins/build-examples.py', '--fixtures', '--wit-bindgen',
                            str(self.cache / 'tools/wit-bindgen/wit-bindgen'), '--wasm-tools',
                            str(self.cache / 'tools/wasm-tools/wasm-tools'), '--output',
                            str(self.cache / 'plugin-examples')], 'plugin-examples', logdir, env=cargo_env)
        if 'pam-upstream' in caps:
            dest = self.cache / 'fingerprint'
            if not (dest / 'pam_fprintd.so').exists():
                archive = self.fetch('fprintd', None, logdir)
                self.run_setup([self.python, 'scripts/prepare-fingerprint-pam.py', '--archive', str(archive), '--output', str(dest)], 'fingerprint', logdir)
        # Fetch complete graphs, including lazy dependencies, ahead of offline runs.
        for cwd in sorted({s['cwd'] for s in suites if s.get('targets')}):
            command = [self.zig, 'build', '--fetch=all']
            if self.args.offline:
                command += ['--system', str(self.root / cwd / 'zig-pkg')]
            self.run_setup(command, 'zig-fetch-' + cwd.replace('/', '-').replace('.', 'root'), logdir, self.root / cwd)
        for variant in variants:
            if self.smoke(variant, logdir / variant):
                raise PrerequisiteError(f'{variant} compositor smoke test failed; see {logdir / variant}.')
        atomic_json(self.cache / 'prepared.json', self.prepared)
        atomic_json(logdir / 'prepared.json', dict(status='passed', variants=self.prepared))
