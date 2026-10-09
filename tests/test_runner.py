"""Behavioral contracts for the self-service runner; no native desktop required."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from test_process import atomic_json, checkout_lock, execute, fingerprint
from test_suites import catalog, inventory_errors, select
from test_environment import Environment

spec = importlib.util.spec_from_file_location('pearl_test_cli', ROOT / 'scripts/test.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


def arguments(**extra):
    return argparse.Namespace(aqueous_source=None, aqueous_prefix=None, qt_prefix=None,
                              offline=False, jobs=2, output=None, fail_fast=False, **extra)


class CatalogTests(unittest.TestCase):
    def test_python_inventory_has_no_unclassified_files(self):
        self.assertEqual(inventory_errors(), [])

    def test_selection_is_explicit_and_aliases_deduplicate(self):
        with self.assertRaises(ValueError):
            select()
        with self.assertRaises(ValueError):
            select(names=['not-a-suite'])
        self.assertEqual([s['id'] for s in select(names=['test', 'test-plugin-unit', 'test-notification-filters'])], ['test'])
        normal = select(names=['test-settings-app'])[0]
        release = select(names=['release:test-settings-app'])[0]
        self.assertNotEqual(normal['options'], release['options'])

    def test_list_and_dry_run_work_outside_checkout_without_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'uncreated'
            command = [sys.executable, ROOT / 'scripts/test.py', 'run', '--suite', 'test-settings-app',
                       '--dry-run', '--json', '--output', output]
            result = subprocess.run(command, cwd=temp, capture_output=True, text=True, check=True)
            plan = json.loads(result.stdout)
            self.assertEqual(plan[0]['id'], 'test-settings-app')
            self.assertEqual(plan[0]['cwd'], str(ROOT))
            self.assertFalse(output.exists())

    def test_file_output_is_not_sent_to_directory_harness(self):
        env = Environment(arguments())
        commands = cli.suite_commands(catalog()['test-greeter-soak'], env, Path('/tmp/evidence'))
        self.assertEqual(commands[-1][-1], '/tmp/evidence/results.json')
        commands = cli.suite_commands(catalog()['test-settings-app'], env, Path('/tmp/evidence'))
        self.assertEqual(commands[-1][-1], '/tmp/evidence')
        commands = cli.suite_commands(catalog()['test-theme-packages'], env, Path('/tmp/evidence'))
        self.assertNotIn('--output', commands[-1])

    def test_offline_build_disables_package_fetching(self):
        args = arguments()
        args.offline = True
        command = cli.suite_commands(catalog()['test'], Environment(args), Path('/tmp/evidence'))[-1]
        self.assertIn('--system', command)


class ProcessTests(unittest.TestCase):
    def test_nonzero_exit_and_complete_log(self):
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / 'test.log'
            code = execute([sys.executable, '-c', 'print("failure evidence"); raise SystemExit(7)'], ROOT,
                           dict(os.environ), log, 5, echo=False)
            self.assertEqual(code, 7)
            self.assertIn('failure evidence', log.read_text())
            self.assertNotIn('PATH', log.with_suffix('.command.json').read_text())

    def test_timeout_cleans_detached_grandchild_and_preserves_unrelated_process(self):
        with tempfile.TemporaryDirectory() as temp:
            pidfile = Path(temp) / 'grandchild.pid'
            sleeper = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
            try:
                code = ('import subprocess,sys,time; from pathlib import Path; '
                        'p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"],start_new_session=True); '
                        f'Path({str(pidfile)!r}).write_text(str(p.pid)); time.sleep(30)')
                result = execute([sys.executable, '-c', code], ROOT, dict(os.environ), Path(temp) / 'timeout.log', 1, echo=False)
                self.assertEqual(result, 124)
                self.assertFalse(Path('/proc', pidfile.read_text()).exists())
                self.assertIsNone(sleeper.poll())
            finally:
                sleeper.terminate()
                sleeper.wait()

    def test_success_also_cleans_orphaned_child(self):
        with tempfile.TemporaryDirectory() as temp:
            pidfile = Path(temp) / 'orphan.pid'
            code = ('import subprocess,sys; from pathlib import Path; '
                    'p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"],start_new_session=True); '
                    f'Path({str(pidfile)!r}).write_text(str(p.pid))')
            result = execute([sys.executable, '-c', code], ROOT, dict(os.environ), Path(temp) / 'success.log', 5, echo=False)
            self.assertEqual(result, 0)
            self.assertFalse(Path('/proc', pidfile.read_text()).exists())

    def test_worker_sigterm_cleans_descendants(self):
        with tempfile.TemporaryDirectory() as temp:
            pidfile = Path(temp) / 'pid'
            command = [sys.executable, '-c', f'import os,time; from pathlib import Path; Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(30)']
            receipt = Path(temp) / 'command.json'
            atomic_json(receipt, dict(command=command, cwd=str(ROOT), timeout=30,
                                      logfile=str(Path(temp) / 'log'), echo=False))
            worker = subprocess.Popen([sys.executable, ROOT / 'scripts/test_process.py', receipt])
            try:
                deadline = time.monotonic() + 5
                while not pidfile.exists() and time.monotonic() < deadline:
                    time.sleep(.025)
                self.assertTrue(pidfile.exists())
                worker.send_signal(signal.SIGTERM)
                self.assertEqual(worker.wait(timeout=7), 130)
                self.assertFalse(Path('/proc', pidfile.read_text()).exists())
            finally:
                if worker.poll() is None:
                    worker.kill()
                    worker.wait()

    def test_checkout_lock_rejects_concurrent_run(self):
        with tempfile.TemporaryDirectory() as temp:
            with checkout_lock(Path(temp)):
                with self.assertRaisesRegex(ValueError, 'Another test run'):
                    with checkout_lock(Path(temp)):
                        self.fail('acquired twice')


class EvidenceTests(unittest.TestCase):
    def test_release_resume_rejects_changed_source_or_environment(self):
        spec = importlib.util.spec_from_file_location('pearl_release_validation', ROOT / 'scripts/release-validate.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        prior = dict(source_fingerprint='old', environment_fingerprint={'zig': '0.16.0'})
        with self.assertRaisesRegex(ValueError, 'different source'):
            module.validate_resume(prior, 'new', prior['environment_fingerprint'])
        with self.assertRaisesRegex(ValueError, 'different dependencies'):
            module.validate_resume(prior, 'old', {'zig': 'other'})
        module.validate_resume(prior, 'old', prior['environment_fingerprint'])

    def test_managed_archive_is_verified_and_tampered_tool_is_rejected(self):
        from test_process import sha
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / 'tool').mkdir()
            (base / 'tool/executable').write_text('original')
            archive = base / 'tool.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                tar.add(base / 'tool', arcname='tool')
            env = Environment(arguments())
            env.cache = base / 'cache'
            env.downloads['fixture'] = dict(url=archive.as_uri(), sha256=sha(archive))
            output = base / 'installed'
            env.fetch('fixture', output, base)
            env.args.offline = True
            self.assertEqual(env.fetch('fixture', output, base), output)
            (output / 'executable').write_text('tampered')
            with self.assertRaisesRegex(ValueError, 'Unrecognized tool'):
                env.fetch('fixture', output, base)
            env.downloads['fixture']['sha256'] = '0' * 64
            with self.assertRaisesRegex(ValueError, 'Offline cache'):
                env.fetch('fixture', None, base)

    def test_missing_tool_and_conflicting_zig_pin_are_actionable(self):
        env = Environment(arguments())
        with patch('test_environment.shutil.which', return_value=None):
            result = env.check(catalog()['test-bindings'])
            self.assertTrue(any('Missing executable cc' in s for s in result['issues']))
        env.version = 'wrong'
        result = env.check(catalog()['test'])
        self.assertTrue(any('disagree' in s for s in result['issues']))

    def test_fingerprint_tracks_dirty_tests_and_ignores_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in ('build.zig', 'build.zig.zon', '.zigversion'):
                (root / name).write_text('fixture')
            (root / 'tests').mkdir()
            test = root / 'tests/example.py'
            test.write_text('old')
            original = fingerprint(root)
            test.write_text('new')
            changed = fingerprint(root)
            self.assertNotEqual(original, changed)
            (root / 'tests/__pycache__').mkdir()
            (root / 'tests/__pycache__/junk').write_text('generated')
            self.assertEqual(fingerprint(root), changed)

    def test_output_directory_never_overwrites_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            args = arguments()
            args.output = Path(temp)
            (args.output / 'results.json').write_text('original')
            with self.assertRaises(FileExistsError):
                cli.new_output(args)
            self.assertEqual((args.output / 'results.json').read_text(), 'original')

    def test_blocked_suite_is_reported_and_nonzero(self):
        with tempfile.TemporaryDirectory() as temp:
            args = arguments(group='fast')
            args.output = Path(temp) / 'run'
            env = Environment(args)
            with patch.object(env, 'check', return_value=dict(issues=['Missing fixture'], versions={}, hint='prepare')):
                result = cli.run_suites(args, select(names=['protocol-trace']), env)
            report = json.loads((args.output / 'results.json').read_text())
            self.assertEqual(result, 2)
            self.assertEqual(report['suites']['protocol-trace']['status'], 'blocked')
            self.assertEqual(report['status'], 'failed')

    def test_rerun_selects_only_unsuccessful_and_retains_options(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            prior = dict(schema_version=1, source_fingerprint='old', configuration={'aqueous_prefix': '/tmp/fixture'},
                         suites={'test': {'status': 'passed'}, 'protocol-trace': {'status': 'failed'}, 'runner': {'status': 'not-run'}})
            atomic_json(directory / 'results.json', prior)
            with patch.object(cli, 'checkout_lock'), patch.object(cli, 'run_suites', return_value=1) as run:
                self.assertEqual(cli.main(['rerun', '--failed', str(directory)]), 1)
                self.assertEqual([s['id'] for s in run.call_args.args[1]], ['protocol-trace', 'runner'])
                self.assertEqual(run.call_args.args[0].aqueous_prefix, Path('/tmp/fixture'))
            self.assertEqual(json.loads((directory / 'results.json').read_text()), prior)


if __name__ == '__main__':
    unittest.main()
