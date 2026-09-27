"""Native-launch ownership tests with explicit process doubles, never ASR evidence."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import dictation_corpus as corpus
import run_dictation_model_baseline as runner
from Tests.Tooling.test_dictation_materialization import NAMES, SpeechDouble
from materialize_dictation_corpus import materialize


class DictationModelRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.audio = self.root / 'audio'
        materialize(self.audio, NAMES, SpeechDouble())
        self.bundle = self.root / 'tests.xctest'
        executable = self.bundle / 'Contents/MacOS/PortavozPackageTests'
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b'explicit-test-double-not-an-executable')
        self.info = self.bundle / 'Contents/Info.plist'
        self.info.write_bytes(plistlib.dumps({'CFBundleExecutable': executable.name}))
        self.launcher = self.root / 'fake-xctest'
        self.launcher.touch()
        self.cases = ['en-payment-negation.clean', 'es-payment-negation.clean']
        self.calls = []

    def use_swiftbuild_layout(self, name='PortavozTests'):
        executable = self.bundle / 'Contents/MacOS' / name
        (executable.parent / 'PortavozPackageTests').rename(executable)
        self.info.write_bytes(plistlib.dumps({'CFBundleExecutable': executable.name}, fmt=plistlib.FMT_BINARY))
        return executable

    def test_current_swiftbuild_bundle_reaches_the_actual_model_launcher(self):
        executable = self.use_swiftbuild_layout()
        result = self.observe(self.successful_double)
        self.assertEqual(result['outcome'], 'observed')
        request = json.loads((self.root / 'run/request.json').read_text())
        self.assertEqual(request['testBinarySHA256'], hashlib.sha256(executable.read_bytes()).hexdigest())
        self.assertEqual(len(self.calls), 1)

    def test_declared_unicode_executable_is_not_replaced_by_a_name_allowlist(self):
        self.use_swiftbuild_layout('Pruebas café')
        result = self.observe(self.successful_double)
        self.assertEqual(result['outcome'], 'observed')
        self.assertEqual(len(self.calls), 1)

    def test_bundle_metadata_cannot_select_missing_or_escaping_executables(self):
        metadata = [[], {}, *({'CFBundleExecutable': value} for value in
                            ('', '.', '..', '../PortavozPackageTests', '/bin/sh', 'missing', '\0', True, 7))]
        for value in metadata:
            with self.subTest(metadata=value):
                self.info.write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_BINARY))
                with self.assertRaises(corpus.CorpusError):
                    self.observe(self.successful_double)
                self.assertFalse((self.root / 'run').exists())
                self.assertEqual(self.calls, [])

    def test_malformed_oversized_and_absent_bundle_metadata_never_launch(self):
        for data in (b'not a plist', b'<?xml version="1.0"?><plist><dict>', b' ' * 65_537, None):
            with self.subTest(size=None if data is None else len(data)):
                if data is None:
                    self.info.unlink()
                else:
                    self.info.write_bytes(data)
                with self.assertRaises(corpus.CorpusError):
                    self.observe(self.successful_double)
                self.assertFalse((self.root / 'run').exists())
                self.assertEqual(self.calls, [])

    def test_declared_executable_cannot_escape_through_a_symlink(self):
        executable = self.bundle / 'Contents/MacOS/PortavozPackageTests'
        outside = self.root / 'not-owned-by-bundle'
        executable.rename(outside)
        executable.symlink_to(outside)
        with self.assertRaises(corpus.CorpusError):
            self.observe(self.successful_double)
        self.assertFalse((self.root / 'run').exists())
        self.assertEqual(self.calls, [])

    def test_changed_bundle_metadata_cannot_retain_an_observed_outcome(self):
        def rewrite_metadata(arguments, **options):
            result = self.successful_double(arguments, **options)
            # Same executable and decoded values; the bundle consumed by
            # XCTest must still retain its original declared identity.
            self.info.write_bytes(plistlib.dumps(plistlib.loads(self.info.read_bytes()), fmt=plistlib.FMT_BINARY))
            return result
        result = self.observe(rewrite_metadata)
        self.assertEqual(result['outcome'], 'invalid-observation')

    def observe(self, invoke, cases=None, attribute_live=False, repetitions=1):
        return runner.run(self.audio, self.cases if cases is None else cases, self.bundle,
                          self.root / 'run', self.launcher, attribute_live=attribute_live, repetitions=repetitions, invoke=invoke)

    def successful_double(self, arguments, **options):
        self.calls.append((arguments, options))
        env = options['env']
        repetitions = int(env['PORTAVOZ_DICTATION_REPETITIONS'])
        entries = {row['caseID']: row for row in json.loads((self.audio / 'manifest.json').read_text())['entries']}
        _, cells = corpus.read_public_corpus()
        document = {'schemaVersion': 2, 'kind': 'dictation-installed-model-observation',
                    'manifestSHA256': hashlib.sha256((self.audio / 'manifest.json').read_bytes()).hexdigest(),
                    'corpusSHA256': corpus.CORPUS_SHA256, 'qualityMeasured': True,
                    'controllerMeasured': False, 'verifiedDeliveryMeasured': False, 'repetitions': repetitions,
                    'memoryMeasured': False, 'backendWindowFailureCoverageMeasured': False,
                    'modelID': 'parakeet-tdt-0.6b-v3-coreml', 'modelRevision': 'a' * 40,
                    'modelVerificationSeconds': 0.001, 'modelLoadSeconds': 0.001,
                    'loadState': 'new-engine-uncontrolled-coreml-disk-cache',
                    'localeMode': 'automatic-no-vocabulary', 'feed': 'realtime-100ms-bounded-pcm',
                    'cells': [self.cell_double(case, attempt, repetitions, cells[case][0], entries[case])
                              for attempt in (1, 2) for case in self.cases]}
        Path(env['PORTAVOZ_DICTATION_BASELINE_OUTPUT']).write_text(json.dumps(document))
        return subprocess.CompletedProcess(arguments, 0)

    def cell_double(self, case, attempt, repetitions, family, entry):
        # A complete schema double, not fabricated ASR or public-text scoring evidence.
        frames = entry['frames'] * repetitions
        duration = frames / 16_000
        score = {'wordErrorRate': 0, 'characterErrorRate': 0, 'referenceWords': 1, 'hypothesisWords': 1,
                 'exactReferenceMatch': True, 'legacyCleanupChangedText': False}
        return {'caseID': case, 'pass': attempt, 'repetitions': repetitions, 'audioSHA256': entry['audioSHA256'],
                **{key: family[key] for key in ('group', 'cohort', 'shape', 'split', 'critical')},
                'inputSeconds': duration, 'inputEndSeconds': duration + 0.001, 'completionSeconds': duration + 0.02,
                'firstUpdateSeconds': 0.001,
                'score': dict(score), 'adapterDeltas': dict(score),
                'work': {'channel': 'microphone', 'sampleRate': 16_000, 'inputFrames': frames,
                         'inputChunks': (frames + 1_599) // 1_600, 'rejectedBuffers': 0,
                         'backendUpdates': 1, 'backendTokens': 1, 'backendTokenTimings': 1,
                         'confirmedUpdates': 1, 'updatesAfterFinishStarted': 0, 'finishCalls': 1,
                         'loadMilliseconds': 0.001, 'feedMilliseconds': duration * 1_000,
                         'finishMilliseconds': 0.1, 'updateDrainMilliseconds': 0.01, 'cleanupMilliseconds': 0.001,
                         'valid': True, 'outcome': 'completed'}}

    def test_launch_has_fixed_selector_minimal_environment_no_output_capture_and_a_deadline(self):
        with mock.patch.dict(os.environ, {'PRIVATE_SENTINEL': 'do-not-propagate'}):
            result = self.observe(self.successful_double)
        self.assertEqual(result['outcome'], 'observed')
        arguments, options = self.calls[0]
        self.assertEqual(arguments[1:3], ['-XCTest', runner.SELECTOR])
        self.assertNotIn('PRIVATE_SENTINEL', options['env'])
        self.assertNotIn('shell', options)
        for key in ('stdin', 'stdout', 'stderr'):
            self.assertEqual(options[key], subprocess.DEVNULL)
        self.assertTrue(300 < options['timeout'] <= 7_200)
        self.assertFalse(result['verifiedDeliveryMeasured'])
        self.assertFalse(result['sourceCommitQualified'])

    def test_changed_published_request_cannot_retain_an_observed_outcome(self):
        def rewrite_request(arguments, **options):
            result = self.successful_double(arguments, **options)
            path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT']).with_name('request.json')
            request = json.loads(path.read_text())
            request['sourceCommitQualified'] = True
            path.write_text(json.dumps(request))
            return result
        result = self.observe(rewrite_request)
        self.assertEqual(result['outcome'], 'invalid-observation')
        outcome = json.loads((self.root / 'run/outcome.json').read_text())
        self.assertEqual(outcome['outcome'], 'invalid-observation')
        self.assertFalse(outcome['sourceCommitQualified'])

    def test_equal_manifest_values_do_not_preserve_rewritten_byte_identity(self):
        original = (self.audio / 'manifest.json').read_bytes()
        def rewrite_manifest(arguments, **options):
            result = self.successful_double(arguments, **options)
            path = self.audio / 'manifest.json'
            path.write_bytes(original + b'\n ')
            self.assertEqual(json.loads(path.read_bytes()), json.loads(original))
            return result
        result = self.observe(rewrite_manifest)
        self.assertEqual(result['outcome'], 'invalid-observation')

    def test_requested_attribution_cannot_pass_on_a_regular_model_receipt(self):
        result = self.observe(self.successful_double, attribute_live=True)
        self.assertEqual(result['outcome'], 'invalid-observation')
        self.assertEqual(self.calls[0][1]['env']['PORTAVOZ_DICTATION_ATTRIBUTE_LIVE'], '1')

    def test_complete_attribution_is_validated_but_does_not_claim_production_equivalence(self):
        def invoke(arguments, **options):
            result = self.successful_double(arguments, **options)
            path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT'])
            document = json.loads(path.read_text())
            for row in document['cells']:
                row['stageAttribution'] = self.attribution()
            path.write_text(json.dumps(document))
            return result
        result = self.observe(invoke, attribute_live=True)
        self.assertEqual(result['outcome'], 'observed')

    def test_attribution_rejects_inconsistent_counts_and_transcript_bearing_fields(self):
        for key, value in [('rejectedAtBoundary', 2), ('mappedSegmentCount', -1), ('hypothesis', 'private-sentinel')]:
            document = self.attribution()
            document[key] = value
            with self.assertRaises(corpus.CorpusError):
                runner.validate_attribution(document)

    def attribution(self):
        score = {'wordErrorRate': 0, 'characterErrorRate': 0, 'referenceWords': 1, 'hypothesisWords': 1,
                 'exactReferenceMatch': True, 'legacyCleanupChangedText': False}
        return {'vendorFinal': score, 'mappedAndCoalesced': score, 'matchesProductionText': False,
                'updateCount': 1, 'timingCount': 1, 'rejectedAtBoundary': 0,
                'rejectedBeforeBoundary': 0, 'mappedSegmentCount': 1}

    def test_known_audio_duration_cannot_request_a_run_beyond_the_owned_deadline(self):
        entries = {str(index): {'frames': 1_920_000} for index in range(30)}
        self.assertEqual(runner.run_deadline(entries, list(entries)[:20], False), 5_100)
        for selected, attributed in [(list(entries), False), (list(entries)[:20], True)]:
            with self.assertRaises(corpus.CorpusError):
                runner.run_deadline(entries, selected, attributed)

    def test_repeated_request_is_bound_to_child_environment_receipt_and_duration(self):
        result = self.observe(self.successful_double, repetitions=12)
        self.assertEqual(result['outcome'], 'observed')
        arguments, options = self.calls[0]
        self.assertEqual(options['env']['PORTAVOZ_DICTATION_REPETITIONS'], '12')
        request = json.loads((self.root / 'run/request.json').read_text())
        self.assertEqual(request['repetitions'], 12)
        self.assertEqual(request['sequence'], 'repeat-admitted-pcm-and-reference')
        self.assertEqual(result['repetitions'], 12)

    def test_short_receipt_cannot_certify_requested_long_sequence(self):
        def invoke(arguments, **options):
            result = self.successful_double(arguments, **options)
            path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT'])
            document = json.loads(path.read_text())
            document['cells'][0]['inputSeconds'] /= 12
            path.write_text(json.dumps(document))
            return result
        self.assertEqual(self.observe(invoke, repetitions=12)['outcome'], 'invalid-observation')

    def test_native_ignored_repetition_count_fails_even_when_case_and_pass_match(self):
        def invoke(arguments, **options):
            result = self.successful_double(arguments, **options)
            path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT'])
            document = json.loads(path.read_text())
            document['cells'][0]['repetitions'] = 1
            path.write_text(json.dumps(document))
            return result
        self.assertEqual(self.observe(invoke, repetitions=6)['outcome'], 'invalid-observation')

    def test_boolean_count_cannot_impersonate_one_repetition(self):
        def invoke(arguments, **options):
            result = self.successful_double(arguments, **options)
            path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT'])
            document = json.loads(path.read_text())
            document['repetitions'] = True
            path.write_text(json.dumps(document))
            return result
        self.assertEqual(self.observe(invoke)['outcome'], 'invalid-observation')

    def test_actual_cli_rejects_invalid_repetition_before_creating_a_run(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / 'scripts/run_dictation_model_baseline.py'),
             '--audio-root', str(self.audio), '--case', self.cases[0],
             '--test-bundle', str(self.bundle), '--xctest', str(self.launcher),
             '--output', str(self.root / 'run'), '--repetitions', '13'],
            stdin=subprocess.DEVNULL, capture_output=True, timeout=20, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / 'run').exists())
        self.assertNotIn(b'Traceback', result.stderr)

    def test_repeat_bounds_fail_before_launch_or_output_creation(self):
        for repetitions in [0, -1, True, 1.5, '2', 13, 10**100]:
            with self.assertRaises(corpus.CorpusError):
                self.observe(self.successful_double, repetitions=repetitions)
        self.assertFalse(self.calls)
        self.assertFalse((self.root / 'run').exists())
        entries = {'cell': {'frames': 160_000}}
        self.assertEqual(runner.run_deadline(entries, ['cell'], False, 12), 540)
        entries['cell']['frames'] += 1
        with self.assertRaises(corpus.CorpusError):
            runner.run_deadline(entries, ['cell'], False, 12)

    def test_missing_receipt_is_not_green_even_with_zero_exit(self):
        result = self.observe(lambda arguments, **_: subprocess.CompletedProcess(arguments, 0))
        self.assertEqual(result['outcome'], 'invalid-observation')

    def test_quality_flag_cannot_replace_the_actual_measurements(self):
        def invoke(arguments, **options):
            result = self.successful_double(arguments, **options)
            path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT'])
            document = json.loads(path.read_text())
            document['cells'][0].pop('score', None)
            path.write_text(json.dumps(document))
            return result
        self.assertEqual(self.observe(invoke)['outcome'], 'invalid-observation')

    def test_unknown_content_cannot_enter_an_admitted_content_free_receipt(self):
        def invoke(arguments, **options):
            result = self.successful_double(arguments, **options)
            path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT'])
            document = json.loads(path.read_text())
            document['transcript'] = 'must-not-be-admitted'
            path.write_text(json.dumps(document))
            return result
        self.assertEqual(self.observe(invoke)['outcome'], 'invalid-observation')

    def test_corrupt_measurements_and_attribution_fail_at_the_run_boundary(self):
        mutations = [
            (('memoryMeasured',), True),
            (('backendWindowFailureCoverageMeasured',), True),
            (('modelRevision',), 'unbounded private description'),
            (('modelLoadSeconds',), -1),
            (('modelVerificationSeconds',), 10**400),
            (('cells', 0, 'pass'), True),
            (('cells', 1, 'cohort'), 'en'),
            (('cells', 1, 'audioSHA256'), 'a' * 64),
            (('cells', 0, 'critical'), 1),
            (('cells', 0, 'score', 'wordErrorRate'), -1),
            (('cells', 1, 'score', 'characterErrorRate'), float('nan')),
            (('cells', 0, 'score', 'referenceWords'), True),
            (('cells', 0, 'score', 'hypothesis'), 'must-not-be-admitted'),
            (('cells', 0, 'score', 'wordErrorRate'), 0.5),  # Contradicts its exact-match flag.
            (('cells', 1, 'adapterDeltas'), None),
            (('cells', 1, 'adapterDeltas', 'legacyCleanupChangedText'), True),
            (('cells', 0, 'completionSeconds'), 0),
            (('cells', 1, 'inputEndSeconds'), False),
            (('cells', 1, 'firstUpdateSeconds'), None),
            (('cells', 1, 'firstUpdateSeconds'), 7_201),
            (('cells', 0, 'work', 'valid'), False),
            (('cells', 0, 'work', 'outcome'), 'failed'),
            (('cells', 0, 'work', 'inputFrames'), 1),
            (('cells', 1, 'work', 'inputChunks'), 0),
            (('cells', 1, 'work', 'rejectedBuffers'), 1),
            (('cells', 1, 'work', 'finishCalls'), 0),
            (('cells', 1, 'work', 'updatesAfterFinishStarted'), 2),
            (('cells', 0, 'work', 'cleanupMilliseconds'), float('inf')),
            (('cells', 0, 'work', 'error'), 'must-not-be-admitted'),
            (('cells', 0, 'stageAttribution'), None),
        ]
        for index, (keys, value) in enumerate(mutations):
            with self.subTest(path=keys):
                def invoke(arguments, **options):
                    result = self.successful_double(arguments, **options)
                    path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT'])
                    document = json.loads(path.read_text())
                    target = document
                    for key in keys[:-1]:
                        target = target[key]
                    target[keys[-1]] = value
                    path.write_text(json.dumps(document))
                    return result
                output = self.root / f'corrupt-{index}'
                result = runner.run(self.audio, self.cases, self.bundle, output, self.launcher, invoke=invoke)
                self.assertEqual(result['outcome'], 'invalid-observation')
                self.assertNotIn('must-not-be-admitted', (output / 'outcome.json').read_text())

    def test_high_error_rates_remain_observations_not_a_censored_quality_pass(self):
        def invoke(arguments, **options):
            result = self.successful_double(arguments, **options)
            path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT'])
            document = json.loads(path.read_text())
            for row in document['cells']:
                row['score'].update(wordErrorRate=5.5, characterErrorRate=7.0, exactReferenceMatch=False)
            path.write_text(json.dumps(document))
            return result
        self.assertEqual(self.observe(invoke)['outcome'], 'observed')

    def test_missing_first_update_requires_empty_output_but_not_a_good_quality_score(self):
        for empty in (False, True):
            def invoke(arguments, **options):
                result = self.successful_double(arguments, **options)
                path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT'])
                document = json.loads(path.read_text())
                for row in document['cells']:
                    del row['firstUpdateSeconds']
                    if empty:
                        for key in ('score', 'adapterDeltas'):
                            row[key].update(wordErrorRate=1.0, characterErrorRate=1.0,
                                            hypothesisWords=0, exactReferenceMatch=False)
                path.write_text(json.dumps(document))
                return result
            result = runner.run(self.audio, self.cases, self.bundle, self.root / f'empty-{empty}',
                                self.launcher, invoke=invoke)
            self.assertEqual(result['outcome'], 'observed' if empty else 'invalid-observation')

    def test_native_timeout_and_failure_never_become_an_observation(self):
        def timeout(arguments, **options):
            raise subprocess.TimeoutExpired(arguments, options['timeout'], output='private-sentinel')
        result = self.observe(timeout)
        self.assertEqual(result['outcome'], 'timed-out')
        self.assertNotIn('private-sentinel', (self.root / 'run/outcome.json').read_text())

    def test_stale_or_incomplete_receipt_fails_closed(self):
        def invoke(arguments, **options):
            result = self.successful_double(arguments, **options)
            path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT'])
            document = json.loads(path.read_text())
            document['cells'].pop()
            path.write_text(json.dumps(document))
            return result
        self.assertEqual(self.observe(invoke)['outcome'], 'invalid-observation')

    def test_audio_mutation_during_the_child_is_not_accepted(self):
        def invoke(arguments, **options):
            result = self.successful_double(arguments, **options)
            path = self.audio / (self.cases[0] + '.wav')
            path.write_bytes(path.read_bytes()[:-1])
            return result
        self.assertEqual(self.observe(invoke)['outcome'], 'invalid-observation')

    def test_unreviewed_case_cannot_create_output_or_launch(self):
        with self.assertRaises(corpus.CorpusError):
            self.observe(self.successful_double, cases=['../../private'])
        self.assertFalse(self.calls)
        self.assertFalse((self.root / 'run').exists())

    def test_existing_run_is_never_replaced_or_retried(self):
        self.observe(self.successful_double)
        with self.assertRaises(FileExistsError):
            self.observe(self.successful_double)
        self.assertEqual(len(self.calls), 1)


if __name__ == '__main__':
    unittest.main()
