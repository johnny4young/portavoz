#!/usr/bin/env python3
"""Run the prebuilt Release XCTest model lane on explicitly selected public audio."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
from xml.parsers.expat import ExpatError

import dictation_corpus as corpus
from dictation_model_receipt import validate_attribution, validate_observation
from dictation_controller_receipt import validate_observation as validate_controller_observation
from materialize_dictation_corpus import publish_json

ROOT = Path(__file__).resolve().parents[1]
SELECTOR = 'PortavozTests.DictationModelBaselineTests/testInstalledParakeetOnExplicitPublicCells'
CONTROLLER_SELECTOR = 'PortavozTests.DictationControllerModelTests/testInstalledParakeetThroughControllerOnExplicitPublicCells'


def run_deadline(entries, cases, attribute_live, repetitions=1):
    corpus.require(corpus.integer(repetitions, 1, 12), 'repetitions must be within 1...12')
    corpus.require(all(entries[case]['frames'] <= 1_920_000 // repetitions for case in cases),
                   'repeated cell exceeds the 120-second PCM bound')
    audio_seconds = sum(entries[case]['frames'] / 16_000 for case in cases) * repetitions
    deadline = audio_seconds * (4 if attribute_live else 2) + 300
    corpus.require(deadline <= 7_200, 'selection exceeds run duration bound; select smaller sequential groups')
    return deadline


def binary_identity(executable):
    digest = hashlib.sha256()
    with executable.open('rb') as stream:
        before = os.fstat(stream.fileno())
        for block in iter(lambda: stream.read(1_048_576), b''):
            digest.update(block)
        after = os.fstat(stream.fileno())
    identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    corpus.require(identity(before) == identity(after) == identity(executable.stat()),
                   'test executable changed while hashing')
    return digest.hexdigest(), identity(after)


def bundle_identity(bundle):
    """Resolve XCTest's declared executable, not a build-system filename guess."""
    try:
        with (bundle / 'Contents/Info.plist').open('rb') as stream:
            data = stream.read(65_537)
        corpus.require(len(data) <= 65_536, 'test bundle metadata exceeds bound')
        metadata = plistlib.loads(data)
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError, RecursionError) as error:
        raise corpus.CorpusError('test bundle metadata is unreadable or malformed') from error
    name = metadata.get('CFBundleExecutable') if type(metadata) is dict else None
    corpus.require(type(name) is str and name not in ('', '.', '..')
                   and '/' not in name and '\0' not in name, 'test bundle executable name is invalid')
    executable = bundle / 'Contents/MacOS' / name
    corpus.require(executable.is_file() and not executable.is_symlink()
                   and executable.resolve().is_relative_to(bundle.resolve()),
                   'declared test executable is missing or outside the bundle')
    return binary_identity(executable), hashlib.sha256(data).hexdigest()


def run(audio_root, cases, bundle, output, xctest, *, attribute_live=False, repetitions=1, controller=False, invoke=subprocess.run):
    """Child output is never retained: even XCTest argument errors can dump environment."""
    corpus.require(type(controller) is bool and not (controller and attribute_live),
                   'controller and independent vendor attribution are separate lanes')
    _, cells = corpus.read_public_corpus()
    manifest, manifest_digest = corpus.read_json(audio_root / 'manifest.json')
    corpus.validate_audio_manifest(manifest, cells, audio_root)
    corpus.require(cases and len(set(cases)) == len(cases) and set(cases) <= cells.keys(),
                   'select unique reviewed corpus cells')
    entries = {entry['caseID']: entry for entry in manifest['entries']}
    timeout = run_deadline(entries, cases, attribute_live, repetitions)
    corpus.require(xctest.is_file(), 'prebuilt XCTest launcher is required')
    # This digest identifies the measured binary, not proof of a clean committed build.
    identity = bundle_identity(bundle)
    binary_digest = identity[0][0]
    output.mkdir(mode=0o700)
    request = {'schemaVersion': 2, 'kind': 'dictation-model-run-request', 'cases': cases, 'passes': 2,
               'corpusSHA256': corpus.CORPUS_SHA256, 'testBinarySHA256': binary_digest,
               'manifestSHA256': manifest_digest,
               'timeoutSeconds': timeout, 'sourceCommitQualified': False, 'stageAttribution': attribute_live,
               'repetitions': repetitions, 'sequence': 'repeat-admitted-pcm-and-reference'}
    if controller:
        request.update(schemaVersion=3, controller=True)
    publish_json(output / 'request.json', request)
    published_request, request_digest = corpus.read_json(output / 'request.json')
    corpus.require(published_request == request, 'published request changed before launch')
    environment = {'HOME': str(Path.home()), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'en_US.UTF-8',
                   'PORTAVOZ_DICTATION_BASELINE_AUDIO': str(audio_root.resolve()),
                   'PORTAVOZ_DICTATION_BASELINE_CASES': ','.join(cases),
                   'PORTAVOZ_DICTATION_REPETITIONS': str(repetitions),
                   'PORTAVOZ_DICTATION_BASELINE_OUTPUT': str((output / 'model.json').resolve())}
    if attribute_live:
        environment['PORTAVOZ_DICTATION_ATTRIBUTE_LIVE'] = '1'
    if controller:
        environment['PORTAVOZ_DICTATION_CONTROLLER'] = '1'
    started = time.monotonic()
    state, exit_code = 'launcher-failed', None
    try:
        result = invoke([str(xctest), '-XCTest', CONTROLLER_SELECTOR if controller else SELECTOR, str(bundle.resolve())], cwd=ROOT,
                        env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, timeout=timeout, check=False)
        exit_code = result.returncode
        state = 'tests-failed'
        if exit_code == 0:
            # Evidence consumers read these files, not this process's retained
            # dictionaries. Equal JSON values do not preserve a recorded hash.
            after_request, after_request_digest = corpus.read_json(output / 'request.json')
            corpus.require(after_request == request and after_request_digest == request_digest,
                           'published request changed during measurement')
            corpus.require(bundle_identity(bundle) == identity,
                           'test bundle identity changed during measurement')
            receipt, _ = corpus.read_json(output / 'model.json', maximum_bytes=8_000_000)
            validator = validate_controller_observation if controller else validate_observation
            validator(receipt, request, cells, entries)
            # Re-admit every byte after native consumption; no mutated corpus is successful.
            after, after_digest = corpus.read_json(audio_root / 'manifest.json')
            corpus.require(after == manifest and after_digest == manifest_digest,
                           'audio manifest changed during measurement')
            corpus.validate_audio_manifest(after, cells, audio_root)
            state = 'observed'
    except subprocess.TimeoutExpired:
        state = 'timed-out'
    except (OSError, corpus.CorpusError, TypeError, AttributeError):
        state = 'invalid-observation'
    outcome = {'schemaVersion': 3 if controller else 2, 'kind': 'dictation-model-run-outcome', 'outcome': state,
               'exitCode': exit_code, 'elapsedSeconds': time.monotonic() - started,
               'selectedCells': len(cases), 'passes': 2, 'repetitions': repetitions, 'verifiedDeliveryMeasured': False,
               'sourceCommitQualified': False}
    publish_json(output / 'outcome.json', outcome)
    return outcome


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--controller', action='store_true', help='Observe the real controller; no native paste is dispatched')
    parser.add_argument('--repetitions', type=int, default=1, help='Repeat each admitted PCM/reference 1...12 times (max 120 seconds)')
    parser.add_argument('--attribute-live', action='store_true', help='Explicit vendor/mapper attribution experiment')
    parser.add_argument('--audio-root', type=Path, required=True)
    parser.add_argument('--case', action='append', required=True, dest='cases')
    parser.add_argument('--test-bundle', type=Path, required=True)
    parser.add_argument('--xctest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New private directory; never overwritten')
    args = parser.parse_args()
    previous = os.umask(0o077)
    try:
        result = run(args.audio_root, args.cases, args.test_bundle, args.output, args.xctest, attribute_live=args.attribute_live, repetitions=args.repetitions, controller=args.controller)
        print(json.dumps(result, sort_keys=True, allow_nan=False))
        return 0 if result['outcome'] == 'observed' else 2
    except (OSError, corpus.CorpusError):
        print('dictation model runner: input or output could not be admitted', file=sys.stderr)
        return 2
    finally:
        os.umask(previous)


if __name__ == '__main__':
    raise SystemExit(main())
