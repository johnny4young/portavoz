#!/usr/bin/env python3
"""Compare Parakeet v3 and Ultra, one model per process, and apply the T38 rule."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import dictation_corpus as corpus
import dictation_field_corpus as field
from materialize_dictation_corpus import publish_json

ROOT = Path(__file__).resolve().parents[1]
SELECTOR = 'PortavozTests.DictationModelComparisonTests/testParakeetV3AgainstUltraOnPublicCells'
MODELS = {'v3': 'parakeet-tdt-0.6b-v3-coreml', 'ultra': 'parakeet-ultra-coreml'}
COHORTS = ('en', 'es', 'mixed')
# Fixed before any field data was seen; see the decision recorded for T38.
MINIMUM_RELATIVE_WER_REDUCTION = 0.15
MAXIMUM_EXTRA_PEAK_BYTES = 150 * 1_048_576
MAXIMUM_EXTRA_WARM_LOAD_SECONDS = 1.0


def admitted_manifest(audio_root):
    """Return (corpus kind, manifest entries); every byte is re-read before launch."""
    document, cells = corpus.read_public_corpus()
    manifest, _ = corpus.read_json(audio_root / 'manifest.json')
    if manifest.get('kind') == field.KIND:
        field.validate(manifest, audio_root, document)
        return 'field-microphone', manifest['entries']
    corpus.validate_audio_manifest(manifest, cells, audio_root)
    return 'public-synthetic', manifest['entries']


def deadline(entries, cases):
    frames = {entry['caseID']: entry['frames'] for entry in entries}
    seconds = sum(frames[case] for case in cases) / 16_000 * 3 + 600
    corpus.require(seconds <= 7_200, 'selection exceeds run duration bound; select fewer cells')
    return seconds


def validate_receipt(receipt, kind, model, cases):
    corpus.require(receipt.get('kind') == 'dictation-model-comparison-observation'
                   and receipt.get('schemaVersion') == 2 and receipt.get('corpus') == kind
                   and receipt.get('corpusSHA256') == corpus.CORPUS_SHA256, 'comparison receipt provenance mismatch')
    models = receipt.get('models')
    corpus.require(type(models) is list and len(models) == 1 and models[0].get('model') == MODELS[model],
                   'a receipt must hold exactly the selected model')
    corpus.require(sorted(cell.get('caseID') for cell in receipt['cells']) == sorted(cases)
                   and all(cell.get('model') == MODELS[model] for cell in receipt['cells']),
                   'receipt cells differ from the request')
    return receipt


def cell_errors(cell, words):
    """(word errors, reference words); a failed cell delivered nothing, so every word is an error."""
    score = cell['score']
    if score is None:
        return words[cell['caseID']], words[cell['caseID']]
    return score['wordErrorRate'] * score['referenceWords'], score['referenceWords']


def weighted_wer(cells, words):
    pairs = [cell_errors(cell, words) for cell in cells]
    total = sum(reference for _, reference in pairs)
    return sum(errors for errors, _ in pairs) / total if total else None


def cell_rate(cell, words):
    errors, reference = cell_errors(cell, words)
    return errors / reference if reference else 0.0


def summarize(receipt, warmup, words, cohorts):
    cells = receipt['cells']
    model = receipt['models'][0]
    by_cohort = {cohort: weighted_wer([c for c in cells if cohorts[c['caseID']] == cohort], words)
                 for cohort in sorted(set(cohorts.values()))}
    return {
        'wordErrorRate': weighted_wer([c for c in cells if words[c['caseID']] > 0], words),
        'wordErrorRateByCohort': by_cohort,
        'exactMatches': sum(1 for c in cells if c['score'] and c['score']['exactReferenceMatch']),
        'failedCells': sum(1 for c in cells if c['score'] is None),
        'criticalCellsWithErrors': sum(1 for c in cells if c['critical'] and words[c['caseID']] > 0
                                       and (c['score'] is None or c['score']['wordErrorRate'] > 0)),
        'firstLoadSeconds': warmup['models'][0]['loadSeconds'], 'warmLoadSeconds': model['loadSeconds'],
        'residentGrowthBytes': model['footprintAfterLoadBytes'] - model['footprintBeforeLoadBytes'],
        'footprintAfterCellsBytes': model['footprintAfterCellsBytes'],
        'peakFootprintBytes': model['peakFootprintBytes'],
    }


def decide(kind, v3, ultra):
    """The pre-registered T38 rule; synthetic evidence can never promote Ultra."""
    if kind != 'field-microphone':
        return {'verdict': 'not-applicable', 'failedCriteria': ['field-microphone evidence required']}
    failed = []
    for cohort in COHORTS:
        before, after = v3['wordErrorRateByCohort'].get(cohort), ultra['wordErrorRateByCohort'].get(cohort)
        if not before or after is None or (before - after) / before < MINIMUM_RELATIVE_WER_REDUCTION:
            failed.append(f'{cohort} relative WER reduction below 15%')
    if ultra['criticalCellsWithErrors'] > v3['criticalCellsWithErrors']:
        failed.append('more critical cells with errors than v3')
    if ultra['peakFootprintBytes'] > v3['peakFootprintBytes'] + MAXIMUM_EXTRA_PEAK_BYTES:
        failed.append('peak footprint exceeds v3 by more than 150 MiB')
    if ultra['warmLoadSeconds'] > v3['warmLoadSeconds'] + MAXIMUM_EXTRA_WARM_LOAD_SECONDS:
        failed.append('warm load exceeds v3 by more than 1 s')
    return {'verdict': 'stay-opt-in' if failed else 'default-for-dictation', 'failedCriteria': failed}


def report(kind, receipts, warmups, document):
    families = {family['id']: family for family in document['families']}
    family_of = lambda case: families[case.rsplit('.', 1)[0]]
    cases = [cell['caseID'] for cell in receipts['v3']['cells']]
    words = {case: len(family_of(case)['acceptedTexts'][0].split()) for case in cases}
    cohorts = {case: family_of(case)['cohort'] for case in cases}
    v3, ultra = (summarize(receipts[name], warmups[name], words, cohorts) for name in ('v3', 'ultra'))
    rates = {name: {c['caseID']: cell_rate(c, words) for c in receipts[name]['cells']} for name in receipts}
    worse = sorted(case for case in cases if rates['ultra'][case] > rates['v3'][case])
    better = sorted(case for case in cases if rates['ultra'][case] < rates['v3'][case])
    return {'schemaVersion': 1, 'kind': 'dictation-model-comparison-report', 'corpus': kind,
            'cellCount': len(cases), 'models': {'v3': v3, 'ultra': ultra},
            'ultraBetterCells': len(better), 'ultraWorseCells': len(worse),
            'ultraWorseCriticalCells': [case for case in worse if family_of(case)['critical']],
            'decision': decide(kind, v3, ultra)}


def launch(model, cases, path, audio_root, models_root, bundle, xctest, timeout, invoke):
    """Child output is never retained: XCTest argument errors can dump environment."""
    environment = {'HOME': str(Path.home()), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'en_US.UTF-8',
                   'PORTAVOZ_ASR_COMPARE_AUDIO': str(audio_root.resolve()),
                   'PORTAVOZ_ASR_COMPARE_MODELS': str(models_root.resolve()),
                   'PORTAVOZ_ASR_COMPARE_OUTPUT': str(path.resolve()),
                   'PORTAVOZ_ASR_COMPARE_MODEL': model,
                   'PORTAVOZ_ASR_COMPARE_CASES': ','.join(cases)}
    try:
        result = invoke([str(xctest), '-XCTest', SELECTOR, str(bundle.resolve())], cwd=ROOT, env=environment,
                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return {'outcome': 'timed-out', 'model': model}
    if result.returncode != 0:
        return {'outcome': 'tests-failed', 'model': model, 'exitCode': result.returncode}
    return None


def run(audio_root, models_root, bundle, xctest, output, cases=None, invoke=subprocess.run):
    """A one-cell warm-up process per model fills Core ML's compiled cache, so the
    measured process loads the way a dictation does after an idle release."""
    document, _ = corpus.read_public_corpus()
    kind, entries = admitted_manifest(audio_root)
    cases = cases or sorted(entry['caseID'] for entry in entries)
    corpus.require(len(set(cases)) == len(cases) and set(cases) <= {e['caseID'] for e in entries},
                   'select unique cells from the admitted manifest')
    corpus.require(xctest.is_file() and bundle.is_dir() and models_root.is_dir(),
                   'prebuilt XCTest launcher, bundle and scratch model store are required')
    timeout = deadline(entries, cases)
    output.mkdir(mode=0o700)
    receipts, warmups = {}, {}
    for model in MODELS:
        for name, selected, store in ((f'{model}-warmup', cases[:1], warmups), (model, cases, receipts)):
            path = output / f'{name}.json'
            if failure := launch(model, selected, path, audio_root, models_root, bundle, xctest, timeout, invoke):
                return failure
            receipt, _ = corpus.read_json(path, maximum_bytes=8_000_000)
            store[model] = validate_receipt(receipt, kind, model, selected)
    corpus.require(receipts['v3']['manifestSHA256'] == receipts['ultra']['manifestSHA256'],
                   'the models measured different manifests')
    admitted_manifest(audio_root)
    document_report = report(kind, receipts, warmups, document)
    publish_json(output / 'report.json', document_report)
    return {'outcome': 'observed', **document_report}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audio-root', type=Path, required=True)
    parser.add_argument('--models', type=Path, required=True, help='Scratch model store with both models verified')
    parser.add_argument('--test-bundle', type=Path, required=True)
    parser.add_argument('--xctest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New private directory; never overwritten')
    parser.add_argument('--case', action='append', dest='cases')
    args = parser.parse_args()
    previous = os.umask(0o077)
    try:
        result = run(args.audio_root, args.models, args.test_bundle, args.xctest, args.output, args.cases)
        print(json.dumps(result, sort_keys=True, indent=2, allow_nan=False))
        return 0 if result['outcome'] == 'observed' else 2
    except (OSError, corpus.CorpusError) as error:
        print(f'model comparison: {error}', file=sys.stderr)
        return 2
    finally:
        os.umask(previous)


if __name__ == '__main__':
    raise SystemExit(main())
