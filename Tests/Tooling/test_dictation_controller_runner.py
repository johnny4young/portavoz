"""Actual launch/admission boundary; injected observations are not ASR evidence."""

import json
from pathlib import Path
import subprocess
import unittest

from Tests.Tooling import test_dictation_model_runner as model_fixtures
import run_dictation_model_baseline as runner
import dictation_corpus as corpus


class DictationControllerRunnerTests(unittest.TestCase):
    def setUp(self):
        # Reuse its owned synthetic corpus, not its tests or a second data builder.
        self.fixture = model_fixtures.DictationModelRunnerTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def run_observation(self, invoke, **options):
        f = self.fixture
        return runner.run(f.audio, f.cases, f.bundle, f.root / 'run', f.launcher,
                          controller=True, invoke=invoke, **options)

    def controller_double(self, arguments, **options):
        result = self.fixture.successful_double(arguments, **options)
        path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT'])
        document = json.loads(path.read_text())
        document.update(kind='dictation-controller-model-observation', schemaVersion=1,
                        controllerMeasured=True, memoryMeasured=True, platformChecksMeasured=False,
                        evaluationTarget='proposed-output-including-cancelled-and-failed-attempts',
                        memoryScope='sampled-whole-xctest-process-not-allocation-attribution',
                        modelLoadAttempts=1, loadState='lazy-shared-engine-uncontrolled-coreml-disk-cache',
                        localeMode='automatic-literal-no-vocabulary', feed='realtime-100ms-public-pcm-controller-stop')
        for index, row in enumerate(document['cells']):
            for key in ('completionSeconds', 'inputEndSeconds', 'firstUpdateSeconds', 'adapterDeltas'):
                row.pop(key)
            row['proposedOutputScore'] = row.pop('score')
            row['runtimeState'] = 'reused-engine' if index else 'first-engine-load'
            row['work'] = [row['work']]
            row.update(inputCompleted=True, fedFrames=row['work'][0]['inputFrames'], pipelineCompleted=True)
            end = row['inputSeconds'] + 0.01
            row['controller'] = {'schemaVersion': 1, 'outcome': 'deliveryRejected',
                                 'verifiedDeliveryMeasured': False, 'terminalSeconds': end + 0.1,
                                 'elapsedSeconds': {'runtimeReady': 0.002, 'microphoneReady': 0.003,
                                                    'firstBufferHandled': 0.01, 'firstCaptionHandled': 0.02,
                                                    'stopRequested': end, 'inputEnded': end + 0.02,
                                                    'transcriptionEnded': end + 0.03, 'textPrepared': end + 0.04,
                                                    'deliveryStarted': end + 0.05, 'deliveryReturned': end + 0.06}}
            row['footprint'] = {'baselineBytes': 100, 'endingBytes': 110, 'peakObservedBytes': 120,
                                'sampleCount': 3, 'cadenceMilliseconds': 100,
                                'initialThermalState': 'nominal', 'finalThermalState': 'fair'}
        path.write_text(json.dumps(document))
        return result

    def mutated(self, mutation):
        def invoke(arguments, **options):
            result = self.controller_double(arguments, **options)
            path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT'])
            document = json.loads(path.read_text())
            mutation(document)
            path.write_text(json.dumps(document))
            return result
        return invoke

    def reset_run(self):
        # Remove only this test's exact output, never the input corpus or a prior run.
        import shutil
        shutil.rmtree(self.fixture.root / 'run')

    def test_controller_has_distinct_selector_scope_and_no_native_delivery_claim(self):
        result = self.run_observation(self.controller_double)
        self.assertEqual(result['outcome'], 'observed')
        self.assertEqual(result['schemaVersion'], 3)
        self.assertFalse(result['verifiedDeliveryMeasured'])
        args, options = self.fixture.calls[0]
        self.assertEqual(args[2], runner.CONTROLLER_SELECTOR)
        self.assertEqual(options['env']['PORTAVOZ_DICTATION_CONTROLLER'], '1')
        self.assertIs(options['stdout'], subprocess.DEVNULL)
        self.assertIs(options['stderr'], subprocess.DEVNULL)
        request = json.loads((self.fixture.root / 'run/request.json').read_text())
        self.assertTrue(request['controller'])
        self.assertFalse(request['sourceCommitQualified'])

    def test_model_only_receipt_cannot_qualify_controller(self):
        result = self.run_observation(self.fixture.successful_double)
        self.assertEqual(result['outcome'], 'invalid-observation')

    def test_bad_shapes_private_fields_and_forged_metrics_are_rejected_at_launch_boundary(self):
        mutations = [
            lambda d: d.update(verifiedDeliveryMeasured=True),
            lambda d: d.update(platformChecksMeasured=True),
            lambda d: d.update(modelLoadAttempts=0),
            lambda d: d['cells'].pop(),
            lambda d: d['cells'][0].update(proposedText='never store this'),
            lambda d: d['cells'][0].update(controller=None),
            lambda d: d['cells'][0].update(work=None),
            lambda d: d['cells'][0].update(pipelineCompleted=1),
            lambda d: d['cells'][0].update(fedFrames=True),
            lambda d: d['cells'][0]['controller'].update(outcome='dispatchReported'),
            lambda d: d['cells'][0]['controller'].update(elapsedSeconds={}),
            lambda d: d['cells'][0]['controller']['elapsedSeconds'].update(runtimeReady=float('nan')),
            lambda d: d['cells'][0]['footprint'].update(peakObservedBytes=1),
            lambda d: d['cells'][0]['footprint'].update(sampleCount=True),
            lambda d: d['cells'][0]['work'][0].update(inputFrames=1),
            lambda d: d['cells'][1].update(runtimeState='first-engine-load'),
        ]
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                result = self.run_observation(self.mutated(mutation))
                self.assertEqual(result['outcome'], 'invalid-observation')
            self.reset_run()

    def test_valid_cancelled_short_attempt_is_kept_not_disguised_as_completed(self):
        def cancel(document):
            row = document['cells'][0]
            row['pipelineCompleted'] = False
            row['controller'].update(outcome='cancelled', elapsedSeconds={
                'runtimeReady': 0.002, 'microphoneReady': 0.003,
                'firstBufferHandled': 0.01, 'stopRequested': 0.04})
            row['proposedOutputScore'].update(wordErrorRate=1, characterErrorRate=1,
                                              hypothesisWords=0, exactReferenceMatch=False)
            row['work'][0].update(outcome='cancelled')
        result = self.run_observation(self.mutated(cancel))
        self.assertEqual(result['outcome'], 'observed')
        rows = json.loads((self.fixture.root / 'run/model.json').read_text())['cells']
        self.assertEqual(len(rows), 4)
        self.assertFalse(rows[0]['pipelineCompleted'])
        self.assertEqual(rows[0]['proposedOutputScore']['wordErrorRate'], 1)

    def test_missing_input_can_be_observed_but_never_marked_complete(self):
        def fail_input(document):
            row = document['cells'][0]
            row.update(inputCompleted=False, fedFrames=0, work=[], pipelineCompleted=False)
        self.assertEqual(self.run_observation(self.mutated(fail_input))['outcome'], 'observed')
        self.reset_run()
        def forged(document):
            fail_input(document)
            document['cells'][0]['pipelineCompleted'] = True
        self.assertEqual(self.run_observation(self.mutated(forged))['outcome'], 'invalid-observation')

    def test_preparation_failure_does_not_hide_next_load_attempt(self):
        def failure(document):
            row = document['cells'][0]
            row.update(inputCompleted=False, fedFrames=0, pipelineCompleted=False, work=[])
            row['controller'].update(outcome='pipelineFailed', elapsedSeconds={})
            row['proposedOutputScore'].update(wordErrorRate=1, characterErrorRate=1,
                                              hypothesisWords=0, exactReferenceMatch=False)
            document['cells'][1]['runtimeState'] = 'first-engine-load'
            document['modelLoadAttempts'] = 2
        self.assertEqual(self.run_observation(self.mutated(failure))['outcome'], 'observed')

    def test_controller_and_vendor_attribution_refuse_before_launch_or_output(self):
        with self.assertRaises(corpus.CorpusError):
            self.run_observation(self.controller_double, attribute_live=True)
        self.assertFalse(self.fixture.calls)
        self.assertFalse((self.fixture.root / 'run').exists())

    def test_replaced_binary_cannot_keep_the_prelaunch_identity(self):
        def replace_binary(arguments, **options):
            result = self.controller_double(arguments, **options)
            executable = self.fixture.bundle / 'Contents/MacOS/PortavozPackageTests'
            executable.write_bytes(b'a different build finished while the test was running')
            return result
        self.assertEqual(self.run_observation(replace_binary)['outcome'], 'invalid-observation')

    def test_impossible_partial_event_order_is_rejected_at_launch_boundary(self):
        for point in ('firstBufferHandled', 'firstCaptionHandled'):
            def reverse(document):
                document['cells'][0]['controller']['elapsedSeconds'][point] = 0
            with self.subTest(point=point):
                self.assertEqual(self.run_observation(self.mutated(reverse))['outcome'], 'invalid-observation')
            self.reset_run()

    def test_timed_out_controller_process_is_not_observed(self):
        def timeout(*args, **kwargs):
            raise subprocess.TimeoutExpired('owned-controller-observer', kwargs['timeout'])
        self.assertEqual(self.run_observation(timeout)['outcome'], 'timed-out')


if __name__ == '__main__':
    unittest.main()
