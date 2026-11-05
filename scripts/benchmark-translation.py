#!/usr/bin/env python3
"""Local paired translation benchmark; corpus and model weights stay in artifacts/."""
import argparse
import hashlib
import json
import random
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'artifacts/translation-benchmark'


def read_rows(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line]


def prepare(count):
    from sacrebleu import get_source_file, get_reference_files
    WORK.mkdir(parents=True, exist_ok=True)
    wmt_path = WORK / 'wmt.json'
    if not wmt_path.exists():
        url = ('https://huggingface.co/datasets/google/wmt24pp/resolve/'
               'fd7405c06494bc66a57b25f55d217a72f96e60dc/en-ja_JP.jsonl')
        urllib.request.urlretrieve(url, wmt_path)
    wmt = read_rows(WORK / 'wmt.json')
    eligible = [(i, r) for i, r in enumerate(wmt)
                if not r.get('is_bad_source', False) and r['domain'] != 'canary'
                and r['source'].strip() and r['target'].strip()]
    selected = random.Random(20261105).sample(eligible, count)
    rows = [dict(id=f'wmt24pp-en-ja-{i}', dataset='wmt24pp', source_lang='en',
                 target_lang='ja', source=r['source'], reference=r['target'],
                 domain=r['domain'], original_index=i) for i, r in selected]
    src = Path(get_source_file('wmt20', 'ja-en'))
    ref = Path(get_reference_files('wmt20', 'ja-en')[0])
    pairs = list(zip(src.read_text().splitlines(), ref.read_text().splitlines()))
    eligible_ja = [(i, s, t) for i, (s, t) in enumerate(pairs) if s.strip() and t.strip()]
    for i, s, t in random.Random(20261105).sample(eligible_ja, count):
        rows.append(dict(id=f'wmt20-ja-en-{i}', dataset='wmt20', source_lang='ja',
                         target_lang='en', source=s, reference=t, original_index=i))
    # Alternate direction to reduce temporal/thermal bias between directions.
    rows = [r for pair in zip(rows[:count], rows[count:]) for r in pair]
    src23 = Path(get_source_file('wmt23', 'ja-en'))
    ref23 = Path(get_reference_files('wmt23', 'ja-en')[0])
    pairs23 = list(zip(src23.read_text().splitlines(), ref23.read_text().splitlines()))
    eligible23 = [(i, s, t) for i, (s, t) in enumerate(pairs23) if s.strip() and t.strip()]
    for i, s, t in random.Random(20261105).sample(eligible23, count):
        rows.append(dict(id=f'wmt23-ja-en-{i}', dataset='wmt23', source_lang='ja',
                         target_lang='en', source=s, reference=t, original_index=i))
    (WORK / 'samples.jsonl').write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in rows))
    manifest = dict(seed=20261105, per_dataset=count, wmt24_total=len(wmt),
                    wmt24_eligible=len(eligible), wmt20_total=len(pairs),
                    wmt20_source_sha256=hashlib.sha256(src.read_bytes()).hexdigest(),
                    wmt20_reference_sha256=hashlib.sha256(ref.read_bytes()).hexdigest(),
                    wmt24_sha256=hashlib.sha256(wmt_path.read_bytes()).hexdigest(),
                    wmt23_total=len(pairs23),
                    wmt23_source_sha256=hashlib.sha256(src23.read_bytes()).hexdigest(),
                    wmt23_reference_sha256=hashlib.sha256(ref23.read_bytes()).hexdigest(),
                    samples_sha256=hashlib.sha256((WORK/'samples.jsonl').read_bytes()).hexdigest())
    (WORK / 'samples-manifest.json').write_text(json.dumps(manifest, indent=2))
    print(json.dumps(manifest, indent=2))


def translate(row, model, port):
    source, target = row['source_lang'], row['target_lang']
    payload = dict(model=model, stream=True, temperature=0.1, seed=42, max_tokens=1024,
                   cache_prompt=False)
    if model.startswith('plamo'):
        endpoint = '/v1/completions'
        payload['prompt'] = ('<|plamo:tag|>dataset<|plamo:msg|>translation'
                             '<|plamo:tag|>input<|plamo:msg|>' + row['source'] +
                             '<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>' +
                             target + '<|plamo:msg|>')
        payload['stop'] = ['<|plamo:tag|>', '<|plamo:bos|>']
    else:
        endpoint = '/v1/completions'
        sl, tl = ('English', 'Japanese') if source == 'en' else ('Japanese', 'English')
        # Same documented TranslateGemma prompt used in Kotoba's Ollama adapter.
        prompt = (f'You are a professional {sl} ({source}) to {tl} ({target}) translator. '
                  f'Your goal is to accurately convey the meaning and nuances of the original {sl} text '
                  f'while adhering to {tl} grammar, vocabulary, and cultural sensitivities.\n'
                  f'Produce only the {tl} translation, without any additional explanations or commentary. '
                  f'Please translate the following {sl} text into {tl}:\n\n\n' + row['source'])
        # Render the official GGUF template directly. Passing this instruction to
        # Chat Completions would wrap it in a second translation instruction.
        # llama.cpp adds the model's BOS token automatically, as for PFML3 above.
        payload['prompt'] = ('<start_of_turn>user\n' + prompt.strip() +
                             '<end_of_turn>\n<start_of_turn>model\n')
        payload['stop'] = ['<end_of_turn>']
    req = urllib.request.Request(f'http://127.0.0.1:{port}' + endpoint,
                                 data=json.dumps(payload).encode(),
                                 headers={'Content-Type': 'application/json'})
    start = time.perf_counter()
    first, output, reason = None, '', None
    with urllib.request.urlopen(req, timeout=180) as response:
        for raw in response:
            if not raw.startswith(b'data: '):
                continue
            raw = raw[6:].strip()
            if raw == b'[DONE]':
                break
            event = json.loads(raw)
            if 'error' in event:
                raise RuntimeError(event['error'])
            for choice in event.get('choices', []):
                text = choice.get('text') or choice.get('delta', {}).get('content') or ''
                if text and first is None:
                    first = time.perf_counter() - start
                output += text
                reason = choice.get('finish_reason') or reason
    if not output.strip() or reason != 'stop':
        raise RuntimeError(f'incomplete response: finish_reason={reason}, chars={len(output)}')
    return dict(prediction=output, first_text_seconds=first,
                total_seconds=time.perf_counter() - start, finish_reason=reason, error=None)


def run(model, port, limit):
    rows = read_rows(WORK / 'samples.jsonl')
    if limit:
        rows = rows[:limit]
    # Record a separate warmup; exclude it from quality and steady-state latency.
    warmup = dict(id='warmup', source_lang='en', target_lang='ja',
                  source='The meeting will start at ten tomorrow morning.')
    (WORK / f'{model}-warmup.json').write_text(json.dumps(translate(warmup, model, port), indent=2))
    path = WORK / f'{model}.jsonl'
    done = {r['id'] for r in read_rows(path)} if path.exists() else set()
    with path.open('a') as out:
        for i, row in enumerate(rows):
            if row['id'] in done:
                continue
            record = dict(row, model=model)
            try:
                record.update(translate(row, model, port))
            except Exception as exc:
                record.update(prediction='', error=str(exc), total_seconds=None, first_text_seconds=None)
            out.write(json.dumps(record, ensure_ascii=False) + '\n')
            out.flush()
            print(f'{model} {i+1}/{len(rows)} {row["id"]} {record["total_seconds"]} {record["error"]}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'run'])
    parser.add_argument('--count', type=int, default=100)
    parser.add_argument('--model', default='plamo-2b')
    parser.add_argument('--port', type=int, default=18080)
    parser.add_argument('--limit', type=int)
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.count)
    else:
        run(args.model, args.port, args.limit)
