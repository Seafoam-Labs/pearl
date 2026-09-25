#!/usr/bin/env python3
"""Mandatory real-provider checks plus fault injection in the instrumented binary."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import threading


def rc4(key, data):
    state = list(range(256))
    j = 0
    for i in range(256):
        j = (j + state[i] + key[i % len(key)]) % 256
        state[i], state[j] = state[j], state[i]
    i = j = 0
    output = bytearray()
    for byte in data:
        i = (i + 1) % 256
        j = (j + state[i]) % 256
        state[i], state[j] = state[j], state[i]
        output.append(byte ^ state[(state[i] + state[j]) % 256])
    return bytes(output)


def pdf(path, rotate=0, password=None):
    # Two different solid pages prove that only the first page is rendered.
    key = None
    extra = ''
    if password:
        padding = bytes.fromhex('28bf4e5e4e758a4164004e56fffa01082e2e00b6d0683e802f0ca9fe6453697a')
        padded = (password.encode() + padding)[:32]
        owner = rc4(hashlib.md5((b'owner-secret' + padding)[:32]).digest()[:5], padded)
        document_id = hashlib.md5(b'phyto-encrypted-fixture').digest()
        key = hashlib.md5(padded + owner + struct.pack('<i', -4) + document_id).digest()[:5]
        user = rc4(key, padding)
        encryption = f'<< /Filter /Standard /V 1 /R 2 /Length 40 /O <{owner.hex()}> /U <{user.hex()}> /P -4 >>'.encode()
        extra = f' /Encrypt 7 0 R /ID [<{document_id.hex()}> <{document_id.hex()}>]'
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>']
    for page, color in ((3, '0.1 0.7 0.3'), (5, '0.8 0.1 0.1')):
        stream = f'{color} rg 0 0 320 160 re f'.encode()
        if key:
            object_key = hashlib.md5(key + (page + 1).to_bytes(3, 'little') + b'\0\0').digest()[:10]
            stream = rc4(object_key, stream)
        objects += [f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 160] /CropBox [0 0 320 160] /Rotate {rotate} /Resources << >> /Contents {page + 1} 0 R >>'.encode(),
                    b'<< /Length ' + str(len(stream)).encode() + b' >>\nstream\n' + stream + b'\nendstream']
    if key:
        objects.append(encryption)
    data = bytearray(b'%PDF-1.4\n')
    offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += f'{i} 0 obj\n'.encode() + obj + b'\nendobj\n'
    xref = len(data)
    data += f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode()
    data += b''.join(f'{n:010} 00000 n \n'.encode() for n in offsets[1:])
    data += f'trailer\n<< /Size {len(offsets)} /Root 1 0 R{extra} >>\nstartxref\n{xref}\n%%EOF\n'.encode()
    path.write_bytes(data)


def video(path, codec='mpeg4', sar=None):
    args = ['/usr/bin/ffmpeg', '-nostdin', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=0x286adc:s=320x160:r=10:d=1']
    if sar:
        args += ['-vf', 'setsar=' + sar]
    subprocess.run(args + ['-threads', '1', '-c:v', codec, '-y', str(path)], check=True, capture_output=True, timeout=10)


def measured_run(command, env, metrics):
    process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    result = {}
    def communicate():
        try:
            result['output'] = process.communicate(timeout=12)
        except subprocess.TimeoutExpired:
            process.kill()
            result['output'] = process.communicate()
    thread = threading.Thread(target=communicate)
    thread.start()
    while thread.is_alive():
        pending = [process.pid]
        rss = 0
        seen = set()
        while pending:
            pid = pending.pop()
            if pid in seen:
                continue
            seen.add(pid)
            try:
                for line in Path(f'/proc/{pid}/status').read_text().splitlines():
                    if line.startswith('VmRSS:'):
                        rss += int(line.split()[1]) * 1024
                pending.extend(map(int, Path(f'/proc/{pid}/task/{pid}/children').read_text().split()))
            except (OSError, ValueError):
                pass
        metrics['sampled_peak_process_tree_rss_bytes'] = max(metrics.get('sampled_peak_process_tree_rss_bytes', 0), rss)
        thread.join(.005)
    stdout, stderr = result['output']
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def check(binary, faults=False):
    with tempfile.TemporaryDirectory(prefix='phyto-providers-') as temporary:
        root = Path(temporary)
        diagnostics = {}
        metrics = {}
        env = dict(os.environ, XDG_CACHE_HOME=str(root / 'cache'), GIO_USE_VFS='local')
        def caps(extra=None):
            result = subprocess.run([binary, '--preview-capabilities'], env=env | (extra or {}), capture_output=True, timeout=8)
            assert result.returncode == 0 and result.stdout[:4] == b'PHP1', result
            assert len(result.stdout) == 72
            return result.stdout
        capability = caps()
        assert capability[4:6] == b'\0\0', ('Real Poppler, FFmpeg and working bubblewrap are required', capability)
        def command(path, provider='pdf', edge=128, deadline=10000):
            st = path.stat()
            return [str(binary), '--preview-helper', path.as_uri(), str(edge), '1', '0', '1', str(st.st_mtime_ns // 10**9), str(st.st_mtime_ns % 10**9 // 1000), str(st.st_size), provider, str(deadline)]
        def run(path, provider='pdf', edge=128, extra=None, deadline=10000):
            result = measured_run(command(path, provider, edge, deadline), env | (extra or {}), metrics)
            assert result.returncode == 0 and result.stdout[:4] == b'PHT2', (result.returncode, result.stdout[:100], result.stderr)
            if os.environ.get('PHYTO_PROVIDER_TEST_DIAGNOSTICS') and result.stderr:
                print(result.stderr.decode(errors='replace')[:16384], flush=True)
            diagnostics['stderr'] = result.stderr.decode(errors='replace')[:16384]
            data = result.stdout
            return data[4], data[5], struct.unpack('<II', data[8:16]), data[16:]
        document = root / 'café & first page.pdf'
        pdf(document)
        first = run(document)
        assert first[:3] == (1, 0, (128, 64)), first[:3]
        r, g, b, alpha = first[3][:4]
        assert g > r * 2 and g > b and alpha == 255, (r, g, b, alpha)
        cached = next((root / 'cache/thumbnails/normal').glob('*.png'))
        assert b'Phyto::ProviderVersion' in cached.read_bytes()
        stamp = cached.stat().st_mtime_ns
        assert run(document) == first and cached.stat().st_mtime_ns == stamp
        # Foreign cache metadata cannot select the wrong PDF page.
        from PIL import Image
        Image.new('RGB', (128, 64), 'red').save(cached)
        assert run(document) == first
        rotated = root / 'rotated.pdf'
        pdf(rotated, 90)
        assert run(rotated)[2] == (64, 128)
        assert run(document, edge=2048)[2] == (2048, 1024)
        protected = root / 'protected.pdf'
        pdf(protected, password='secret')
        # Prove this is a valid protected document, not just a corrupt fixture.
        unlocked = subprocess.run(['/usr/bin/pdftoppm', '-upw', 'secret', '-f', '1', '-l', '1', '-singlefile', '-scale-to', '16', '-png', str(protected)], capture_output=True, timeout=5)
        assert unlocked.returncode == 0 and unlocked.stdout.startswith(b'\x89PNG')
        assert run(protected)[0] == 3
        broken = root / 'bad.pdf'
        broken.write_bytes(b'%PDF-1.4\nbroken')
        assert run(broken)[0] == 3
        broken.write_bytes(b'not a PDF')
        assert run(broken)[0] == 3
        large = root / 'large.pdf'
        with large.open('wb') as f:
            f.write(b'%PDF-1.4\n')
            f.truncate(50 * 1024 * 1024 + 1)
        assert run(large)[1] == 5
        print('PASS PDF first page, rotation, 2048px preview, limits and provider cache identity', flush=True)

        for extension, codec in [('mp4', 'mpeg4'), ('mov', 'mpeg4'), ('mkv', 'mpeg4'), ('avi', 'mpeg4'), ('webm', 'libvpx-vp9')]:
            movie = root / ('movie.' + extension)
            video(movie, codec)
            still = run(movie, 'video')
            assert still[:3] == (1, 0, (128, 64)), (extension, still[:3], diagnostics)
            r, g, b, _ = still[3][:4]
            assert b > r * 2 and b > g, (extension, r, g, b)
            assert run(movie, 'video', 2048)[2] == (320, 160)
        h264 = root / 'h264.mp4'
        video(h264, 'libx264')
        assert run(h264, 'video')[:3] == (1, 0, (128, 64))
        movie = root / 'movie.mp4'
        portrait = root / 'portrait.mp4'
        subprocess.run(['/usr/bin/ffmpeg', '-v', 'error', '-display_rotation:v:0', '90', '-i', str(movie), '-c', 'copy', str(portrait)], check=True, capture_output=True)
        rotation_result = run(portrait, 'video')
        assert rotation_result[2] == (64, 128), rotation_result[:3]
        anamorphic = root / 'anamorphic.mp4'
        video(anamorphic, sar='2/1')
        assert run(anamorphic, 'video')[2] == (128, 32)
        audio = root / 'audio.mp4'
        subprocess.run(['/usr/bin/ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=duration=0.1', '-c:a', 'aac', str(audio)], check=True, capture_output=True)
        assert run(audio, 'video')[0] == 3
        cover = root / 'cover.png'
        Image.new('RGB', (64, 64), 'red').save(cover)
        art_only = root / 'art-only.mp4'
        subprocess.run(['/usr/bin/ffmpeg', '-v', 'error', '-i', str(audio), '-i', str(cover), '-map', '0:a', '-map', '1:v', '-c', 'copy', '-disposition:v:0', 'attached_pic', str(art_only)], check=True, capture_output=True)
        assert run(art_only, 'video')[0] == 3, 'cover art is not a video stream'
        playlist = root / 'playlist.mp4'
        playlist.write_text('#EXTM3U\nhttp://127.0.0.1/secret\n')
        assert run(playlist, 'video')[0] == 3
        large_movie = root / 'large.mp4'
        with large_movie.open('wb') as f:
            f.truncate(2 * 1024 * 1024 * 1024 + 1)
        assert run(large_movie, 'video')[1] == 5
        print('PASS MP4/MOV/MKV/AVI/WebM stills, no upscaling, rotation, anamorphic ratio, audio/playlist rejection', flush=True)

        if faults:
            assert caps({'PHYTO_TEST_PREVIEW_NO_SANDBOX': '1'})[4:6] == b'\x04\x04'
            assert caps({'PHYTO_TEST_PROVIDER_pdftoppm': '/nonexistent'})[4:6] == b'\x02\0'
            assert caps({'PHYTO_TEST_PROVIDER_ffprobe': '/nonexistent'})[4:6] == b'\0\x03'
            fake = root / 'converter'
            def script(body):
                fake.write_text('#!/usr/bin/python3\n' + body)
                fake.chmod(0o700)
                # Fingerprint changes invalidate existing provider thumbnails.
                return {'PHYTO_TEST_PROVIDER_pdftoppm': str(fake)}
            assert run(document, extra=script('import sys\nsys.exit(1)\n'))[0] == 3
            assert run(document, extra=script('import os\nos.write(1, b"x" * (21 * 1024 * 1024))\n'))[1] == 5
            assert run(document, extra=script('import os\nfor i in range(300): os.write(2, b"x" * 16384)\nos.write(1, b"invalid png")\n'))[0] == 3
            started = time.monotonic()
            assert run(document, deadline=350, extra=script('import time\ntime.sleep(30)\n'))[1] == 6
            assert time.monotonic() - started < 2
            # Converters see the selected file, but not its siblings/home or host network.
            canary = root / 'private.txt'
            canary.write_text('PRIVATE')
            import base64, io, socket
            encoded = io.BytesIO()
            Image.new('RGB', (2, 1), 'green').save(encoded, format='PNG')
            listener = socket.socket()
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            body = f'''import os, socket, sys, base64
assert os.path.exists('/input/source')
assert not os.path.exists({str(canary)!r})
assert not os.path.exists('/run/user')
try:
    os.open('/input/source', os.O_WRONLY)
except OSError:
    pass
else:
    raise AssertionError('input is writable')
s = socket.socket()
assert s.connect_ex(('127.0.0.1', {listener.getsockname()[1]})) != 0
os.write(1, base64.b64decode({base64.b64encode(encoded.getvalue())!r}))
'''
            assert run(document, extra=script(body))[0] == 1, 'sandbox canary assertions failed'
            listener.close()
            # A successful conversion cannot publish pixels from an obsolete source.
            delayed = script('import os, time, base64\ntime.sleep(.35)\nos.write(1, base64.b64decode(' + repr(base64.b64encode(encoded.getvalue())) + '))\n')
            changing = subprocess.Popen(command(document), env=env | delayed, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            time.sleep(.15)
            original = document.stat()
            os.utime(document, ns=(original.st_atime_ns, original.st_mtime_ns + 10_000_000))
            data, stderr = changing.communicate(timeout=3)
            assert changing.returncode == 0 and data[4] == 3 and b'changed' in data[16:], (data[:100], stderr)
            # Hold stdout open from a descendant and cancel the outer helper.
            extra = script('import os, time\npid = os.fork()\ntime.sleep(30)\n')
            proc = subprocess.Popen(command(document), env=env | extra, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            time.sleep(.2)
            descendants = []
            def children(pid):
                path = Path(f'/proc/{pid}/task/{pid}/children')
                return [int(p) for p in path.read_text().split()] if path.exists() else []
            pending = children(proc.pid)
            while pending:
                pid = pending.pop()
                descendants.append(pid)
                pending.extend(children(pid))
            assert descendants, 'converter did not launch'
            proc.kill()
            proc.communicate(timeout=2)
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                live = [p for p in descendants if Path(f'/proc/{p}/stat').exists() and Path(f'/proc/{p}/stat').read_text().split()[2] != 'Z']
                if not live:
                    break
                time.sleep(.02)
            assert not live, ('descendants survived cancellation', live)
            print('PASS missing tools, crashes, output/stderr floods, deadlines, confinement and descendant cancellation', flush=True)
        return {'pdf': 'Poppler first page', 'video': ['MP4', 'MOV', 'Matroska', 'AVI', 'WebM'], 'codecs': ['MPEG-4 Part 2', 'H.264', 'VP9'], 'fault_injection': faults, **metrics}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--faults', action='store_true')
    args = parser.parse_args()
    check(str(args.binary.resolve()), args.faults)
