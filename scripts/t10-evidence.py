#!/usr/bin/env python3
"""Collect completed T10 evidence; refuse failed or mismatched test binaries."""
import datetime,hashlib,html,json,re,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'artifacts/t10';VERIFY=OUT/'verification'
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def command(*args): return subprocess.check_output(args,cwd=ROOT,text=True).strip()
SUITES={
 'preferences':('verification/metadata.json','instrumented'),
 'desktop':('regression/desktop/results.json','production'),
 'surfaces':('regression/surfaces/results.json','production'),
 'session-services':('regression/session-services/result.json','instrumented'),
 'lifecycle':('regression/lifecycle/results.json','instrumented'),
 'services':('regression/services/results.json','instrumented'),
 'connectivity':('regression/connectivity/result.json','instrumented'),
}
def main():
 production=sha(ROOT/'zig-out/bin/pearl');ctl=sha(ROOT/'zig-out/bin/pearlctl')
 instrumented=json.loads((VERIFY/'metadata.json').read_text())['pearl_sha256']
 suites={}
 for name,(relative,kind) in SUITES.items():
  path=OUT/relative;v=json.loads(path.read_text());assert v['status'] in ('passed','pass'),(name,v['status'])
  assert all(value for value in v['checks'].values() if isinstance(value,bool)),name
  digest=v.get('pearl_sha256',v.get('executable_sha256'));assert digest==(production if kind=='production' else instrumented),(name,'binary mismatch')
  if 'ctl_sha256' in v: assert v['ctl_sha256']==ctl,name
  if 'production_sha256' in v: assert v['production_sha256']==production,name
  if 'production_executable_sha256' in v: assert v['production_executable_sha256']==production,name
  suites[name]={'path':relative,'status':v['status'],'checks':len(v['checks']),'binary':kind,'binary_sha256':digest,'result_sha256':sha(path)}
 logs={'build':'build-final','unit':'unit-final','preferences':'preferences-final','desktop':'desktop','surfaces':'surfaces','session-services':'session-services','lifecycle':'lifecycle','services':'services','connectivity':'connectivity'}
 for name,suffix in logs.items():
  source=Path('/tmp')/f'pearl-t10-{suffix}.log';text=source.read_text();assert 'steps succeeded' in text and not re.search(r'\(\d+ failed\)',text),name
  shutil.copyfile(source,VERIFY/f'{name}.log')
 unit=(VERIFY/'unit.log').read_text();counts=[int(n) for n in re.findall(r'run test (\d+) pass',unit)];assert len(counts)==3,counts
 files=[ROOT/'build.zig',ROOT/'build.zig.zon',ROOT/'.zigversion']
 for folder in ('src','resources','bindings','tests','scripts'):
  files.extend(p for p in (ROOT/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
 manifest={str(p.relative_to(ROOT)):sha(p) for p in sorted(set(files))}
 (VERIFY/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 refs={}
 for name in ('dark','light'):
  path=ROOT/f'artifacts/t00/dms/dms-{name}-settings.png';refs[str(path.relative_to(ROOT))]=sha(path)
 report={'recorded_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'zig':command('zig','version'),'gtk':command('pkg-config','--modversion','gtk4'),'glib':command('pkg-config','--modversion','glib-2.0'),'matugen':command('matugen','--version'),'optimize':'ReleaseSafe','production_sha256':production,'instrumented_sha256':instrumented,'ctl_sha256':ctl,'all_suite_binaries_match':True,'unit_counts':dict(zip(('pure','adapter_services','bindings'),counts)),'unit_total':sum(counts),'integration_total':sum(s['checks'] for s in suites.values()),'suites':suites,'source_manifest_sha256':sha(VERIFY/'source-manifest.json'),'dms_references':refs}
 (VERIFY/'report.json').write_text(json.dumps(report,indent=2)+'\n')
 rows='\n'.join(f'| {name} | {s["checks"]} passed |' for name,s in suites.items())
 (VERIFY/'README.md').write_text(f'''# T10 verification — September 13, 2026

Zig 0.16.0 ReleaseSafe with the pinned Ghostty bindings. All suites below use the
same final production/instrumented binaries; hashes are checked by
`scripts/t10-evidence.py` and recorded in [report.json](report.json).

| Suite | Result |
| --- | --- |
| Pure tests | {counts[0]} passed |
| Adapter/service unit tests | {counts[1]} passed |
| Binding API test | {counts[2]} passed |
{rows}

Total: **{sum(counts)} unit/binding tests and {report['integration_total']} integration checks/groups**.

[The T10 result](metadata.json) records defaults, atomic save, shared surface
updates, corrupt/external edits, stale revisions, bounded images, palette cache,
missing fonts/themes, malformed GTK CSS, native GTK pixel checks, reservations,
connector policies, keyboard draft recovery/merge, export ownership/backups,
failed saves, migration, larger configurations, idle work, restart recovery,
generator errors/output limits/deadlines, rapid change cancellation/coalescing,
concurrent disk edits, shutdown/reaping, and operation without matugen.

[Actual captures](../comparison.html) compare Material settings with the frozen
DMS references and show native GTK styling. Images are unedited screenshots.
The custom green/purple GTK theme is an intentionally recognizable test fixture,
not a bundled Pearl theme. Surface regression includes native Aqueous blur.

[Source checksums](source-manifest.json), [build log](build.log), [unit log](unit.log),
and per-suite logs are retained here. See [PREFERENCES.md](../../../docs/PREFERENCES.md)
for schema, limits and CLI behavior. The tests use private buses, settings,
service fixtures and headless/nested compositors; no host radio scan, theme,
wallpaper, daemon ownership or Aqueous configuration was changed. T08's separate
physical scan acceptance remains pending.
''')
 sections=[]
 for variant in ('dark','light'):
  sections.append(f'<section><h2>Static Material · {variant}</h2><div class="pair"><figure><figcaption>DMS · frozen T00 reference</figcaption><a href="../t00/dms/dms-{variant}-settings.png"><img src="../t00/dms/dms-{variant}-settings.png" alt="DMS {variant} settings"></a></figure><figure><figcaption>Pearl · live Aqueous settings</figcaption><a href="verification/session/settings-static-{variant}.png"><img src="verification/session/settings-static-{variant}.png" alt="Pearl {variant} settings"></a></figure></div></section>')
 for filename,title in [('settings-dynamic-wallpaper','Dynamic Material from a wallpaper'),('settings-gtk-custom','Installed GTK theme · synthetic acceptance fixture'),('settings-gtk-system','GTK mode · system default'),('settings-output-policy','Per-output bar and popup policy'),('theme-second-output-osd','One theme across a second output and OSD')]:
  assert (VERIFY/'session'/f'{filename}.png').is_file()
  sections.append(f'<section><h2>{html.escape(title)}</h2><a href="verification/session/{filename}.png"><img src="verification/session/{filename}.png" alt="{html.escape(title)}"></a></section>')
 (OUT/'comparison.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Pearl T10 · settings and themes</title><style>body{margin:0 auto;padding:32px;max-width:1800px;background:#141218;color:#e6e0e9;font:16px/1.5 system-ui}h1{font-size:32px}h2{font-size:21px}a{color:#d0bcff}section{margin:36px 0}figure{margin:0}figcaption{margin-bottom:8px;color:#cac4d0}.pair{display:grid;grid-template-columns:1fr 1fr;gap:20px}img{display:block;max-width:100%;border-radius:12px;border:1px solid #49454f}@media(max-width:900px){.pair{grid-template-columns:1fr}}</style><h1>Pearl T10 · preferences, wallpaper and themes</h1><p>Live GTK4 surfaces on private Aqueous sessions, built with Zig 0.16.0. Material styling follows DMS's colors, typography and rounded controls; the settings layout differs. GTK mode uses the selected GTK theme's styling.</p><p><a href="verification/README.md">Verification</a> · <a href="../../docs/PREFERENCES.md">Preferences contract</a></p>'''+''.join(sections)+'</html>\n')
 print(json.dumps({'unit_tests':report['unit_total'],'integration_checks':report['integration_total'],'all_suite_binaries_match':True}))
if __name__=='__main__': main()
