#!/usr/bin/env python3
"""Observe every selected public cell in serial, independently admitted cohorts."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import dictation_corpus as corpus
import run_dictation_model_baseline as runner
from materialize_dictation_corpus import publish_json


def partition(entries, cases, maximum_cells):
    corpus.require(corpus.integer(maximum_cells, 1, 16), 'cohort size must be within 1...16')
    groups, current, frames = [], [], 0
    for case in cases:
        count = entries[case]['frames']
        corpus.require(count <= 1_920_000, 'one cell exceeds the cohort audio bound')
        if current and (len(current) == maximum_cells or frames + count > 1_920_000):
            groups.append(current)
            current, frames = [], 0
        current.append(case)
        frames += count
    if current:
        groups.append(current)
    return groups


def receipt_hashes(directory):
    hashes = {}
    for name in ('request.json', 'model.json', 'outcome.json'):
        path = directory / name
        corpus.require(path.is_file() and not path.is_symlink(), 'cohort receipt is not a regular file')
        _, hashes[name] = corpus.read_json(path, maximum_bytes=8_000_000)
    return hashes


def run(audio_root, cases, bundle, output, xctest, *, maximum_cells=16, invoke=subprocess.run):
    _, cells = corpus.read_public_corpus()
    selected = sorted(cells) if cases is None else cases
    corpus.require(type(selected) is list and selected and all(type(case) is str for case in selected)
                   and len(set(selected)) == len(selected) and set(selected) <= cells.keys(),
                   'select unique reviewed corpus cells')
    manifest, manifest_digest = corpus.read_json(audio_root / 'manifest.json')
    corpus.validate_audio_manifest(manifest, cells, audio_root)
    entries = {entry['caseID']: entry for entry in manifest['entries']}
    groups = partition(entries, selected, maximum_cells)
    corpus.require(xctest.is_file(), 'prebuilt XCTest launcher is required')
    identity = runner.bundle_identity(bundle)
    binary_digest = identity[0][0]
    plan = [{'id': f'cohort-{index:04d}', 'cases': group,
             'timeoutSeconds': runner.run_deadline(entries, group, False)} for index, group in enumerate(groups)]
    output.mkdir(mode=0o700)
    publish_json(output / 'matrix-request.json', {
        'kind': 'dictation-controller-matrix-request', 'schemaVersion': 1,
        'corpusSHA256': corpus.CORPUS_SHA256, 'manifestSHA256': manifest_digest,
        'testBinarySHA256': binary_digest, 'cohorts': plan, 'passesPerCohort': 2,
        'processPolicy': 'fresh-process-per-cohort-two-local-passes',
        'fullPublicCorpusSelected': set(selected) == cells.keys(),
        'sourceCommitQualified': False, 'verifiedDeliveryMeasured': False,
    })
    _, plan_digest = corpus.read_json(output / 'matrix-request.json')
    completed, states = [], []
    state = 'incomplete'
    try:
        for cohort in plan:
            corpus.require(runner.bundle_identity(bundle) == identity, 'matrix test bundle changed')
            directory = output / cohort['id']
            request_digest = None
            def execute(arguments, **options):
                nonlocal request_digest
                _, request_digest = corpus.read_json(directory / 'request.json')
                return invoke(arguments, **options)
            result = runner.run(audio_root, cohort['cases'], bundle, directory, xctest,
                                controller=True, invoke=execute)
            states.append({'id': cohort['id'], 'outcome': result['outcome']})
            request, digest = corpus.read_json(directory / 'request.json')
            corpus.require(digest == request_digest and request['testBinarySHA256'] == binary_digest
                           and request['manifestSHA256'] == manifest_digest
                           and request['cases'] == cohort['cases'], 'cohort identity changed')
            if result['outcome'] != 'observed':
                break
            observation, _ = corpus.read_json(directory / 'model.json', maximum_bytes=8_000_000)
            runner.validate_controller_observation(observation, request, cells, entries)
            if completed:
                corpus.require(observation['modelRevision'] == completed[0][2], 'matrix model revision changed')
            completed.append((cohort, receipt_hashes(directory), observation['modelRevision']))
        # Re-admit earlier evidence too: a later cohort must not replace its
        # predecessor's receipt or quietly switch the matrix's input/binary.
        corpus.require(runner.bundle_identity(bundle) == identity, 'matrix test bundle changed')
        corpus.require(corpus.read_json(output / 'matrix-request.json')[1] == plan_digest, 'matrix plan changed')
        after, digest = corpus.read_json(audio_root / 'manifest.json')
        corpus.require(after == manifest and digest == manifest_digest, 'matrix manifest changed')
        corpus.validate_audio_manifest(after, cells, audio_root)
        for cohort, hashes, _ in completed:
            corpus.require(receipt_hashes(output / cohort['id']) == hashes, 'completed cohort changed')
        if len(completed) == len(plan):
            state = 'observed'
    except (OSError, corpus.CorpusError, TypeError, KeyError):
        state = 'invalid-observation'
    result = {
        'kind': 'dictation-controller-matrix-outcome', 'schemaVersion': 1, 'outcome': state,
        'selectedCells': len(selected), 'plannedCohorts': len(plan), 'cohorts': states,
        'observedCells': 0 if state == 'invalid-observation' else sum(len(item[0]['cases']) for item in completed),
        'passesPerCohort': 2, 'fullPublicCorpusSelected': set(selected) == cells.keys(),
        'processPolicy': 'fresh-process-per-cohort-two-local-passes',
        'qualityAccepted': False, 'sourceCommitQualified': False, 'verifiedDeliveryMeasured': False,
    }
    publish_json(output / 'matrix-outcome.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audio-root', type=Path, required=True)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--all', action='store_true', help='Select the entire pinned public corpus')
    selection.add_argument('--case', action='append', dest='cases')
    parser.add_argument('--cohort-size', type=int, default=16, help='Maximum cells per process, within 1...16')
    parser.add_argument('--test-bundle', type=Path, required=True)
    parser.add_argument('--xctest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New private directory; never overwritten')
    args = parser.parse_args()
    previous = os.umask(0o077)
    try:
        result = run(args.audio_root, args.cases, args.test_bundle, args.output, args.xctest,
                     maximum_cells=args.cohort_size)
        print(json.dumps(result, sort_keys=True, allow_nan=False))
        return 0 if result['outcome'] == 'observed' else 2
    except (OSError, corpus.CorpusError):
        print('dictation matrix: input or output could not be admitted', file=sys.stderr)
        return 2
    finally:
        os.umask(previous)


if __name__ == '__main__':
    raise SystemExit(main())
