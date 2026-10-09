#!/usr/bin/env python3
"""Self-service Pearl tests: discover, diagnose, prepare, run, and retain evidence."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shlex
import signal
import sys
import time
import uuid
import xml.etree.ElementTree as ET

from test_environment import Environment, PrerequisiteError, capture
from test_process import atomic_json, checkout_lock, execute, fingerprint
from test_suites import ROOT, GROUPS, catalog, inventory_errors, select


def positive(value):
    result = int(value)
    if result < 1:
        raise argparse.ArgumentTypeError('must be a positive integer')
    return result


def parser():
    p = argparse.ArgumentParser(description=__doc__, epilog='Start with: list; doctor --group integration; prepare --group integration; run --group integration. See docs/TESTING.md.')
    commands = p.add_subparsers(dest='command')
    listing = commands.add_parser('list', help='Discover suites without building or downloading')
    listing.add_argument('--json', action='store_true')
    listing.add_argument('--group', choices=GROUPS)
    registry = commands.add_parser('check-registry', help='Check Python inventory and actual Zig target listings')
    registry.add_argument('--python-only', action='store_true', help='Do not execute Zig')
    for name in ('doctor', 'prepare', 'run', 'rerun'):
        cmd = commands.add_parser(name)
        if name == 'rerun':
            cmd.add_argument('--failed', type=Path, required=True, metavar='RUN_DIRECTORY')
        else:
            selection = cmd.add_mutually_exclusive_group(required=True)
            selection.add_argument('--group', choices=GROUPS)
            selection.add_argument('--suite', action='append')
        cmd.add_argument('--aqueous-source', type=Path, help='Read-only Git source containing the pinned commit')
        cmd.add_argument('--aqueous-prefix', type=Path, help='Existing verified production fixture prefix')
        cmd.add_argument('--qt-prefix', type=Path, help='Existing QtEngine/Darkly installation prefix')
        cmd.add_argument('--offline', action='store_true', help='Disable dependency downloads; use prepared cache')
        cmd.add_argument('--output', type=Path, help='New evidence directory (must not exist)')
        cmd.add_argument('--jobs', type=positive, default=min(os.cpu_count() or 2, 4), help='Zig compiler job limit; suites execute serially')
        cmd.add_argument('--fail-fast', action='store_true')
        cmd.add_argument('--dry-run', action='store_true', help='Show commands; do not execute or write files')
        cmd.add_argument('--json', action='store_true', help='Machine-readable diagnosis or dry-run plan')
    return p


def suite_commands(suite, environment, output):
    values = environment.values(suite)
    expand = lambda parts: [p.format_map(values) for p in parts]
    commands = [expand(c) for c in suite.get('before', [])]
    if suite.get('targets'):
        command = [environment.zig, 'build', *suite['targets'], '-Doptimize=ReleaseSafe',
                   f'-j{environment.args.jobs}', '--summary', 'all', *suite['options']]
        if 'plugins' in suite['capabilities']:
            command += ['-Dwasm-plugins=true', '-Dwasmtime-prefix=' + values['wasmtime'],
                        '-Dplugin-examples=' + values['examples']]
        if 'pam-upstream' in suite['capabilities']:
            command += ['-Dfingerprint-pam=' + str(environment.cache / 'fingerprint/pam_fprintd.so')]
        if environment.args.offline:
            command += ['--system', str(environment.root / suite['cwd'] / 'zig-pkg')]
        arguments = expand(suite['args'])
        if suite['output'] != 'none':
            arguments += ['--output', str(output / 'results.json' if suite['output'] == 'file' else output)]
        if 'qt' in suite['capabilities'] and environment.args.qt_prefix:
            arguments += ['--engine-prefix', str(environment.args.qt_prefix.resolve())]
        if suite['id'].endswith('test-qt-session'):
            arguments += ['--aqueous-source', values['source']]
        if arguments:
            command += ['--', *arguments]
    else:
        command = expand(suite['command'])
        if suite['output'] != 'none':
            command += ['--output', str(output / 'results.json' if suite['output'] == 'file' else output)]
    commands.append(command)
    return commands


def new_output(args, kind='runs'):
    path = args.output.resolve() if args.output else ROOT / '.cache' / ('test-' + kind) / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8])
    path.mkdir(parents=True, exist_ok=False)
    return path


def save_report(path, report):
    atomic_json(path / 'results.json', report)
    lines = [f"Pearl tests: {report['status']}", f"Selection: {report['selection']}", '']
    junit = ET.Element('testsuite', name='Pearl', tests=str(len(report['suites'])))
    for key, result in report['suites'].items():
        lines.append(f"{key}: {result['status']} ({result.get('seconds', 0):.1f}s) — {result.get('log', '')}")
        if result.get('issues'):
            lines.extend('  ' + issue for issue in result['issues'])
        case = ET.SubElement(junit, 'testcase', name=key, time=str(result.get('seconds', 0)))
        if result['status'] != 'passed':
            tag = 'failure' if result['status'] in ('failed', 'timed-out') else 'error'
            ET.SubElement(case, tag, message=result['status']).text = '\n'.join(result.get('issues', []))
    (path / 'summary.txt').write_text('\n'.join(lines) + '\n')
    (path / 'junit.xml').write_text(ET.tostring(junit, encoding='unicode') + '\n')


def run_suites(args, suites, environment, parent=None):
    output = new_output(args)
    print('Results: ' + str(output), flush=True)
    initial = fingerprint(ROOT)
    report = dict(schema_version=1, status='running', selection=getattr(args, 'group', None) or [s['id'] for s in suites],
                  started=datetime.now(timezone.utc).isoformat(), source_fingerprint=initial,
                  parent=str(parent) if parent else None, suites={},
                  configuration=dict(aqueous_prefix=str(args.aqueous_prefix.resolve()) if args.aqueous_prefix else None,
                                     qt_prefix=str(args.qt_prefix.resolve()) if args.qt_prefix else None,
                                     jobs=args.jobs, offline=args.offline),
                  excluded=[key for key in catalog() if key not in {s['id'] for s in suites}])
    if parent:
        previous = json.loads((parent / 'results.json').read_text())
        report['parent_source_matches'] = previous.get('source_fingerprint') == initial
    for suite in suites:
        report['suites'][suite['id']] = dict(status='not-run', capabilities=suite['capabilities'],
                                             fixture=suite.get('fixture'))
    save_report(output, report)
    checked_variants = {}
    exit_code = 0
    try:
        for suite in suites:
            key = suite['id']
            result = report['suites'][key]
            started = time.monotonic()
            directory = output / key.replace(':', '-')
            directory.mkdir()
            check = environment.check(suite)
            result.update(versions=check['versions'], issues=check['issues'])
            variant = suite.get('fixture')
            if variant and not result['issues']:
                if variant not in checked_variants:
                    checked_variants[variant] = environment.smoke(variant, output / ('probe-' + variant))
                if checked_variants[variant]:
                    result['issues'].append(f'Private {variant} compositor smoke test failed; see probe-{variant}/smoke.log.')
            if result['issues']:
                result.update(status='blocked', remedy=check['hint'])
                print(f'{key}: BLOCKED\n' + '\n'.join(result['issues']) + '\n' + check['hint'], flush=True)
                exit_code = exit_code or 2
            else:
                if variant:
                    result['provenance'] = json.loads((environment.prefix(variant) / 'metadata.json').read_text())
                commands = suite_commands(suite, environment, directory)
                result['commands'] = commands
                result['cwd'] = str(ROOT / suite['cwd'])
                print(f'Running {key}', flush=True)
                result['status'] = 'not-run'
                save_report(output, report)
                for i, command in enumerate(commands):
                    logfile = directory / f'command-{i + 1}.log'
                    result['log'] = str(logfile.relative_to(output))
                    child_env = environment.suite_env(suite)
                    child_env['PEARL_TEST_OUTPUT'] = str(directory)
                    code = execute(command, ROOT / suite['cwd'], child_env, logfile, suite['timeout'])
                    result['exit_code'] = code
                    result['status'] = 'passed' if code == 0 else 'timed-out' if code == 124 else 'interrupted' if code == 130 else 'failed'
                    if code:
                        exit_code = 130 if code == 130 else 3 if code == 125 else 1
                        break
            result['seconds'] = round(time.monotonic() - started, 3)
            print(f"{key}: {result['status']} ({result['seconds']:.1f}s)", flush=True)
            save_report(output, report)
            if exit_code == 130 or (args.fail_fast and result['status'] != 'passed'):
                break
    except KeyboardInterrupt:
        result['status'] = 'interrupted'
        exit_code = 130
    except Exception as error:
        report['error'] = str(error)
        exit_code = 3
        print(f'Runner error: {error}', file=sys.stderr)
    finally:
        report['source_unchanged'] = fingerprint(ROOT) == initial
        if not report['source_unchanged']:
            report['error'] = 'Source changed during execution; results do not describe one source tree.'
            exit_code = exit_code or 3
        report['status'] = 'passed' if exit_code == 0 else 'interrupted' if exit_code == 130 else 'failed'
        report['exit_code'] = exit_code
        report['finished'] = datetime.now(timezone.utc).isoformat()
        save_report(output, report)
        print(f"{report['status'].upper()}: {output / 'summary.txt'}", flush=True)
    return exit_code


def check_registry(python_only=False):
    errors = inventory_errors()
    if not python_only:
        entries = catalog()
        env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.cache/zig'))
        for cwd in sorted({s['cwd'] for s in entries.values() if s['targets']}):
            options = []
            if cwd == '.':
                options = ['-Dwasm-plugins=true', '-Dwasmtime-prefix=' + str(ROOT / '.cache/test-runner/tools/wasmtime'),
                           '-Dfingerprint-pam=' + str(ROOT / '.cache/test-runner/fingerprint/pam_fprintd.so')]
            code, output = capture(['zig', 'build', '--help', *options], env, ROOT / cwd)
            if code:
                errors.append(f'{cwd}: cannot inspect build targets: {output}')
                continue
            discovered = set(re.findall(r'^  ((?:test(?:-[\w-]+)?)|integration|benchmark)\s', output, re.M))
            registered = {t for s in entries.values() if s['cwd'] == cwd for t in s['targets']}
            for target in sorted(discovered - registered):
                errors.append(f'Unregistered Zig target: {cwd}: {target}')
            for target in sorted(registered - discovered):
                errors.append(f'Registered Zig target disappeared: {cwd}: {target}')
    for error in errors:
        print(error, file=sys.stderr)
    if not errors:
        print('Suite registry matches ' + ('Python inventory.' if python_only else 'Python inventory and Zig build target listings.'))
    return 1 if errors else 0


def main(argv=None):
    p = parser()
    args = p.parse_args(argv)
    if not args.command:
        p.print_help()
        return 0
    if args.command == 'list':
        suites = select(args.group) if args.group else list(catalog().values())
        if args.json:
            print(json.dumps(dict(groups=GROUPS, suites=suites,
                                  exclusions=json.loads((ROOT / 'scripts/test-exclusions.json').read_text())), indent=2))
        else:
            print('Groups: ' + ', '.join(GROUPS))
            for suite in suites:
                print(f"{suite['id']:36} {','.join(suite['groups']):20} {suite['description']}")
                print('  needs: ' + ', '.join(suite['capabilities']) +
                      (f"; compositor: {suite['fixture']}" if suite['fixture'] else '') +
                      (f"; alias of {suite['alias']}" if suite.get('alias') else ''))
        return 0
    if args.command == 'check-registry':
        return check_registry(args.python_only)
    parent = None
    if args.command == 'rerun':
        parent = args.failed.resolve()
        prior = json.loads((parent / 'results.json').read_text())
        if prior.get('schema_version') != 1:
            raise ValueError('Unsupported results schema; cannot rerun this report.')
        names = [key for key, value in prior['suites'].items() if value['status'] != 'passed']
        if not names:
            print('No unsuccessful suites to rerun.')
            return 0
        suites = select(names=names)
        for name in ('aqueous_prefix', 'qt_prefix'):
            if getattr(args, name) is None and prior.get('configuration', {}).get(name):
                setattr(args, name, Path(prior['configuration'][name]))
    else:
        suites = select(args.group, args.suite)
    environment = Environment(args)
    if args.dry_run:
        output = args.output.resolve() if args.output else ROOT / '.cache/test-runs/DRY-RUN'
        plan = [dict(id=s['id'], cwd=str(ROOT / s['cwd']), fixture=s['fixture'],
                     capabilities=s['capabilities'], commands=suite_commands(s, environment, output / s['id'].replace(':', '-')))
                for s in suites]
        print(json.dumps(plan, indent=2) if args.json else '\n'.join(
            f"{s['id']} ({s['cwd']})\n  " + '\n  '.join(shlex.join(c) for c in s['commands']) for s in plan))
        return 0
    if args.command == 'doctor':
        checks = {s['id']: environment.check(s) for s in suites}
        variants = {s['fixture'] for s in suites if s.get('fixture') and not checks[s['id']]['issues']}
        if variants:
            output = new_output(args, 'diagnostics')
            for variant in sorted(variants):
                code = environment.smoke(variant, output / variant, echo=not args.json)
                for suite in suites:
                    if suite.get('fixture') == variant:
                        checks[suite['id']]['probe_log'] = str(output / variant / 'smoke.log')
                        if code:
                            checks[suite['id']]['issues'].append(f'Private compositor/capture probe failed (exit {code}); see {output / variant / "smoke.log"}.')
            atomic_json(output / 'diagnostics.json', checks)
        if args.json:
            print(json.dumps(checks, indent=2))
        else:
            for key, check in checks.items():
                print(key + ': ' + ('BLOCKED' if check['issues'] else 'prerequisites available'))
                for issue in check['issues']:
                    print('  ' + issue)
            if any(c['issues'] for c in checks.values()):
                print(environment.package_hint({cap for s in suites for cap in s['capabilities']}))
            if variants:
                print('Private compositor probe evidence: ' + str(output))
        return 2 if any(c['issues'] for c in checks.values()) else 0
    with checkout_lock(ROOT):
        if args.command == 'prepare':
            output = new_output(args, 'preparation')
            print('Preparation logs: ' + str(output), flush=True)
            try:
                environment.prepare(suites, output)
            except BaseException as error:
                atomic_json(output / 'prepared.json', dict(status='failed', error=str(error)))
                raise
            print('Preparation passed. Run the same selection with run.')
            return 0
        return run_suites(args, suites, environment, parent)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('Interrupted.', file=sys.stderr)
        sys.exit(130)
    except (ValueError, FileNotFoundError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
    except Exception as error:
        print(f'Runner infrastructure error: {error}', file=sys.stderr)
        sys.exit(3)
