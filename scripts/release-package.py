#!/usr/bin/env python3
"""Build an Arch package privately, verify payload, and retain a release manifest."""
import argparse, hashlib, importlib.util, json, os, shutil, subprocess, tarfile, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('release_source',ROOT/'scripts/release-source.py');source=importlib.util.module_from_spec(spec);spec.loader.exec_module(source)
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,default=ROOT/'artifacts/aqueous-082/package');a=p.parse_args();a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)
    report={'status':'running','method':'makepkg dependency check, build, check(), staging package(); no installation or service activation'}
    try:
        with tempfile.TemporaryDirectory(prefix='pearl-package-') as temp:
            work=Path(temp);meta=source.archive(ROOT,work);report['source']=meta
            env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(ROOT/'.cache/zig'),SOURCE_DATE_EPOCH=str(meta['source_date_epoch']),PKGDEST=str(a.output))
            with (a.output/'makepkg.log').open('w') as log:
                subprocess.run(['makepkg','--nobuild','--noconfirm'],cwd=work,env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=600)
                extracted=work/'src'/('pearl-'+json.loads((ROOT/'packaging/release.json').read_text())['arch_pkgver'])
                if (ROOT/'zig-pkg').is_dir():shutil.copytree(ROOT/'zig-pkg',extracted/'zig-pkg')
                subprocess.run(['makepkg','--noextract','--force','--noconfirm'],cwd=work,env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=900)
            package_paths=subprocess.check_output(['makepkg','--packagelist'],cwd=work,env=env,text=True).splitlines();assert len(package_paths)==1
            package=Path(package_paths[0]);report['package']=package.name;report['sha256']=hashlib.sha256(package.read_bytes()).hexdigest()
            with tarfile.open(package) as tar:
                names=set(tar.getnames());assert {n for n in names if n.startswith('usr/bin/') and not n.endswith('/')}=={'usr/bin/pearl','usr/bin/pearlctl','usr/bin/pearl-lock','usr/bin/pearl-settings','usr/bin/pearl-themes','usr/bin/pearl-plugin-host','usr/bin/phyto','usr/bin/dome'}
                plugin_files={f'usr/share/pearl/plugins/{example}/{member}' for example in ('timer-c','counter-zig','counter-rust','companion-c') for member in ('plugin.json','plugin.wasm')}
                plugin_files.update({'usr/share/pearl/plugins/companion-c/cat.png','usr/share/pearl/plugins/companion-c/LICENSE.assets'})
                assert {n for n in names if n.startswith('usr/share/pearl/plugins/') and tar.getmember(n).isfile()}==plugin_files
                assert {'usr/share/pearl/plugins-sdk/plugin.wit','usr/share/licenses/pearl/Wasmtime-LICENSE'} <= names
                report['plugin_payload_sha256']={n:hashlib.sha256(tar.extractfile(n).read()).hexdigest() for n in sorted(plugin_files | {'usr/bin/pearl-plugin-host'})}
                assert 'etc/pam.d/pearl' in names and 'usr/lib/systemd/user/pearl.service' in names
                for resource in ('applications/org.aqueous.Pearl.Settings.desktop','icons/hicolor/scalable/apps/org.aqueous.Pearl.Settings.svg','metainfo/org.aqueous.Pearl.Settings.metainfo.xml','applications/org.aqueous.Phyto.desktop','icons/hicolor/scalable/apps/org.aqueous.Phyto.svg','applications/org.aqueous.Dome.desktop','icons/hicolor/scalable/apps/org.aqueous.Dome.svg','metainfo/org.aqueous.Dome.metainfo.xml'):
                    assert 'usr/share/'+resource in names
                assert b'Exec=pearl-settings\n' in tar.extractfile('usr/share/applications/org.aqueous.Pearl.Settings.desktop').read()
                assert b'Exec=phyto %u\n' in tar.extractfile('usr/share/applications/org.aqueous.Phyto.desktop').read()
                assert b'Exec=dome\n' in tar.extractfile('usr/share/applications/org.aqueous.Dome.desktop').read()
                report['dome_sha256']=hashlib.sha256(tar.extractfile('usr/bin/dome').read()).hexdigest()
                report['phyto_sha256']=hashlib.sha256(tar.extractfile('usr/bin/phyto').read()).hexdigest()
                assert not any('.wants/' in n or 'pam-fixture' in n or 'pearl-lock-test' in n for n in names)
                report['binary_sha256']={n:hashlib.sha256(tar.extractfile('usr/bin/'+n).read()).hexdigest() for n in ('pearl','pearlctl','pearl-lock','pearl-settings')}
                (a.output/'PKGINFO').write_bytes(tar.extractfile('.PKGINFO').read());(a.output/'BUILDINFO').write_bytes(tar.extractfile('.BUILDINFO').read())
                (a.output/'files.txt').write_text('\n'.join(sorted(names))+'\n')
            for name in ('PKGBUILD','source.json',meta['archive']):shutil.copy2(work/name,a.output/name)
            report['status']='passed'
    except Exception as error:report.update(status='failed',error=str(error));raise
    finally:(a.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
