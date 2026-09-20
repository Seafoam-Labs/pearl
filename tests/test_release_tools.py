#!/usr/bin/env python3
"""Release tooling must fail closed and archives must exclude local state."""
import hashlib, importlib.util, json, os, shutil, subprocess, tempfile, unittest, tarfile
import xml.etree.ElementTree as ET
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/('release-'+name+'.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
gate=module('gate');source=module('source')
def write(root,path,value):
    p=root/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(value))
class ReleaseTools(unittest.TestCase):
    def test_missing_evidence_is_not_release_ready(self):
        with tempfile.TemporaryDirectory() as t:
            result=gate.evaluate(Path(t));self.assertFalse(result['release_ready']);self.assertIn('functional',result['pending_or_failed']);self.assertIn('accessibility',result['pending_or_failed'])
    def test_passed_label_without_full_matrix_is_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);write(root,'functional/metadata.json',{'status':'passed','targets':{'unit':{'exit_code':0}}})
            self.assertFalse(gate.evaluate(root)['checks']['functional'])
    def test_missing_manual_evidence_cannot_be_signed_off(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);binary={'pearl':'a','pearlctl':'b','pearl-lock':'c'}
            write(root,'package/metadata.json',{'status':'passed','binary_sha256':binary})
            write(root,'manual.json',{'binary_sha256':binary,'checks':{n:{'status':'passed','reviewer':'Fixture','date':'2026-09-14','machine':'Fixture','notes':'Fixture','evidence':'missing','evidence_sha256':'x'} for n in gate.MANUAL}})
            self.assertTrue(all(not gate.evaluate(root)['checks'][n] for n in gate.MANUAL))
    def test_settings_binary_is_required_in_release_manifest(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);binary={'pearl':'a','pearlctl':'b','pearl-lock':'c'}
            write(root,'package/metadata.json',{'status':'passed','binary_sha256':binary})
            self.assertFalse(gate.evaluate(root)['checks']['package'])
            binary['pearl-settings']='d'
            write(root,'package/metadata.json',{'status':'passed','binary_sha256':binary})
            self.assertTrue(gate.evaluate(root)['checks']['package'])
            self.assertFalse(gate.evaluate(root)['release_ready'])
    def test_archive_is_deterministic_and_ignores_local_artifacts(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t)/'source';root.mkdir();write(root,'packaging/release.json',{'arch_pkgver':'1','version':'1','source_date_epoch':1})
            (root/'packaging/arch').mkdir();(root/'packaging/arch/PKGBUILD').write_text("sha256sums=('@SOURCE_SHA256@')\n");(root/'README.md').write_text('fixture')
            write(root,'plugins/wit/plugin.wit',{'included':True})
            write(root,'plugins/examples/rust/target/generated.wasm',{'excluded':True})
            write(root,'subprojects/phyto/src/main.zig',{'included':True})
            write(root,'subprojects/phyto/packaging/org.aqueous.Phyto.desktop',{'included':True})
            write(root,'subprojects/dome/build.zig',{'included':True})
            write(root,'subprojects/dome/src/main.zig',{'included':True})
            write(root,'subprojects/dome/packaging/org.aqueous.Dome.desktop',{'included':True})
            for directory in ('zig-out', 'zig-pkg', '.zig-cache', '.cache', 'artifacts', '__pycache__'):
                write(root,f'subprojects/phyto/{directory}/local',{'excluded':True})
                write(root,f'subprojects/dome/{directory}/local',{'excluded':True})
            write(root,'subprojects/unrelated/src/main.zig',{'excluded':True})
            first=source.archive(root,Path(t)/'one');write(root,'artifacts/private.json',{'ignored':True});second=source.archive(root,Path(t)/'two')
            with tarfile.open(Path(t)/'one'/first['archive']) as archive:
                self.assertIn('pearl-1/plugins/wit/plugin.wit',archive.getnames())
                self.assertFalse(any('/target/' in name for name in archive.getnames()))
                self.assertEqual({name for name in archive.getnames() if '/subprojects/' in name}, {
                    'pearl-1/subprojects/phyto/src/main.zig',
                    'pearl-1/subprojects/phyto/packaging/org.aqueous.Phyto.desktop',
                    'pearl-1/subprojects/dome/build.zig',
                    'pearl-1/subprojects/dome/src/main.zig',
                    'pearl-1/subprojects/dome/packaging/org.aqueous.Dome.desktop',
                })
            self.assertEqual(first,second);self.assertIn(first['sha256'],(Path(t)/'one/PKGBUILD').read_text())
            (root/'src').mkdir();(root/'src/link').symlink_to(root/'README.md')
            with self.assertRaises(ValueError):source.archive(root,Path(t)/'three')
    def test_standalone_app_payloads_in_each_pearl_package(self):
        # Run real package() functions with inert build outputs in a private root.
        with tempfile.TemporaryDirectory() as t:
            work=Path(t);root=work/'pearl';root.mkdir()
            for directory in ('packaging','bindings/licenses'):
                shutil.copytree(ROOT/directory,root/directory)
            for name in ('README.md','docs/RELEASE.md','plugins/wit/plugin.wit',
                         'subprojects/phyto/packaging/org.aqueous.Phyto.desktop',
                         'subprojects/phyto/resources/org.aqueous.Phyto.svg'):
                target=root/name;target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(ROOT/name,target)
            binary=root/'zig-out/bin';binary.mkdir(parents=True)
            for name in ('pearl','pearlctl','pearl-lock','pearl-settings','pearl-themes','pearl-plugin-host'):
                (binary/name).write_bytes(b'package fixture\n')
            license_file=root/'zig-out/share/licenses/pearl/Wasmtime-LICENSE'
            license_file.parent.mkdir(parents=True);license_file.write_text('fixture')
            phyto=root/'subprojects/phyto/zig-out/bin/phyto'
            phyto.parent.mkdir(parents=True);phyto.write_bytes(b'Phyto production fixture\n')
            # Populate both Dome variants so a recipe cannot accidentally install
            # an executable or launcher from the other build identity.
            dome=root/'subprojects/dome/zig-out'
            for git in (False,True):
                command='dome-git' if git else 'dome'
                identity='org.aqueous.Dome.Git' if git else 'org.aqueous.Dome'
                executable=dome/'bin'/command
                executable.parent.mkdir(parents=True,exist_ok=True)
                executable.write_bytes(f'{command} production fixture\n'.encode())
                for source_name,destination in (
                    ('packaging/org.aqueous.Dome.desktop',f'share/applications/{identity}.desktop'),
                    ('packaging/org.aqueous.Dome.metainfo.xml',f'share/metainfo/{identity}.metainfo.xml'),
                    ('resources/org.aqueous.Dome.svg',f'share/icons/hicolor/scalable/apps/{identity}.svg'),
                ):
                    content=(ROOT/'subprojects/dome'/source_name).read_text()
                    content=content.replace('org.aqueous.Dome',identity)
                    content=content.replace('Exec=dome',f'Exec={command}')
                    content=content.replace('<binary>dome</binary>',f'<binary>{command}</binary>')
                    target=dome/destination;target.parent.mkdir(parents=True,exist_ok=True)
                    target.write_text(content)
            for example in ('timer-c','counter-zig','counter-rust','companion-c'):
                for member in ('plugin.json','plugin.wasm'):
                    write(root,f'.cache/plugin-examples/{example}/{member}',{})
            for member in ('cat.png','LICENSE.assets'):
                write(root,f'.cache/plugin-examples/companion-c/{member}',{})
            version=json.loads((ROOT/'packaging/release.json').read_text())['arch_pkgver']
            (work/f'pearl-{version}').symlink_to(root, target_is_directory=True)
            for variant in ('arch','arch-git','arch-intel-git'):
                with self.subTest(variant=variant):
                    stage=work/variant
                    subprocess.run(['bash','-euc',
                        'source "$1"; srcdir="$2"; pkgdir="$3"; package',
                        'stage',str(ROOT/'packaging'/variant/'PKGBUILD'),str(work),str(stage)],
                        env={k:v for k,v in os.environ.items() if k not in ('PEARL_BINARY_DIR','PEARL_PLUGIN_EXAMPLES_DIR')},
                        check=True,capture_output=True)
                    git=variant!='arch';command='phyto-git' if git else 'phyto'
                    identity='org.aqueous.Phyto.Git' if git else 'org.aqueous.Phyto'
                    installed=stage/'usr/bin'/command
                    self.assertEqual(installed.read_bytes(),phyto.read_bytes())
                    self.assertEqual(installed.stat().st_mode&0o7777,0o755)
                    self.assertFalse((stage/'usr/bin'/('phyto' if git else 'phyto-git')).exists())
                    desktop=stage/f'usr/share/applications/{identity}.desktop'
                    content=desktop.read_text()
                    for line in (f'Exec={command} %u',f'Icon={identity}',f'StartupWMClass={identity}','MimeType=inode/directory;'):
                        self.assertIn(line,content.splitlines())
                    self.assertTrue((stage/f'usr/share/icons/hicolor/scalable/apps/{identity}.svg').is_file())
                    if git:
                        self.assertFalse((stage/'usr/share/applications/org.aqueous.Phyto.desktop').exists())
                        self.assertFalse((stage/'usr/share/icons/hicolor/scalable/apps/org.aqueous.Phyto.svg').exists())
                    if shutil.which('desktop-file-validate'):
                        subprocess.run(['desktop-file-validate',str(desktop)],check=True,capture_output=True)
                    command='dome-git' if git else 'dome'
                    identity='org.aqueous.Dome.Git' if git else 'org.aqueous.Dome'
                    opposite='org.aqueous.Dome' if git else 'org.aqueous.Dome.Git'
                    installed=stage/'usr/bin'/command
                    self.assertEqual(installed.read_bytes(),(dome/'bin'/command).read_bytes())
                    self.assertEqual(installed.stat().st_mode&0o7777,0o755)
                    self.assertFalse((stage/'usr/bin'/('dome' if git else 'dome-git')).exists())
                    desktop=stage/f'usr/share/applications/{identity}.desktop'
                    for line in (f'Exec={command}',f'Icon={identity}'):
                        self.assertIn(line,desktop.read_text().splitlines())
                    for directory,extension in (('applications','desktop'),('icons/hicolor/scalable/apps','svg'),('metainfo','metainfo.xml')):
                        self.assertTrue((stage/f'usr/share/{directory}/{identity}.{extension}').is_file())
                        self.assertFalse((stage/f'usr/share/{directory}/{opposite}.{extension}').exists())
                    metadata=ET.parse(stage/f'usr/share/metainfo/{identity}.metainfo.xml').getroot()
                    self.assertEqual(metadata.findtext('id'),identity)
                    self.assertEqual(metadata.findtext('launchable'),f'{identity}.desktop')
                    self.assertEqual(metadata.findtext('provides/binary'),command)
                    if shutil.which('desktop-file-validate'):
                        subprocess.run(['desktop-file-validate',str(desktop)],check=True,capture_output=True)
if __name__=='__main__':unittest.main()
