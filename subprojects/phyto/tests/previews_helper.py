#!/usr/bin/env python3
"""Real decoder/cache checks, with an isolated cache and no graphical session."""
import argparse
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib


def png(path, width=320, height=160, color=(210, 60, 100, 180)):
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress((b'\0' + bytes(color) * width) * height)) + chunk(b'IEND', b''))


def check(binary):
    with tempfile.TemporaryDirectory(prefix='phyto-preview-helper-') as temporary:
        root = Path(temporary)
        cache = root / 'cache'
        env = dict(os.environ, XDG_CACHE_HOME=str(cache))

        def run(path, edge=128, text=False, limit=50 * 1024 * 1024, version=None):
            st = version or path.stat()
            result = subprocess.run([str(binary), '--preview-helper', path.as_uri(), str(edge), str(limit), str(int(text)), '1', str(st.st_mtime_ns // 10**9), str(st.st_mtime_ns % 10**9 // 1000), str(st.st_size)], env=env, capture_output=True, timeout=12)
            assert result.returncode == 0, (result.returncode, result.stderr)
            assert result.stdout[:4] == b'PHT2', (result.stdout, result.stderr)
            return result.stdout[4], struct.unpack('<II', result.stdout[8:16]), result.stdout[16:], result.stderr

        source = root / 'café & 100%.png'
        png(source)
        image = run(source)
        assert image[:2] == (1, (128, 64)), image
        assert len(image[2]) == 128 * 64 * 4
        assert image[2][3] == 180, 'alpha must survive'
        cached = cache / 'thumbnails/normal' / (hashlib.md5(source.as_uri().replace('%26', '&').encode()).hexdigest() + '.png')
        assert cached.exists(), 'standard cache entry missing'
        assert cached.stat().st_mode & 0o777 == 0o600
        assert cached.parent.stat().st_mode & 0o777 == 0o700
        assert b'Thumb::URI' in cached.read_bytes() and b'Thumb::MTime' in cached.read_bytes()
        timestamp = cached.stat().st_mtime_ns
        assert run(source)[2] == image[2]
        assert cached.stat().st_mtime_ns == timestamp, 'warm cache must not be rewritten'
        previous = source.stat()
        png(source, color=(30, 170, 60, 255))
        os.utime(source, ns=(previous.st_atime_ns, previous.st_mtime_ns + 10_000_000))
        assert run(source)[2] != image[2], 'sub-second changes must invalidate the cache'
        assert run(source, version=previous)[0] == 3
        cached.write_bytes(b'not a PNG')
        assert run(source)[0] == 1, 'corrupt cache must regenerate'
        assert run(source, limit=1)[0] == 3
        assert run(source, edge=2048)[1] == (320, 160), 'do not upscale'
        # Pillow is a test fixture encoder, never an application dependency.
        from PIL import Image
        oriented = root / 'rotated.jpg'
        jpeg = Image.new('RGB', (80, 40), (20, 150, 70))
        exif = Image.Exif()
        exif[274] = 6
        jpeg.save(oriented, exif=exif)
        assert run(oriented)[1] == (40, 80), 'EXIF orientation must be applied'
        for extension in ('webp', 'gif'):
            encoded = root / ('sample.' + extension)
            Image.new('RGB', (24, 12), (60, 80, 200)).save(encoded)
            assert run(encoded)[:2] == (1, (24, 12))
        print('PASS JPEG orientation, WebP and GIF decoding', flush=True)
        print('PASS image scaling, alpha, standard cache, warm hits and invalidation', flush=True)

        text = root / 'source.txt'
        text.write_text('<script>alert("never execute")</script>\n' + '\N{SNOWMAN}' * 30000)
        t = run(text, text=True)
        assert t[0] == 2 and b'<script>' in t[2] and b'Preview truncated' in t[2]
        t[2].decode('utf-8')
        text.write_text('line\n' * 1000)
        assert run(text, text=True)[2].count(b'line\n') == 500
        text.write_bytes(b'\x00\xffbinary')
        assert run(text, text=True)[0] == 3
        text.write_text('plain text with an image extension')
        assert run(text)[0] == 3
        symlink = root / 'link.png'
        symlink.symlink_to(source)
        assert run(symlink)[0] == 3
        fifo = root / 'pipe'
        os.mkfifo(fifo)
        assert run(fifo, text=True)[0] == 3
        print('PASS bounded UTF-8 text, binary rejection, symlink and FIFO rejection', flush=True)

        # Force budget pruning with ownership receipts; a changed foreign
        # entry must survive even when its old receipt claims Phyto ownership.
        owned = cache / 'thumbnails/normal' / ('0' * 32 + '.png')
        foreign = cache / 'thumbnails/normal' / ('1' * 32 + '.png')
        png(owned, 1, 1)
        png(foreign, 2, 2)
        ledger = cache / 'phyto/thumbnail-cache.ini'
        ledger.write_text('[Sizes]\nnormal/' + owned.name + '=536870912\nnormal/' + foreign.name + '=536870912\n[Hashes]\nnormal/' + owned.name + '=' + hashlib.sha256(owned.read_bytes()).hexdigest() + '\nnormal/' + foreign.name + '=' + '0' * 64 + '\n')
        uncached = root / 'uncached.png'
        png(uncached, 80, 40)
        assert run(uncached)[0] == 1
        assert not owned.exists() and foreign.exists()
        print('PASS disk budget pruning preserves entries replaced by other applications', flush=True)

        cache_file = root / 'unwritable-cache' 
        cache_file.write_text('file instead of cache directory')
        env['XDG_CACHE_HOME'] = str(cache_file)
        assert run(source)[0] == 1, 'cache failures must not prevent preview'
        print('PASS cache write failures preserve generated images', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    check(parser.parse_args().binary.resolve())
