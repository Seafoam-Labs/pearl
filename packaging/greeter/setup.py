#!/usr/bin/python3
"""Select Pearl for the next boot or restore its previous boot configuration."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

UNIT = 'pearl-greeter.service'


class Setup:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.system = self.root/'etc/systemd/system'
        self.state = self.root/'var/lib/pearl-greeter-setup/previous.json'

    def systemctl(self, *args, check=True):
        return subprocess.run(['/usr/bin/systemctl', '--root', str(self.root), *args],
                              check=check, text=True, capture_output=True)

    def target(self, name):
        path = self.system/name
        if path.is_symlink():
            value = os.readlink(path)
            if value == '/dev/null':
                raise RuntimeError(f'{path} is masked; unmask it before selecting a greeter')
            return value
        if path.exists():
            raise RuntimeError(f'{path} is not a symlink; refusing to replace a custom unit')
        return None

    def replace_link(self, name, target):
        path = self.system/name
        self.target(name)  # Reject unexpected regular files or masks during restore too.
        if target is None:
            path.unlink(missing_ok=True)
        else:
            temporary = path.with_name(name+'.pearl-tmp')
            temporary.unlink(missing_ok=True)
            temporary.symlink_to(target)
            temporary.replace(path)

    def enable(self):
        previous = self.target('display-manager.service')
        if previous and Path(previous).name == UNIT:
            print('Pearl Greeter is already selected.')
            return
        default = self.target('default.target')
        previous_unit = Path(previous).name if previous else None
        if previous_unit and (not previous_unit.endswith('.service') or previous_unit.startswith('-')):
            raise RuntimeError('Unrecognized previous display-manager service')
        enabled = bool(previous_unit and self.systemctl('is-enabled', previous_unit, check=False).stdout.strip() == 'enabled')
        state = dict(display_manager=previous, previous_unit=previous_unit,
                     previous_enabled=enabled, default_target=default)
        self.state.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.state.parent.chmod(0o700)
        temporary = self.state.with_suffix('.tmp')
        temporary.write_text(json.dumps(state, indent=2)+'\n')
        temporary.chmod(0o600)
        temporary.replace(self.state)
        try:
            if previous_unit:
                self.systemctl('disable', previous_unit)
            self.systemctl('enable', '--force', UNIT)
            self.systemctl('set-default', 'graphical.target')
        except (subprocess.CalledProcessError, OSError):
            self.restore_state(state)
            raise
        print('Pearl Greeter selected for next boot; previous setup saved in '+str(self.state))

    def restore_state(self, state):
        # Offline unit-file operations only: never stop a running login session.
        self.systemctl('disable', UNIT)
        if state['previous_enabled']:
            self.systemctl('enable', state['previous_unit'])
        self.replace_link('display-manager.service', state['display_manager'])
        self.replace_link('default.target', state['default_target'])
        self.restore_config()
        self.state.unlink()

    def restore_config(self):
        config = self.root/'etc/greetd/config.toml'
        template = self.root/'usr/share/pearl-greeter/greetd.toml'
        backup = config.with_name('config.toml.bak')
        # Restore our replacement, preserving a later administrator configuration.
        if not config.is_file() or not template.is_file() or config.read_bytes() != template.read_bytes():
            return
        if backup.is_file():
            shutil.copy2(backup, config)
        else:
            config.unlink()

    def restore(self):
        if not self.state.exists():
            self.restore_config()
            print('No previous Pearl Greeter setup to restore.')
            return
        current = self.target('display-manager.service')
        if not current or Path(current).name != UNIT:
            self.restore_config()
            print('Display-manager selection has changed; preserving the current setup.')
            return
        state = json.loads(self.state.read_text())
        # Keep a later administrator change to the default target.
        current_default = self.target('default.target')
        if not current_default or Path(current_default).name != 'graphical.target':
            state['default_target'] = current_default
        self.restore_state(state)
        print('Previous display-manager selection restored for next boot.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('enable', 'restore'))
    parser.add_argument('--root', type=Path, default=Path('/'), help='Offline installation root')
    args = parser.parse_args()
    if args.root.resolve() == Path('/') and os.geteuid() != 0:
        parser.error('System configuration requires root')
    try:
        getattr(Setup(args.root), args.action)()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Pearl Greeter setup failed: {error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
