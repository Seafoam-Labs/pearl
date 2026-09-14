#!/usr/bin/python3
"""Fail only the private helper's reload, retaining real output discovery."""
import os, pathlib, sys
mode = pathlib.Path(os.environ['PEARL_AQUEOUS_FAULT_FILE']).read_text().strip()
if sys.argv[1:3] == ['session', 'reload'] and mode == 'reload-failed':
    print('{"ok":false,"status":"failed"}')
    sys.exit(1)
os.execv('/usr/bin/aqueousctl', ['aqueousctl', *sys.argv[1:]])
