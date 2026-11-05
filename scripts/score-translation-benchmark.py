#!/usr/bin/env python3
"""Score saved predictions. Run after latency collection to avoid GPU contention."""
import argparse
import hashlib
import json
import random
import statistics
from pathlib import Path

from sacrebleu.metrics import CHRF

WORK = Path(__file__).resolve().parents[1] / 'artifacts/translation-benchmark'


def load(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--comet-checkpoint')
    args = parser.parse_args()
    samples = load(WORK / 'samples.jsonl')
    models = {}
    for name in ['apple-intelligence', 'plamo-2b', 'gemma-12b']:
        path = WORK / f'{name}.jsonl'
        if not path.exists():
            continue
        rows = load(path)
        assert len(rows) == len(samples), f'{name}: incomplete run ({len(rows)})'
        assert [r['id'] for r in rows] == [s['id'] for s in samples], name
        models[name] = rows
    if args.comet_checkpoint:
        from comet import load_from_checkpoint
        metric = load_from_checkpoint(args.comet_checkpoint)
        for name, rows in models.items():
            cache = WORK / f'{name}-comet.json'
            inputs = [dict(src=r['source'], mt=r['prediction'], ref=r['reference']) for r in rows]
            fingerprint = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
            checkpoint = str(Path(args.comet_checkpoint).resolve())
            cached = json.loads(cache.read_text()) if cache.exists() else None
            if isinstance(cached, dict) and cached.get('inputs_sha256') == fingerprint and cached.get('checkpoint') == checkpoint:
                scores = cached['scores']
            else:
                result = metric.predict(inputs, batch_size=8, gpus=0, num_workers=1)
                scores = list(result.scores)
                cache.write_text(json.dumps(dict(inputs_sha256=fingerprint, checkpoint=checkpoint, scores=scores)))
            assert len(scores) == len(rows)
            for row, score in zip(rows, scores):
                row['comet'] = score
    chrf = CHRF(word_order=2)
    summary = {}
    for name, rows in models.items():
        summary[name] = {}
        for dataset in ['wmt24pp', 'wmt23', 'wmt20']:
            group = [r for r in rows if r['dataset'] == dataset]
            successes = [r for r in group if not r['error']]
            result = dict(n=len(group), failures=len(group)-len(successes),
                          chrf_pp=chrf.corpus_score([r['prediction'] for r in group],
                                                   [[r['reference'] for r in group]]).score)
            for key in ['first_text_seconds', 'total_seconds']:
                values = sorted(r[key] for r in successes if r.get(key) is not None)
                result[key + '_median'] = statistics.median(values) if values else None
                result[key + '_p95'] = values[min(len(values)-1, int(.95 * len(values)))] if values else None
            if args.comet_checkpoint:
                # Failed outputs, including empty or partial text, remain in this score.
                result['comet_all'] = statistics.mean(r['comet'] for r in group)
                result['comet_success_only'] = statistics.mean(r['comet'] for r in successes) if successes else None
            summary[name][dataset + ('-en-ja' if dataset == 'wmt24pp' else '-ja-en')] = result
    comparisons = {}
    if args.comet_checkpoint and 'plamo-2b' in models:
        for baseline in models:
            if baseline == 'plamo-2b':
                continue
            for dataset in ['wmt24pp', 'wmt23', 'wmt20']:
                pairs = [(p, b) for p, b in zip(models['plamo-2b'], models[baseline])
                         if p['dataset'] == dataset and not p['error'] and not b['error']]
                diffs = [p['comet']-b['comet'] for p, b in pairs]
                rng = random.Random(20261105)
                boot = sorted(statistics.mean(rng.choices(diffs, k=len(diffs))) for _ in range(2000))
                comparisons[f'plamo-2b_minus_{baseline}_{dataset}'] = dict(
                    n=len(diffs), paired_successful_only=True, mean_difference=statistics.mean(diffs),
                    bootstrap_95ci=[boot[49], boot[1949]],
                    higher_sentence_scores=sum(d > 0 for d in diffs),
                    lower_sentence_scores=sum(d < 0 for d in diffs))
    result = dict(models=summary, paired_comet=comparisons,
                  chrf_signature=str(chrf.get_signature()))
    (WORK / 'summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
