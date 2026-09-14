#!/usr/bin/env python3
"""Verify final T11 binaries/results and assemble the reviewable handoff."""
import datetime, hashlib, json, re, shutil, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'artifacts/t11';VERIFY=OUT/'verification'
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def command(*args):return subprocess.check_output(args,cwd=ROOT,text=True).strip()
production=sha(ROOT/'zig-out/bin/pearl');ctl=sha(ROOT/'zig-out/bin/pearlctl')
instrumented=json.loads((OUT/'regression/preferences/metadata.json').read_text())['pearl_sha256']
suites={}
for name,relative,kind in [
    ('aqueous-settings','verification/report.json','production'),
    ('preferences','regression/preferences/metadata.json','instrumented'),
    ('surfaces','regression/surfaces/results.json','production'),
    ('lifecycle','regression/lifecycle/results.json','instrumented'),
]:
    path=OUT/relative;v=json.loads(path.read_text());assert v['status'] in ('passed','pass'),name
    assert all(value for value in v['checks'].values() if isinstance(value,bool)),name
    digest=v.get('pearl_sha256',v.get('executable_sha256'));assert digest==(production if kind=='production' else instrumented),(name,'binary mismatch')
    if 'ctl_sha256' in v:assert v['ctl_sha256']==ctl,name
    if 'production_executable_sha256' in v:assert v['production_executable_sha256']==production,name
    suites[name]=dict(path=relative,checks=len(v['checks']),status=v['status'],binary=kind,binary_sha256=digest,result_sha256=sha(path))
for name,suffix in [('build','build-final'),('unit','unit-final'),('aqueous-settings','settings-final'),('preferences','preferences'),('surfaces','surfaces'),('lifecycle','lifecycle')]:
    source=Path('/tmp')/f'pearl-t11-{suffix}.log';text=source.read_text()
    assert 'steps succeeded' in text and not re.search(r'\(\d+ failed\)',text),name
    shutil.copyfile(source,VERIFY/f'{name}.log')
shutil.copyfile('/tmp/pearl-t11-native-bindings.log',VERIFY/'native-bindings.log')
assert 'PASS native binding' in (VERIFY/'native-bindings.log').read_text()
counts=[int(n) for n in re.findall(r'run test (\d+) pass',(VERIFY/'unit.log').read_text())];assert len(counts)==3,counts
files=[ROOT/'build.zig',ROOT/'build.zig.zon',ROOT/'.zigversion',ROOT/'README.md']
for folder in ('src','resources','bindings','tests','scripts','docs'):
    files.extend(p for p in (ROOT/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
manifest={str(p.relative_to(ROOT)):sha(p) for p in sorted(set(files))}
(VERIFY/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
snapshot=json.loads((VERIFY/'schema.json').read_text())
report=dict(recorded_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),zig=command('zig','version'),gtk=command('pkg-config','--modversion','gtk4'),glib=command('pkg-config','--modversion','glib-2.0'),optimize='ReleaseSafe',aqueous_revision=command('git','-C','/home/zoey/RiderProjects/Aqueous','rev-parse','HEAD'),helper_version=snapshot['helper_version'],helper_sha256=sha(Path('/usr/bin/aqueous-config')),schema_fields=len(snapshot['fields']),production_sha256=production,instrumented_sha256=instrumented,ctl_sha256=ctl,all_suite_binaries_match=True,unit_counts=dict(zip(('pure','adapter_services','bindings'),counts)),unit_total=sum(counts),integration_total=sum(s['checks'] for s in suites.values()),suites=suites,source_manifest_sha256=sha(VERIFY/'source-manifest.json'))
(VERIFY/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
rows='\n'.join(f'| {name} | {s["checks"]} passed |' for name,s in suites.items())
(VERIFY/'README.md').write_text(f'''# T11 verification — September 13, 2026

Zig 0.16.0 ReleaseSafe and pinned Ghostty bindings. All suites use the same final
production/instrumented binaries; `scripts/t11-evidence.py` checks their hashes.
See [summary.json](summary.json) and [source checksums](source-manifest.json).

| Suite | Result |
| --- | --- |
| Pure unit tests | {counts[0]} passed |
| Adapter/service unit tests | {counts[1]} passed |
| Binding API tests | {counts[2]} passed |
{rows}

**{report['unit_total']} unit/binding tests and {report['integration_total']} integration checks/groups.**

[T11 results](report.json) cover discovery, all 221 fields, GTK page lifetime,
Material/native GTK styling, retained generations and drafts, invalid values,
raw/structured overlap, raw display bypass prevention, stale and concurrent edits,
rebasing, rejected and lost save replies, reload retry, toolkit failure, preserved
unknown TOML/comments and original-generation multi-file backups. Shortcut tests
use a real compositor binding to prove inhibition and cleanup.

Display tests cover protocol test/apply, visible Keep/Revert, the 15-second timeout,
output removal/re-enable, conflicting canonical edits before Keep, competing live
edits, and rollback after SIGKILL of Pearl. All settings, buses and displays are
private. Headless tests do not establish physical monitor/HDR/mirroring behavior.

The [field/editor inventory](../../../docs/AQUEOUS_FIELD_INVENTORY.md) and
[settings documentation](../../../docs/AQUEOUS_SETTINGS.md) explicitly list
unsupported protected-display cases and deferred visual collection editors.
The old settings frontend is not used; `aqueous-config --shell none` remains the
canonical backend. [Helper calls](helper-calls.jsonl) preserve argv evidence.

[Actual screenshots and DMS references](../comparison.html) are unedited captures.
[Build](build.log), [unit](unit.log), [settings](aqueous-settings.log),
[preferences](preferences.log), [surfaces](surfaces.log), [lifecycle](lifecycle.log)
and [native binding reproduction](native-bindings.log) logs are retained.
''')
images=[('DMS dark reference','../t00/dms/dms-dark-settings.png'),('Pearl Aqueous settings · dark','verification/session/aqueous-appearance-dark.png'),('DMS light reference','../t00/dms/dms-light-settings.png'),('Pearl Aqueous settings · light','verification/session/aqueous-appearance-light.png'),('Native GTK theme','verification/session/aqueous-appearance-gtk.png'),('Protected display preview','verification/session/display-protected-preview.png'),('Layouts','verification/session/aqueous-layouts.png'),('Input','verification/session/aqueous-input.png'),('Rules','verification/session/aqueous-rules.png'),('Advanced','verification/session/aqueous-advanced.png')]
cards=''.join(f'<figure><figcaption>{title}</figcaption><a href="{path}"><img loading="lazy" src="{path}" alt="{title}"></a></figure>' for title,path in images)
(OUT/'comparison.html').write_text('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Pearl T11 · Aqueous settings</title><style>body{background:#141218;color:#e6e0e9;font:16px system-ui;margin:24px}a{color:#d0bcff}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:20px}figure{margin:0;background:#211f26;border-radius:16px;overflow:hidden}figcaption{padding:16px}img{width:100%;display:block}p{max-width:80ch}</style><h1>Aqueous settings in Pearl</h1><p>Unedited private-session captures alongside the frozen DMS references. Native GTK mode follows GTK styling. The display guardian keeps the original live configuration until confirmation. <a href="verification/README.md">Verification and limits</a>.</p><main>'+cards+'</main>')
print(json.dumps(report,indent=2))
