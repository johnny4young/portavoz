"""Offline count/receipt doubles test the benchmark harness, never ASR quality."""

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import dictation_benchmark as benchmark
import dictation_corpus as corpus
from materialize_dictation_corpus import fingerprint

FIXTURE = ROOT / 'Tests/Tooling/Fixtures/DictationBenchmark/synthetic-input-v1.json'


class DictationBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.document, self.digest = corpus.read_json(FIXTURE)

    def report(self):
        return benchmark.summarize(self.document, self.digest)

    def rebind(self):
        self.document['plan']['configurationDigest'] = fingerprint(self.document['configuration'])
        self.document['plan']['datasetDigest'] = fingerprint(self.document['dataset'])
        for attempt in self.document['attempts']:
            attempt['planDigest'] = fingerprint(self.document['plan'])

    def metric(self, report, metric, temperature='warm'):
        return next(row for row in report['latency'] if row['metric'] == metric
                    and row['temperature'] == temperature)

    def test_golden_keeps_missing_cancelled_and_unverified_attempts(self):
        result = self.report()
        self.assertEqual(result, json.loads((FIXTURE.parent / 'synthetic-report-v1.json').read_text()))
        self.assertEqual(result['counts']['planned'], 5)
        self.assertEqual(result['counts']['missing'], 1)
        self.assertEqual(result['counts']['terminal']['cancelled'], 1)
        self.assertEqual(result['delivery']['eligiblePlanned'], 4)
        self.assertEqual(result['delivery']['verifiedFractionOfAllPlanned'], .25)
        self.assertEqual(result['delivery']['outcomes']['dispatched-unverified'], 1)
        self.assertEqual(result['gate'], 'inconclusive')
        for key in ('populationQualified', 'consentVerified', 'audioBytesVerified'):
            self.assertFalse(result[key])

    def test_cancelled_speech_retains_full_deletions_and_word_weighting(self):
        row = next(row for row in self.report()['precision'] if row['stratum'] == 'quiet-en')
        stage = row['stages']['postRule']
        self.assertEqual(stage['plannedSpeechAttempts'], 2)
        self.assertEqual(stage['word']['edits'], 3)
        self.assertEqual(stage['word']['plannedReferenceCount'], 6)
        self.assertEqual(stage['word']['completeErrorRate'], .5)
        self.assertEqual(stage['observedSpeakerMacroWER'], .5)

    def test_absent_attempt_and_stage_do_not_become_zero_error(self):
        mixed = next(row for row in self.report()['precision'] if row['stratum'] == 'quiet-mixed')
        self.assertIsNone(mixed['stages']['raw']['word']['completeErrorRate'])
        self.assertEqual(mixed['stages']['raw']['missingScores'], 1)
        self.document['attempts'][1]['scores']['raw'] = None
        english = next(row for row in self.report()['precision'] if row['stratum'] == 'quiet-en')
        self.assertIsNone(english['stages']['raw']['word']['completeErrorRate'])
        self.assertEqual(english['stages']['raw']['word']['observedErrorRate'], 1)
        self.assertEqual(english['stages']['raw']['word']['plannedReferenceCount'], 6)

    def test_no_speech_uses_incidence_and_actual_exposure_not_wer(self):
        result = self.report()
        self.assertEqual(result['nonSpeech']['completeIncidence'], 1)
        self.assertEqual(result['nonSpeech']['lexicalWordsPerMinute'], 120)
        silence = next(row for row in result['precision'] if row['stratum'] == 'no-speech')
        self.assertIsNone(silence['stages']['raw']['word']['observedErrorRate'])
        self.document['attempts'][2].update(fedFrames=0, status='failed', failureReason='capture')
        self.assertIsNone(self.report()['nonSpeech']['lexicalWordsPerMinute'])

    def test_nearest_rank_latency_is_success_conditional_and_ms(self):
        result = self.report()
        prepared = self.metric(result, 'stop-to-prepared')
        self.assertEqual((prepared['p50'], prepared['p95']), (200, 300))
        self.assertEqual(prepared['eligiblePlanned'], 4)
        self.assertEqual(prepared['missingOrUnsuccessful'], 2)
        observed = self.metric(result, 'stop-to-observed-edit')
        self.assertEqual(observed['p95'], 400)
        self.assertEqual(observed['measuredCompleted'], 1)
        cold = self.metric(result, 'request-to-ready', 'process-cold')
        self.assertEqual(cold['p50'], 1000)
        self.assertEqual(benchmark.quantiles([]), {'p50': None, 'p95': None})
        self.assertEqual(benchmark.quantiles([1, 2, 3, 4])['p50'], 2)

    def test_completed_capture_cannot_silently_drop_planned_frames(self):
        self.document['attempts'][0]['fedFrames'] = 0
        with self.assertRaises(corpus.CorpusError):
            self.report()

    def test_non_speech_is_not_counted_as_a_speaker(self):
        self.assertEqual(self.report()['counts']['plannedSpeakerClusters'], 3)

    def test_missing_receiver_proof_never_becomes_zero_latency(self):
        attempt = self.document['attempts'][0]
        attempt['receiverProof'] = None
        attempt['phases']['receiver'] = None
        attempt['deliveryOutcome'] = 'dispatched-unverified'
        metric = self.metric(self.report(), 'stop-to-observed-edit')
        self.assertIsNone(metric['p50'])
        self.assertEqual(metric['measuredCompleted'], 0)

    def test_empty_receipt_set_is_not_run_not_green(self):
        self.document['attempts'] = []
        result = self.report()
        self.assertEqual(result['gate'], 'not-run')
        self.assertEqual(result['counts']['missing'], 5)
        self.assertTrue(all(row['p95'] is None for row in result['latency']))

    def test_high_insertion_rate_above_one_remains_visible(self):
        score = self.document['attempts'][0]['scores']['raw']
        score.update(wordSubstitutions=2, wordInsertions=10, hypothesisWords=12,
                     characterSubstitutions=5, characterInsertions=20, hypothesisCharacters=25)
        row = next(row for row in self.report()['precision'] if row['stratum'] == 'quiet-es')
        self.assertEqual(row['stages']['raw']['word']['completeErrorRate'], 6)

    def test_metadata_is_assertion_not_verified_consent(self):
        self.document['evidenceClass'] = 'declared-observation'
        self.document['dataset'].update(provenance='consented-adult-declared', consentPolicyID='review-record')
        self.rebind()
        result = self.report()
        self.assertFalse(result['consentVerified'])
        self.assertFalse(result['populationQualified'])
        self.assertEqual(result['gate'], 'inconclusive')
        self.document['dataset']['consentPolicyID'] = None
        self.rebind()
        with self.assertRaises(corpus.CorpusError):
            self.report()

    def test_split_leakage_rejected_for_speaker_family_session_audio_and_reference(self):
        for key in ('speakerClusterID', 'familyID', 'sessionID', 'audioDigest', 'referenceDigest'):
            with self.subTest(key=key):
                original = copy.deepcopy(self.document)
                first, second = self.document['dataset']['cases'][:2]
                second['split'] = 'development'
                second[key] = first[key]
                self.rebind()
                with self.assertRaises(corpus.CorpusError):
                    self.report()
                self.document = original

    def test_safety_counterexamples_are_retained_as_failures(self):
        mutations = {
            'wrongTarget': lambda a: a['receiverProof'].update(targetID='other-target'),
            'wrongSelection': lambda a: a['receiverProof'].update(selectionID='other-selection'),
            'duplicateInsertion': lambda a: a['receiverProof'].update(insertionCount=2),
            'dispatchAfterCancel': lambda a: a['phases'].update(cancel=1250),
        }
        for counterexample, mutate in mutations.items():
            with self.subTest(counterexample=counterexample):
                original = copy.deepcopy(self.document)
                attempt = self.document['attempts'][0]
                attempt.update(status='failed', failureReason='safety', deliveryOutcome='failed')
                mutate(attempt)
                result = self.report()
                self.assertEqual(result['gate'], 'fail')
                self.assertEqual(result['safetyCounterexamples'][counterexample], 1)
                self.document = original

    def test_conflicting_terminal_reason_cannot_relabel_timeout_as_cancellation(self):
        for status, reason in (('cancelled', 'timeout'), ('timed-out', 'user-cancelled'),
                               ('refused', 'timeout'), ('failed', 'user-cancelled')):
            with self.subTest(status=status, reason=reason):
                original = copy.deepcopy(self.document)
                self.document['attempts'][3].update(status=status, failureReason=reason)
                with self.assertRaises(corpus.CorpusError):
                    self.report()
                self.document = original

    def test_failed_receiver_text_mismatch_is_visible(self):
        attempt = self.document['attempts'][0]
        attempt.update(status='failed', failureReason='delivery', deliveryOutcome='failed')
        attempt['receiverProof']['textDigest'] = 'f' * 64
        result = self.report()
        self.assertEqual(result['safetyCounterexamples'].get('wrongText'), 1)
        self.assertEqual(result['gate'], 'fail')

    def test_no_speech_insertion_is_a_retained_safety_counterexample(self):
        attempt = self.document['attempts'][2]
        attempt.update(status='failed', failureReason='safety', deliveryOutcome='failed')
        attempt['phases'].update(dispatch=1350, receiver=1450)
        attempt['receiverProof'] = dict(generationID=self.document['plan']['generationID'],
                                       attemptID=attempt['attemptID'], targetID='scratch-target',
                                       selectionID='scratch-selection', textDigest=attempt['preparedTextDigest'],
                                       insertionCount=1, acknowledgementMs=1450)
        result = self.report()
        self.assertEqual(result['safetyCounterexamples']['nonSpeechInsertion'], 1)
        self.assertEqual(result['gate'], 'fail')

    def test_plan_is_hashed_once_during_attempt_admission(self):
        plan, receipt = copy.deepcopy(self.document['plan']['attempts'][0]), copy.deepcopy(self.document['attempts'][0])
        self.document['plan']['attempts'] = []
        self.document['attempts'] = []
        for index in range(100):
            item, attempt = copy.deepcopy(plan), copy.deepcopy(receipt)
            item.update(attemptID=f'repeated-{index}', conditionID=f'condition-{index}')
            attempt['attemptID'] = item['attemptID']
            attempt['receiverProof']['attemptID'] = item['attemptID']
            self.document['plan']['attempts'].append(item)
            self.document['attempts'].append(attempt)
        self.rebind()
        with mock.patch.object(benchmark, 'fingerprint', wraps=fingerprint) as hashed:
            result = self.report()
        self.assertEqual(result['counts']['observed'], 100)
        self.assertLessEqual(hashed.call_count, 10)
        self.assertFalse(result['populationQualified'])

    def test_dispatch_then_cancel_retains_actual_receiver_evidence(self):
        attempt = self.document['attempts'][0]
        attempt.update(status='cancelled', failureReason='user-cancelled')
        attempt['phases']['cancel'] = 1500
        result = self.report()
        self.assertEqual(result['delivery']['outcomes']['verified'], 1)
        self.assertEqual(result['safetyCounterexamples']['dispatchAfterCancel'], 0)
        self.assertEqual(self.metric(result, 'stop-to-observed-edit')['measuredCompleted'], 0)

    def test_rejects_malformed_forged_and_unbound_inputs(self):
        mutations = [
            lambda d: d.update(schemaVersion=True),
            lambda d: d.update(transcript='private-sentinel'),
            lambda d: d['configuration'].update(clockUnit='seconds'),
            lambda d: d['configuration'].update(normalizerDigest='unknown'),
            lambda d: d['dataset']['cases'].append(d['dataset']['cases'][0]),
            lambda d: d['plan']['attempts'].append(d['plan']['attempts'][0]),
            lambda d: d['attempts'].append(d['attempts'][0]),
            lambda d: d['attempts'][0].update(planDigest='f'*64),
            lambda d: d['attempts'][0].update(attemptID='unplanned'),
            lambda d: d['attempts'][0].update(receiverProof=None),
            lambda d: d['attempts'][0]['receiverProof'].update(textDigest='f'*64),
            lambda d: d['attempts'][0]['receiverProof'].update(generationID='another-generation'),
            lambda d: d['attempts'][0]['receiverProof'].update(targetID='another-target'),
            lambda d: d['attempts'][0]['receiverProof'].update(selectionID='another-selection'),
            lambda d: d['attempts'][0]['receiverProof'].update(insertionCount=2),
            lambda d: d['attempts'][0]['phases'].update(stop=1401),
            lambda d: d['attempts'][0]['phases'].update(stop=None),
            lambda d: d['attempts'][0]['phases'].update(receiver=float('nan')),
            lambda d: d['attempts'][0]['phases'].update(prepared=True),
            lambda d: d['attempts'][0].update(fedFrames=16001),
            lambda d: d['attempts'][0]['scores']['raw'].update(wordSubstitutions=3),
            lambda d: d['attempts'][0]['scores']['raw'].update(wordInsertions=-1),
            lambda d: d['attempts'][0]['scores']['raw'].update(wordSubstitutions=.5),
            lambda d: d['attempts'][0]['scores']['raw'].update(hypothesisWords=0),
            lambda d: d['attempts'][0]['scores']['raw'].update(characterSubstitutions=True),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutations.index(mutation)):
                original = copy.deepcopy(self.document)
                mutation(self.document)
                with self.assertRaises(corpus.CorpusError):
                    self.report()
                self.document = original

    def test_cli_is_reproducible_private_and_never_overwrites(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'report.json'
            command = [sys.executable, str(ROOT / 'scripts/dictation_benchmark.py'),
                       '--input', str(FIXTURE), '--output', str(output)]
            result = subprocess.run(command, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(output.read_text()), self.report())
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            before = output.read_bytes()
            self.assertEqual(subprocess.run(command, capture_output=True, timeout=10).returncode, 2)
            self.assertEqual(output.read_bytes(), before)

    def test_cli_rejects_duplicate_json_keys_and_hides_private_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / 'input.json', Path(directory) / 'output.json'
            source.write_text('{"kind":"private-sentinel","kind":"duplicate"}')
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/dictation_benchmark.py'),
                                     '--input', str(source), '--output', str(output)], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn(b'private-sentinel', result.stderr)
            self.assertFalse(output.exists())

    def test_changed_input_cannot_publish_a_report(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'report.json'
            with mock.patch.object(corpus, 'read_json', side_effect=[(self.document, self.digest),
                                                                   (self.document, 'f'*64)]):
                self.assertEqual(benchmark.main(['--input', str(FIXTURE), '--output', str(output)]), 2)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
