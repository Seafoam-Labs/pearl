#!/usr/bin/env python3
"""Real print worker file I/O without accessing a printer or the user's files."""
import os
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[2]
binary=ROOT/'zig-out/bin/xdg-desktop-portal-pearl'
with tempfile.TemporaryDirectory(prefix='pearl-print-') as tmp:
    root=Path(tmp);source=root/'input.pdf';payload=b'%PDF-1.4\nfixture document\n';source.write_bytes(payload)
    target=root/'output with spaces.pdf'
    def save(source,target,format=None):
        with source.open('rb') as stream:
            fd=stream.fileno()
            return subprocess.run([binary,'--print-worker','file',target.as_uri(),'new',*([format] if format else [])],pass_fds=(fd,),preexec_fn=lambda:os.dup2(fd,3),capture_output=True,timeout=10)
    assert save(source,target).returncode==0
    assert target.read_bytes()==payload
    assert save(source,target).returncode==2,'existing file overwritten without consent'
    invalid=root/'bad';invalid.write_bytes(b'not a print document')
    assert save(invalid,root/'bad.pdf').returncode==2
    assert not (root/'bad.pdf').exists()
    svg=root/'input.svg';svg_payload=b'<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100"/></svg>'
    svg.write_bytes(svg_payload)
    svg_target=root/'output.svg'
    assert save(svg,svg_target,'svg').returncode==0
    assert svg_target.read_bytes()==svg_payload
    assert save(source,root/'wrong.svg','svg').returncode==2
    assert not (root/'wrong.svg').exists()
    link=root/'link.pdf';link.symlink_to(target)
    assert save(source,link).returncode==2
    assert target.read_bytes()==payload
print('PASS isolated print worker PDF/SVG byte preservation, negotiated format rejection and exclusive destination creation')
