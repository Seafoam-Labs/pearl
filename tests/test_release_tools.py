#!/usr/bin/env python3
"""Release tooling must fail closed and archives must exclude local state."""
import importlib.util, json, tempfile, unittest, tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/('release-'+name+'.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
gate=module('gate');source=module('source')
def write(root,path,value):
    p=root/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(value))
class ReleaseTools(unittest.TestCase):
    def test_settings_window_failure_is_advisory_but_other_failures_block(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t)
            targets={name:{'exit_code':0,'status':'passed'} for name in gate.TARGETS}
            targets['test-settings-app']={'exit_code':1,'status':'failed'}
            report=dict(status='passed',source_unchanged=True,targets=targets)
            write(root,'functional/metadata.json',report)
            result=gate.evaluate(root)
            self.assertTrue(result['checks']['functional'])
            self.assertEqual(result['reports']['test-settings-app']['status'],'failed')
            self.assertTrue(result['reports']['test-settings-app']['report_only'])
            targets['test-settings-appearance']['exit_code']=1
            write(root,'functional/metadata.json',report)
            self.assertFalse(gate.evaluate(root)['checks']['functional'])

    def test_settings_acceptance_only_exempts_window_and_preserves_source_check(self):
        spec=importlib.util.spec_from_file_location('settings_acceptance',ROOT/'tests/integration/test_settings_acceptance.py')
        acceptance=importlib.util.module_from_spec(spec);spec.loader.exec_module(acceptance)
        report=dict(source_unchanged=True,suites={'window':{'status':'failed'},'appearance':{'status':'passed'}})
        self.assertTrue(acceptance.acceptance_passed(report))
        report['suites']['appearance']['status']='failed'
        self.assertFalse(acceptance.acceptance_passed(report))
        report['suites']['appearance']['status']='passed';report['source_unchanged']=False
        self.assertFalse(acceptance.acceptance_passed(report))

    def test_helper_provenance_uses_pinned_version_not_compatibility_floor(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);project=root/'project';evidence=root/'evidence'
            release=dict(aqueous_revision='revision',aqueous_binary_sha256='shell',aqueousctl_binary_sha256='ctl',aqueous_config_binary_sha256='config',aqueous_wlroots_sha256='wlroots',aqueous_config_floor='0.8.2',aqueous_config_version='1.0.12')
            write(project,'packaging/release.json',release)
            baseline=dict(revision='revision',binary_sha256={'aqueous':'shell','aqueousctl':'ctl','aqueous-config':'config'},wlroots_sha256='wlroots',helper={'version':'1.0.12'})
            write(evidence,'functional/test-aqueous-settings/metadata.json',{'baseline':baseline})
            self.assertTrue(gate.evaluate(evidence,project)['checks']['master-provenance'])
            baseline['helper']['version']='0.8.2'
            write(evidence,'functional/test-aqueous-settings/metadata.json',{'baseline':baseline})
            self.assertFalse(gate.evaluate(evidence,project)['checks']['master-provenance'])
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
            (root/'packaging/arch').mkdir();(root/'packaging/arch/PKGBUILD').write_text(
                'pkgver=0.1.0\nsource=("pearl-$pkgver.tar.gz::https://example.invalid/v$pkgver.tar.gz"\n'
                '        "dependency.tar.gz")\nsha256sums=(\'published-hash\'\n        \'dependency-hash\')\n')
            (root/'README.md').write_text('fixture')
            write(root,'plugins/wit/plugin.wit',{'included':True})
            write(root,'plugins/examples/rust/target/generated.wasm',{'excluded':True})
            write(root,'subprojects/phyto/src/main.zig',{'included':True})
            write(root,'subprojects/phyto/packaging/org.aqueous.Phyto.desktop',{'included':True})
            write(root,'subprojects/dome/build.zig',{'included':True})
            write(root,'subprojects/dome/src/main.zig',{'included':True})
            write(root,'subprojects/dome/packaging/org.aqueous.Dome.desktop',{'included':True})
            for member in ('build.zig','src/main.zig','packaging/org.aqueous.Coral.desktop','resources/coral-dark.xml','resources/coral-light.xml'):
                write(root,f'subprojects/coral/{member}',{'included':True})
            for directory in ('zig-out', 'zig-pkg', '.zig-cache', '.cache', 'artifacts', '__pycache__'):
                write(root,f'subprojects/phyto/{directory}/local',{'excluded':True})
                write(root,f'subprojects/dome/{directory}/local',{'excluded':True})
                write(root,f'subprojects/coral/{directory}/local',{'excluded':True})
            write(root,'subprojects/unrelated/src/main.zig',{'excluded':True})
            first=source.archive(root,Path(t)/'one');write(root,'artifacts/private.json',{'ignored':True});second=source.archive(root,Path(t)/'two')
            with tarfile.open(Path(t)/'one'/first['archive']) as archive:
                self.assertIn('pearl-1/plugins/wit/plugin.wit',archive.getnames())
                self.assertFalse(any('/target/' in name for name in archive.getnames()))
                self.assertEqual({name for name in archive.getnames() if '/subprojects/' in name}, {
                    'pearl-1/subprojects/phyto/src/main.zig',
                    'pearl-1/subprojects/phyto/packaging/org.aqueous.Phyto.desktop',
                    'pearl-1/subprojects/coral/build.zig',
                    'pearl-1/subprojects/coral/src/main.zig',
                    'pearl-1/subprojects/coral/packaging/org.aqueous.Coral.desktop',
                    'pearl-1/subprojects/coral/resources/coral-dark.xml',
                    'pearl-1/subprojects/coral/resources/coral-light.xml',
                    'pearl-1/subprojects/dome/build.zig',
                    'pearl-1/subprojects/dome/src/main.zig',
                    'pearl-1/subprojects/dome/packaging/org.aqueous.Dome.desktop',
                })
            self.assertEqual(first,second);self.assertIn(first['sha256'],(Path(t)/'one/PKGBUILD').read_text())
            self.assertFalse((Path(t)/'one/PKGBUILD.portal').exists())
            recipe=(Path(t)/'one/PKGBUILD').read_text()
            self.assertIn('pkgver=1\n',recipe)
            self.assertIn('source=("pearl-$pkgver.tar.gz"\n',recipe)
            self.assertNotIn('example.invalid',recipe)
            self.assertIn('"dependency.tar.gz"',recipe)
            self.assertIn("'dependency-hash'",recipe)
            (root/'src').mkdir();(root/'src/link').symlink_to(root/'README.md')
            with self.assertRaises(ValueError):source.archive(root,Path(t)/'three')
if __name__=='__main__':unittest.main()
