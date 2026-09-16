"""Measure the installed Pearl in a private desktop; never modify host settings."""
import copy
import gzip
import json
import re
import signal
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'scripts'), str(ROOT / 'tests/integration')]
from pearl_session import PrivateSession
from test_surfaces import ctl
from test_preferences import apply, settled

renderer = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else 'wallpaper'
out = ROOT / 'artifacts/memory-investigation' / renderer
if mode != 'wallpaper':
    out = out / mode
arena_limit = sys.argv[3] if len(sys.argv) > 3 else None
if arena_limit:
    out = out / ('arena-' + arena_limit)
wallpaper = json.loads((Path.home() / '.config/pearl/preferences.json').read_text())['wallpaper']
results = []

with PrivateSession(out, aqueous=ROOT / '.cache/aqueous-master/bin/aqueous') as session:
    session.env['GSETTINGS_BACKEND'] = 'memory'
    if renderer == 'default':
        session.env.pop('GSK_RENDERER', None)
    else:
        session.env['GSK_RENDERER'] = renderer
    overrides = {}
    if mode == 'heap':
        overrides['LD_PRELOAD'] = str(ROOT / 'artifacts/memory-investigation/heap_probe.so')
    if arena_limit:
        overrides['MALLOC_ARENA_MAX'] = arena_limit
    app = session.child('pearl', ['/usr/bin/pearl-git'], **overrides)
    app.expect('event=control-ready')
    binary = '/usr/bin/pearlctl-git'
    preferences = settled(session, binary)['preferences']

    def sample(label):
        time.sleep(2)
        if mode == 'heap':
            app.proc.send_signal(signal.SIGUSR1 if label == 'trimmed' else signal.SIGUSR2)
            time.sleep(.2)
        proc = Path('/proc') / str(app.proc.pid)
        rollup = (proc / 'smaps_rollup').read_text()
        record = {'label': label, 'pid': app.proc.pid,
                  **{key: int(value) for key, value in re.findall(r'^(\w+):\s+(\d+) kB', rollup, re.M)}}
        record['fds'] = len(list((proc / 'fd').iterdir()))
        maps = (proc / 'smaps').read_text()
        record['glycin_frames'] = maps.count('/memfd:glycin-frame')
        with gzip.open(out / (label + '.smaps.gz'), 'wt') as target:
            target.write(maps)
        results.append(record)
        (out / 'samples.json').write_text(json.dumps(results, indent=2))
        print(renderer, label, {k: record[k] for k in ['Rss', 'Pss', 'Anonymous', 'glycin_frames', 'fds']}, flush=True)

    sample('baseline')
    picture = copy.deepcopy(preferences)
    picture['wallpaper'] = wallpaper
    picture['theme']['mode'] = 'static'
    solid = copy.deepcopy(picture)
    solid['wallpaper']['mode'] = 'solid'
    apply(session, binary, picture)
    sample('wallpaper')
    for i in range(20):
        ctl(session, binary, 'launcher', 'show')
        time.sleep(.08)
        ctl(session, binary, 'launcher', 'hide')
    sample('launcher_20')
    if mode in ('launcher', 'heap'):
        for batch in range(5):
            for i in range(20):
                ctl(session, binary, 'launcher', 'show')
                time.sleep(.08)
                ctl(session, binary, 'launcher', 'hide')
            sample('launcher_' + str(40 + 20 * batch))
        for i in range(3):
            time.sleep(10)
            sample('idle_' + str(i))
        if mode == 'heap':
            sample('trimmed')
        ctl(session, binary, 'quit')
        assert app.wait() == 0
        sys.exit(0)
    apply(session, binary, solid)
    sample('solid')
    for i in range(5):
        apply(session, binary, picture)
        sample('wallpaper_repeat_' + str(i))
        apply(session, binary, solid)
        sample('solid_repeat_' + str(i))
    ctl(session, binary, 'quit')
    assert app.wait() == 0
