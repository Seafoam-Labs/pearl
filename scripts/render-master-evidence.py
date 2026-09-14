#!/usr/bin/env python3
"""Render an index of actual current-master evidence, without granting release approval."""
import argparse,html,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def read(path):
    try:return json.loads(path.read_text())
    except (OSError,ValueError):return {}
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,default=ROOT/'artifacts/aqueous-master');a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
    release=read(ROOT/'packaging/release.json');gate=read(a.output/'gate.json')
    lines=['# Pinned Aqueous master evidence','',f'Pearl **{release["version"]}**, Zig **{release["zig"]}**, Aqueous `{release["aqueous_revision"]}`, helper **{release["aqueous_config_floor"]}**.','', '[UI capture gallery](gallery.html) · [capability coverage](../../docs/AQUEOUS_CAPABILITY_COVERAGE.md) · [upstream dependencies](../../docs/AQUEOUS_MASTER_DEPENDENCIES.md) · [migration](../../docs/AQUEOUS_MASTER_MIGRATION.md)','', '| Evidence | Recorded status |','|---|---|']
    for folder,label in [('functional','Full functional matrix'),('ui','Themes, allocation, accessibility names/roles and keyboard'),('upstream','Canonical journal and native lease adversarial suites'),('performance','Production idle/startup and 1,000-cycle soak'),('reproducibility','Two fresh source/build roots'),('package','Checksum-locked Arch package')]:
        report=read(a.output/folder/'metadata.json');lines.append(f'| [{label}]({folder}/metadata.json) | {report.get("status","not yet recorded")} |')
    lines+=['','The [release gate](gate.json) checks matching production binaries, provenance, source stability, fixture hashes, coverage, all automated suites and separate human signoffs. It remains closed for: '+', '.join(gate.get('pending_or_failed',['gate not yet evaluated']))+'.','', 'Production helper/compositor hashes and build flags are in [provenance.json](provenance.json). Its patch list records the pinned source inputs; patched wlroots was reused read-only, not rebuilt here. Instrumented crash fixtures are labelled separately in the upstream report and are never packaged.','', 'All sessions use private HOME/XDG directories, D-Bus buses and virtual outputs. A separate test-only focus query observes GTK while actual keyboard events perform edits. Direct AT-SPI focus requests return an error on this GTK stack; names/roles are verified, while real Orca/physical acceptance remains pending.','', 'Current master cannot safely persist unclassified collection changes, lacks several structured display mutations, and withholds scene color metadata. Pearl exposes these as explicit gates. This evidence does not claim successful physical preview, HDR conversion or isolated-window PNG export.','', 'Earlier `artifacts/t16` is preserved as the previous candidate. Intermediate diagnostic runs under this directory are not substitutes for the indexed final suite metadata.']
    (a.output/'README.md').write_text('\n'.join(lines)+'\n')
    document=['<!doctype html><meta charset="utf-8"><title>Pearl master UI evidence</title><style>body{background:#17151e;color:#f2eff9;font:16px system-ui;margin:24px}a{color:#d3bdff}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(560px,100%),1fr));gap:20px}figure{margin:0}img{width:100%;height:auto;border:1px solid #746a83}figcaption{padding:8px 0}h2{grid-column:1/-1}</style><h1>Pearl master UI evidence</h1><p>Automated private captures. Human visual and assistive-technology signoffs remain separate. <a href="README.md">Evidence index</a></p><main>']
    for theme in ('dark','light','gtk-compact','large-text'):
        document.append('<h2>'+html.escape(theme)+'</h2>')
        for page in ('displays','rules','keybinds','layouts','operation-receipt','capture'):
            file=a.output/'ui/session'/f'{theme}-{page}.png'
            if file.exists():
                path=file.relative_to(a.output).as_posix();document.append(f'<figure><a href="{path}"><img loading="lazy" src="{path}" alt="{theme} {page}"></a><figcaption>{html.escape(page)}</figcaption></figure>')
    document.append('</main>');(a.output/'gallery.html').write_text('\n'.join(document)+'\n')
if __name__=='__main__':main()
