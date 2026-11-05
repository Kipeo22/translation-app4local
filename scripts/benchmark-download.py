#!/usr/bin/env python3
"""Download pinned benchmark weights using verified HTTP byte ranges."""
import concurrent.futures
import hashlib
import json
import os
import time
import urllib.request
from pathlib import Path

WORK = Path(__file__).resolve().parents[1] / 'artifacts/translation-benchmark'
MODELS = [
    ('plamo-2b.gguf', 'pfnet/plamo-3-translate-2b-GGUF',
     'f2b4599dff9b3e45c62567eac15e83186b4cb64e', 'plamo-3-translate-2b-Q4_K_M.gguf'),
    ('gemma-12b.gguf', 'bullerwins/translategemma-12b-it-GGUF',
     'd7d1d8cc4ff53d4bc883ef33eae3894f07833b63', 'translategemma-12b-it-Q4_K_M.gguf'),
]


def download(name, repo, revision, filename):
    (WORK / 'models').mkdir(parents=True, exist_ok=True)
    url = f'https://huggingface.co/{repo}/resolve/{revision}/{filename}'
    req = urllib.request.Request(url, headers={'Range': 'bytes=0-0'})
    with urllib.request.urlopen(req, timeout=90) as response:
        total = int(response.headers['Content-Range'].split('/')[-1])
    path = WORK / 'models' / name
    chunk = 32 * 1024 * 1024
    # An existing partial file must contain a sequentially downloaded prefix.
    complete = path.stat().st_size if path.exists() else 0
    marker = WORK / f'{name}.download.json'
    if complete == total and marker.exists():
        return
    if complete >= total:
        raise RuntimeError(f'{path}: full-sized file without completion marker; verify it before reuse')
    first = complete // chunk * chunk
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    os.ftruncate(fd, total)

    def part(start):
        end = min(start + chunk, total) - 1
        expected = f'bytes {start}-{end}/{total}'
        for attempt in range(5):
            try:
                request = urllib.request.Request(url, headers={'Range': f'bytes={start}-{end}'})
                with urllib.request.urlopen(request, timeout=120) as response:
                    if response.headers.get('Content-Range') != expected:
                        raise RuntimeError('Server returned the wrong byte range')
                    position = start
                    while data := response.read(1024 * 1024):
                        os.pwrite(fd, data, position)
                        position += len(data)
                    if position != end + 1:
                        raise RuntimeError('Incomplete byte range')
                return end-start+1
            except Exception:
                if attempt == 4:
                    raise
                time.sleep(1 + attempt)
    try:
        done = first
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            for size in pool.map(part, range(first, total, chunk)):
                done += size
                print(f'{name}: {done/total:.1%} ({done}/{total})', flush=True)
    except BaseException:
        # A preallocated file cannot be mistaken for a completed sequential download.
        os.ftruncate(fd, first)
        raise
    finally:
        os.close(fd)
    digest = hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()
    marker.write_text(json.dumps(dict(repo=repo, revision=revision, filename=filename,
                                     bytes=total, sha256=digest), indent=2))


if __name__ == '__main__':
    for model in MODELS:
        download(*model)
