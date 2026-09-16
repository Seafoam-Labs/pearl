#!/usr/bin/env python3
"""Test package payload and real offline systemctl operations in disposable roots."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('greeter_setup', ROOT/'packaging/greeter/setup.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class GreeterInstall(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pearl-install-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.system = self.root/'etc/systemd/system'
        self.system.mkdir(parents=True)
        units = self.root/'usr/lib/systemd/system'
        units.mkdir(parents=True)
        (units/'pearl-greeter.service').write_text((ROOT/'packaging/greeter/pearl-greeter.service').read_text())
        (units/'old.service').write_text('[Service]\nExecStart=/usr/bin/true\n[Install]\nAlias=display-manager.service\nWantedBy=graphical.target\n')
        for name in ('graphical.target', 'multi-user.target', 'rescue.target'):
            (units/name).write_text('[Unit]\nDescription=Fixture target\n')
        self.install = setup.Setup(self.root)

    def old_manager(self):
        self.install.systemctl('enable', 'old.service')
        self.install.systemctl('set-default', 'multi-user.target')

    def backup_configs(self, check=True):
        return subprocess.run(['bash', '-c', 'source "$1"; _backup_greetd_configs "$2"',
                               'backup-test', str(ROOT/'packaging/arch-greeter/pearl-greeter.install'),
                               str(self.root)], check=check, capture_output=True, text=True)

    def test_config_backup_preserves_original_and_existing_backup(self):
        config_dir = self.root/'etc/greetd'
        config_dir.mkdir()
        config = config_dir/'config.toml'
        config.write_text('[terminal]\nvt = 2\n')
        config.chmod(0o640)
        self.backup_configs()
        backup = config_dir/'config.toml.bak'
        self.assertEqual(backup.read_bytes(), config.read_bytes())
        self.assertEqual(backup.stat().st_mode & 0o777, 0o640)
        original = backup.read_bytes()
        config.write_text('later edit')
        self.backup_configs()
        self.assertEqual(backup.read_bytes(), original)
        self.assertEqual(config.read_text(), 'later edit')
        self.install.enable()
        self.install.restore()
        self.assertEqual(backup.read_bytes(), original)

    def test_missing_greetd_config_needs_no_backup(self):
        self.backup_configs()
        self.assertFalse((self.root/'etc/greetd').exists())

    def test_install_and_remove_restore_previous_manager_and_target(self):
        self.old_manager()
        self.install.enable()
        self.assertEqual(Path(self.install.target('display-manager.service')).name, setup.UNIT)
        self.assertEqual(Path(self.install.target('default.target')).name, 'graphical.target')
        self.assertFalse((self.system/'graphical.target.wants/old.service').is_symlink())
        self.assertEqual(self.install.state.stat().st_mode & 0o777, 0o600)
        self.install.restore()
        self.assertEqual(Path(self.install.target('display-manager.service')).name, 'old.service')
        self.assertEqual(Path(self.install.target('default.target')).name, 'multi-user.target')
        self.assertTrue((self.system/'graphical.target.wants/old.service').is_symlink())
        self.assertFalse(self.install.state.exists())

    def test_first_install_without_display_manager_restores_absence(self):
        self.install.enable()
        self.install.restore()
        self.assertIsNone(self.install.target('display-manager.service'))
        self.assertIsNone(self.install.target('default.target'))

    def test_repeat_enable_preserves_original_backup(self):
        self.old_manager()
        self.install.enable()
        before = self.install.state.read_bytes()
        self.install.enable()
        self.assertEqual(before, self.install.state.read_bytes())
        self.install.restore()
        self.assertEqual(Path(self.install.target('display-manager.service')).name, 'old.service')

    def test_removal_preserves_later_manager_or_disable_choice(self):
        for choice in ('other', 'disabled'):
            with self.subTest(choice=choice):
                self.install.enable()
                self.install.systemctl('disable', setup.UNIT)
                if choice == 'other':
                    self.install.systemctl('enable', 'old.service')
                before = self.install.target('display-manager.service')
                self.install.restore()
                self.assertEqual(before, self.install.target('display-manager.service'))

    def test_restore_preserves_later_default_target(self):
        self.install.enable()
        self.install.systemctl('set-default', 'rescue.target')
        self.install.restore()
        self.assertEqual(Path(self.install.target('default.target')).name, 'rescue.target')

    def test_failed_activation_rolls_back(self):
        self.old_manager()
        (self.system/setup.UNIT).symlink_to('/dev/null')
        with self.assertRaises(subprocess.CalledProcessError):
            self.install.enable()
        self.assertEqual(Path(self.install.target('display-manager.service')).name, 'old.service')
        self.assertEqual(Path(self.install.target('default.target')).name, 'multi-user.target')

    def test_custom_display_manager_file_is_not_overwritten(self):
        custom = self.system/'display-manager.service'
        custom.write_text('[Service]\nExecStart=/usr/bin/true\n')
        with self.assertRaises(RuntimeError):
            self.install.enable()
        self.assertTrue(custom.is_file())
        self.assertFalse(custom.is_symlink())

    def test_standalone_payload_contains_defaults_and_no_shell_session(self):
        payload = self.root/'payload'
        subprocess.run(['python3', str(ROOT/'packaging/greeter/stage.py'), '--system-package', '--dest', str(payload)], check=True, capture_output=True)
        required = ('etc/pearl/greeter.json', 'etc/pearl/greetd.toml',
                    'usr/lib/sysusers.d/pearl-greeter.conf', 'usr/lib/tmpfiles.d/pearl-greeter.conf',
                    'usr/lib/systemd/system/pearl-greeter.service', 'usr/lib/pearl/pearl-greeter-setup',
                    'usr/lib/pearl/pearl-greeter-host', 'usr/lib/pearl/pearl-greeter-init',
                    'usr/lib/pearl/pearl-greeter-session', 'usr/bin/pearl-greeter')
        for name in required:
            self.assertTrue((payload/name).is_file(), name)
        config = json.loads((payload/'etc/pearl/greeter.json').read_text())
        self.assertTrue(config['allow_uwsm'])
        self.assertEqual(config['default_session'], 'wayland:aqueous.desktop')
        self.assertFalse((payload/'etc/greetd').exists())
        self.assertFalse((payload/'etc/pam.d').exists())
        self.assertFalse((payload/'usr/share/wayland-sessions').exists())
        self.assertFalse((payload/'usr/lib/pearl/pearl-aqueous-init').exists())
        self.assertTrue(os.access(payload/'usr/lib/pearl/pearl-greeter-setup', os.X_OK))
        # The package uses greetd's distro PAM policy, not the Pearl locker's policy.
        pkgbuild = (ROOT/'packaging/arch-greeter/PKGBUILD').read_text()
        self.assertIn("backup=('etc/pearl/greeter.json' 'etc/pearl/greetd.toml')", pkgbuild)


if __name__ == '__main__':
    unittest.main()
