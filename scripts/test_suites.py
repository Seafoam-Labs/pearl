"""Audited test catalog. Importing this module does not execute build tools."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GROUPS = ('fast', 'native', 'integration', 'greeter', 'qt', 'plugins', 'upstream',
          'apps', 'extended', 'release-regression', 'all')
RELEASE_TARGETS = (
    'integration', 'test-components', 'test-adapter', 'test-surfaces', 'test-desktop',
    'test-services', 'test-connectivity', 'test-session-services', 'test-preferences',
    'test-aqueous-settings', 'test-capture-master', 'test-security', 'test-lock',
    'test-clipboard-capture', 'test-dock-islands', 'test-settings-boundary',
    'test-settings-app', 'test-settings-appearance', 'test-settings-services',
    'test-settings-devices', 'test-settings-integration', 'test-settings-presentation',
    'test-release',
)


def catalog():
    suites = json.loads((ROOT / 'scripts/test-suites.json').read_text())
    result = {s['id']: s for s in suites}
    if len(result) != len(suites):
        raise ValueError('Duplicate suite IDs in test-suites.json')
    # Release variants intentionally retain different compiler options.
    unit = dict(id='release:unit', description='Release unit and binding matrix',
                cwd='.', targets=['test', 'test-adapter-unit', 'test-bindings', 'test-release-tools'],
                capabilities=['zig', 'native'], fixture=None, output='none', timeout=900,
                args=[], sources=[], options=['-Drelease=true'], groups=['release-regression'])
    result[unit['id']] = unit
    for target in RELEASE_TARGETS:
        suite = dict(result[target], id='release:' + target, groups=['release-regression'])
        suite['options'] = [*suite['options'], '-Drelease=true']
        result[suite['id']] = suite
    return result


def select(group=None, names=None):
    entries = catalog()
    if group:
        if group not in GROUPS:
            raise ValueError('Unknown group: ' + group)
        names = [key for key, s in entries.items() if group == 'all' or group in s['groups']]
    if not names:
        raise ValueError('Select --group or at least one --suite; use list to discover suites.')
    selected = {}
    for name in names:
        if name not in entries:
            raise ValueError(f'Unknown suite {name!r}; use list to discover suite IDs.')
        suite = entries[name]
        if suite.get('alias'):
            suite = entries[suite['alias']]
        selected[suite['id']] = suite
    # Only remove identical constituent execution, not differently configured suites.
    if 'test' in selected:
        selected.pop('test-notification-filters', None)
    return list(selected.values())


def inventory_errors():
    """Check Python entry points separately from runtime Zig target discovery."""
    entries = catalog()
    excluded = json.loads((ROOT / 'scripts/test-exclusions.json').read_text())
    covered = {p for s in entries.values() for p in s['sources']}
    paths = [*ROOT.glob('tests/*.py'), *ROOT.glob('tests/integration/*.py'),
             *ROOT.glob('subprojects/*/tests/*.py')]
    actual = {str(p.relative_to(ROOT)) for p in paths}
    errors = [f'Unregistered Python file: {p}' for p in sorted(actual - covered - excluded.keys())]
    errors += [f'Missing registered source: {p}' for p in sorted((covered | excluded.keys()) - actual)]
    errors += [f'Unexplained exclusion: {p}' for p, reason in excluded.items() if not reason or reason == 'REVIEW']
    return errors
