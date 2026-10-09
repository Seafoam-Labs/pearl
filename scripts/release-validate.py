#!/usr/bin/env python3
"""Compatibility adapter for release evidence; execution uses scripts/test.py."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import signal
import uuid

from test import parser as runner_parser, run_suites
from test_environment import Environment
from test_process import atomic_json, checkout_lock, fingerprint
from test_suites import ROOT, RELEASE_TARGETS, select

TARGETS = RELEASE_TARGETS


def validate_resume(prior, source, environment):
    if prior.get('source_fingerprint') != source:
        raise ValueError('Cannot resume release evidence from different source/tests. Use a new --output directory.')
    if prior.get('environment_fingerprint') != environment:
        raise ValueError('Cannot resume release evidence with different dependencies or fixtures. Use a new --output directory.')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, default=ROOT / 'artifacts/aqueous-082/functional')
    p.add_argument('--resume', action='store_true')
    p.add_argument('--targets', nargs='+', choices=TARGETS, default=TARGETS)
    p.add_argument('--aqueous-prefix', type=Path)
    p.add_argument('--jobs', type=int, default=min(os.cpu_count() or 2, 4))
    args = p.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    targets = ['unit', *dict.fromkeys(args.targets)]
    suites = select(names=['release:' + target for target in targets])
    command = ['run', '--group', 'release-regression', '--jobs', str(args.jobs)]
    prefix = args.aqueous_prefix or (Path(os.environ['PEARL_TEST_AQUEOUS_PREFIX']) if os.environ.get('PEARL_TEST_AQUEOUS_PREFIX') else None)
    if prefix:
        command += ['--aqueous-prefix', str(prefix)]
    run_args = runner_parser().parse_args(command)
    run_args.group = None  # A --targets run must not advertise full-group coverage.
    run_args.output = output / 'runs' / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8])
    env = Environment(run_args)
    with checkout_lock(ROOT):
        initial = fingerprint(ROOT)
        context = {s['id']: env.check(s) for s in select('release-regression')}
        for variant in ('production',):
            path = env.prefix(variant) / 'metadata.json'
            context[variant] = json.loads(path.read_text()) if path.exists() else None
        metadata = output / 'metadata.json'
        prior = json.loads(metadata.read_text()) if metadata.exists() else None
        if prior and not args.resume:
            raise ValueError('Evidence already exists. Use --resume for identical inputs or choose a new --output.')
        if args.resume and prior:
            validate_resume(prior, initial, context)
        report = prior or dict(targets={}, previous_attempts={})
        report.update(status='running', source_fingerprint=initial, environment_fingerprint=context)
        atomic_json(metadata, report)
        try:
            code = run_suites(run_args, suites, env)
            results = json.loads((run_args.output / 'results.json').read_text())
            for target in targets:
                key = 'release:' + target
                record = results['suites'][key]
                destination = output / target
                if destination.exists():
                    previous = output / 'attempts' / (target + '-' + uuid.uuid4().hex[:8])
                    previous.parent.mkdir(exist_ok=True)
                    destination.rename(previous)
                    report['previous_attempts'].setdefault(target, []).append(dict(
                        result=report['targets'].get(target), artifacts=str(previous.relative_to(output))))
                source = run_args.output / key.replace(':', '-')
                if source.exists():
                    shutil.copytree(source, destination)
                report['targets'][target] = dict(exit_code=record.get('exit_code', 2),
                    seconds=record.get('seconds', 0), command=record.get('commands', []),
                    status=record['status'], run=str(run_args.output.relative_to(output)))
            report['source_unchanged'] = results['source_unchanged']
            report['status'] = 'passed' if code == 0 and all(v['exit_code'] == 0 for v in report['targets'].values()) else 'failed'
            return code if report['status'] == 'passed' or code else 1
        except BaseException as error:
            report.update(status='failed', error=str(error), source_unchanged=fingerprint(ROOT) == initial)
            raise
        finally:
            atomic_json(metadata, report)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except ValueError as error:
        raise SystemExit(str(error))
