"""Matrix-to-existing-launcher call sites; doubles never establish model quality."""

import json
from pathlib import Path
import subprocess
import sys
import unittest

from Tests.Tooling import test_dictation_controller_runner as controller_fixtures
import dictation_corpus as corpus
import run_dictation_controller_matrix as matrix


class DictationControllerMatrixTests(unittest.TestCase):
    def setUp(self):
        self.controller = controller_fixtures.DictationControllerRunnerTests()
        self.controller.setUp()
        self.addCleanup(self.controller.doCleanups)
        self.fixture = self.controller.fixture
        self.output = self.fixture.root / 'matrix'

    def observe(self, invoke=None, **options):
        return matrix.run(self.fixture.audio, options.pop('cases', self.fixture.cases),
                          self.fixture.bundle, self.output, self.fixture.launcher,
                          invoke=invoke or self.success, **options)

    def success(self, arguments, **options):
        self.fixture.cases = options['env']['PORTAVOZ_DICTATION_BASELINE_CASES'].split(',')
        return self.controller.controller_double(arguments, **options)

    def read(self, name):
        return json.loads((self.output / name).read_text())

    def test_current_swiftbuild_bundle_reaches_each_controller_cohort(self):
        self.fixture.use_swiftbuild_layout()
        result = self.observe(maximum_cells=1)
        self.assertEqual(result['outcome'], 'observed')
        self.assertEqual(result['observedCells'], 2)
        self.assertEqual(len(self.fixture.calls), 2)

    def test_actual_launch_chain_keeps_bilingual_cells_and_two_passes_per_process(self):
        cases = self.fixture.cases.copy()
        result = self.observe(maximum_cells=1)
        self.assertEqual(result['outcome'], 'observed')
        self.assertEqual(result['observedCells'], 2)
        self.assertFalse(result['fullPublicCorpusSelected'])
        self.assertFalse(result['qualityAccepted'])
        self.assertFalse(result['sourceCommitQualified'])
        self.assertFalse(result['verifiedDeliveryMeasured'])
        self.assertEqual(result['processPolicy'], 'fresh-process-per-cohort-two-local-passes')
        self.assertEqual(len(self.fixture.calls), 2)
        rows = []
        for index in range(2):
            observation = self.read(f'cohort-{index:04d}/model.json')
            rows += [(row['caseID'], row['pass']) for row in observation['cells']]
            self.assertEqual(observation['modelLoadAttempts'], 1)
            self.assertEqual(observation['cells'][0]['runtimeState'], 'first-engine-load')
            self.assertLessEqual(self.fixture.calls[index][1]['timeout'], 540)
        self.assertEqual(rows, [(case, attempt) for case in cases for attempt in (1, 2)])
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.output / 'matrix-request.json').stat().st_mode & 0o777, 0o600)

    def test_timeout_preserves_prior_terminal_receipt_and_does_not_retry_or_run_remaining_cohorts(self):
        calls = []
        def invoke(arguments, **options):
            calls.append(options['env']['PORTAVOZ_DICTATION_BASELINE_CASES'])
            if len(calls) == 2:
                raise subprocess.TimeoutExpired('content-free-child', options['timeout'])
            return self.success(arguments, **options)
        cases = [*self.fixture.cases, 'en-payment-negation.soft']
        result = self.observe(invoke, cases=cases, maximum_cells=1)
        self.assertEqual(result['outcome'], 'incomplete')
        self.assertEqual(result['observedCells'], 1)
        self.assertEqual(len(calls), 2)
        self.assertEqual(self.read('cohort-0000/outcome.json')['outcome'], 'observed')
        self.assertEqual(self.read('cohort-0001/outcome.json')['outcome'], 'timed-out')
        self.assertFalse((self.output / 'cohort-0002').exists())
        self.assertEqual(len(self.read('cohort-0000/model.json')['cells']), 2)

    def test_zero_exit_without_a_receipt_cannot_qualify_a_matrix(self):
        result = self.observe(lambda args, **_: subprocess.CompletedProcess(args, 0))
        self.assertEqual(result['outcome'], 'incomplete')
        self.assertEqual(result['observedCells'], 0)
        self.assertEqual(result['cohorts'][0]['outcome'], 'invalid-observation')

    def test_interruption_retains_completed_cohorts_but_publishes_no_complete_matrix(self):
        def invoke(arguments, **options):
            if self.fixture.calls:
                raise KeyboardInterrupt()
            return self.success(arguments, **options)
        with self.assertRaises(KeyboardInterrupt):
            self.observe(invoke, maximum_cells=1)
        self.assertEqual(self.read('cohort-0000/outcome.json')['outcome'], 'observed')
        self.assertTrue((self.output / 'matrix-request.json').is_file())
        self.assertFalse((self.output / 'matrix-outcome.json').exists())

    def test_later_cohort_cannot_rewrite_an_earlier_receipt_or_matrix_plan(self):
        for name in ('cohort-0000/model.json', 'cohort-0000/request.json', 'matrix-request.json'):
            with self.subTest(name=name):
                self.output = self.fixture.root / ('tamper-' + name.replace('/', '-'))
                calls = []
                def invoke(arguments, **options):
                    calls.append(1)
                    result = self.success(arguments, **options)
                    if len(calls) == 2:
                        target = self.output / name
                        document = json.loads(target.read_text())
                        document['untrustedText'] = 'do-not-export'
                        target.write_text(json.dumps(document))
                    return result
                cases = ['en-payment-negation.clean', 'es-payment-negation.clean']
                result = self.observe(invoke, cases=cases, maximum_cells=1)
                self.assertEqual(result['outcome'], 'invalid-observation')
                self.assertEqual(result['observedCells'], 0)
                self.assertNotIn('do-not-export', (self.output / 'matrix-outcome.json').read_text())

    def test_request_change_during_child_invalidates_current_cohort(self):
        def invoke(arguments, **options):
            result = self.success(arguments, **options)
            path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT']).with_name('request.json')
            value = json.loads(path.read_text())
            value['timeoutSeconds'] *= 2
            path.write_text(json.dumps(value))
            return result
        result = self.observe(invoke)
        self.assertEqual(result['outcome'], 'invalid-observation')
        self.assertEqual(result['observedCells'], 0)
        self.assertEqual(self.read('cohort-0000/outcome.json')['outcome'], 'invalid-observation')

    def test_binary_replacement_cannot_mix_builds_across_processes(self):
        def invoke(arguments, **options):
            result = self.success(arguments, **options)
            if len(self.fixture.calls) == 2:
                (self.fixture.bundle / 'Contents/MacOS/PortavozPackageTests').write_bytes(b'changed-build')
            return result
        result = self.observe(invoke, maximum_cells=1)
        self.assertEqual(result['outcome'], 'invalid-observation')
        self.assertEqual(result['observedCells'], 0)

    def test_complete_corpus_reaches_the_launcher_without_missing_or_duplicate_attempts(self):
        result = self.observe(cases=None)
        self.assertEqual(result['outcome'], 'observed')
        self.assertEqual(result['observedCells'], 480)
        self.assertTrue(result['fullPublicCorpusSelected'])
        _, cells = corpus.read_public_corpus()
        requests = [self.read(f"{item['id']}/request.json") for item in result['cohorts']]
        selected = [case for request in requests for case in request['cases']]
        self.assertEqual(selected, sorted(cells))
        observed = [(row['caseID'], row['pass']) for item in result['cohorts']
                    for row in self.read(f"{item['id']}/model.json")['cells']]
        self.assertCountEqual(observed, [(case, attempt) for case in cells for attempt in (1, 2)])
        self.assertEqual(len(self.fixture.calls), result['plannedCohorts'])

    def test_new_invocation_never_replaces_an_existing_matrix(self):
        self.observe()
        before = (self.output / 'matrix-outcome.json').read_bytes()
        with self.assertRaises(FileExistsError):
            self.observe()
        self.assertEqual((self.output / 'matrix-outcome.json').read_bytes(), before)
        self.assertEqual(len(self.fixture.calls), 1)

    def test_model_revision_cannot_change_between_cohorts(self):
        def invoke(arguments, **options):
            result = self.success(arguments, **options)
            if len(self.fixture.calls) == 2:
                path = Path(options['env']['PORTAVOZ_DICTATION_BASELINE_OUTPUT'])
                document = json.loads(path.read_text())
                document['modelRevision'] = 'b' * 40
                path.write_text(json.dumps(document))
            return result
        self.assertEqual(self.observe(invoke, maximum_cells=1)['outcome'], 'invalid-observation')

    def test_empty_duplicate_unknown_and_bad_limits_fail_before_publication_or_child(self):
        for cases in ([], ['not-a-case'], [self.fixture.cases[0]] * 2, ['café — private']):
            with self.assertRaises(corpus.CorpusError):
                self.observe(cases=cases)
        for size in (0, -1, 17, True, 1.5, '2'):
            with self.assertRaises(corpus.CorpusError):
                self.observe(maximum_cells=size)
        self.assertFalse(self.fixture.calls)
        self.assertFalse(self.output.exists())

    def test_exact_audio_boundary_and_whole_corpus_inventory_are_not_truncated(self):
        entries = {'one': {'frames': 1_920_000}, 'two': {'frames': 1}}
        self.assertEqual(matrix.partition(entries, ['one', 'two'], 16), [['one'], ['two']])
        entries['one']['frames'] += 1
        with self.assertRaises(corpus.CorpusError):
            matrix.partition(entries, ['one'], 16)
        _, cells = corpus.read_public_corpus()
        entries = {entry['caseID']: entry for entry in
                   json.loads((self.fixture.audio / 'manifest.json').read_text())['entries']}
        groups = matrix.partition(entries, sorted(cells), 16)
        self.assertEqual([case for group in groups for case in group], sorted(cells))
        self.assertEqual(sum(map(len, groups)), 480)
        self.assertTrue(all(len(group) <= 16 for group in groups))

    def test_cli_bad_size_refuses_before_creating_output(self):
        result = subprocess.run([sys.executable, str(matrix.__file__),
                                 '--audio-root', str(self.fixture.audio), '--all', '--cohort-size', '0',
                                 '--test-bundle', str(self.fixture.bundle), '--xctest', str(self.fixture.launcher),
                                 '--output', str(self.output)], capture_output=True, timeout=20, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.output.exists())
        self.assertNotIn(b'Traceback', result.stderr)


if __name__ == '__main__':
    unittest.main()
