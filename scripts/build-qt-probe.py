#!/usr/bin/env python3
"""Build an optional Qt consumer without linking Qt into Pearl."""
import argparse
import shlex
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--qt', choices=('5', '6'), required=True)
p.add_argument('--source', required=True)
p.add_argument('--output', required=True)
a = p.parse_args()
flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', f'Qt{a.qt}Widgets'], text=True)
subprocess.run(['c++', '-std=c++17', '-fPIC', '-O2', a.source, '-o', a.output, *shlex.split(flags)], check=True)
