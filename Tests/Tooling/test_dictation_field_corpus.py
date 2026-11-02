"""Field-recording admission and the T38 comparison rule, with generated audio only."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import dictation_corpus as corpus
import dictation_field_corpus as field
import run_dictation_model_comparison as comparison

DOCUMENT, _ = corpus.read_public_corpus()
SPEECH = sorted(field.field_cells(DOCUMENT))


def write_wav(path, frames=1_600, value=0):
    with wave.open(str(path), 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16_000)
        audio.writeframes(int(value).to_bytes(2, 'little', signed=True) * frames)


class FieldCorpusTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for index, case in enumerate(SPEECH):
            write_wav(self.root / f'{case}.wav', value=index)

    def test_every_speech_family_is_recorded_once_and_non_speech_never(self):
        self.assertEqual(len(SPEECH), 56)
        self.assertFalse(any(case.startswith('non-speech') for case in SPEECH))
        manifest, missing = field.build(self.root, 'built-in', DOCUMENT)
        self.assertEqual(missing, [])
        self.assertEqual(field.validate(manifest, self.root, DOCUMENT),
                         {'fieldCellCount': 56, 'microphone': 'built-in'})

    def test_missing_recordings_are_named_instead_of_admitted(self):
        (self.root / 'en-accent.field.wav').unlink()
        manifest, missing = field.build(self.root, 'external', DOCUMENT)
        self.assertEqual(missing, ['en-accent'])
        with self.assertRaises(corpus.CorpusError):
            field.validate(manifest, self.root, DOCUMENT)

    def test_mutated_audio_and_foreign_provenance_are_rejected(self):
        manifest, _ = field.build(self.root, 'built-in', DOCUMENT)
        for change in ({'microphone': 'studio'}, {'kind': 'dictation-audio-manifest'},
                       {'corpusSHA256': '0' * 64}, {'recipeSHA256': 'a' * 64}):
            with self.subTest(change=change), self.assertRaises(corpus.CorpusError):
                field.validate({**manifest, **change}, self.root, DOCUMENT)
        with self.assertRaises(corpus.CorpusError):
            field.build(self.root, 'studio', DOCUMENT)
        write_wav(self.root / 'en-accent.field.wav', frames=1_601)
        with self.assertRaises(corpus.CorpusError):
            field.validate(manifest, self.root, DOCUMENT)

    def test_cli_publishes_an_owner_only_manifest_and_refuses_gaps(self):
        script = ROOT / 'scripts' / 'dictation_field_corpus.py'
        (self.root / 'es-accent.field.wav').unlink()
        gap = subprocess.run([sys.executable, str(script), 'build', '--audio-root', str(self.root)],
                             capture_output=True, text=True, check=False)
        self.assertEqual(gap.returncode, 2)
        self.assertEqual(json.loads(gap.stderr), {'missing': ['es-accent']})
        self.assertFalse((self.root / 'manifest.json').exists())
        write_wav(self.root / 'es-accent.field.wav', value=99)
        built = subprocess.run([sys.executable, str(script), 'build', '--audio-root', str(self.root)],
                               capture_output=True, text=True, check=False)
        self.assertEqual(built.returncode, 0, built.stderr)
        self.assertEqual(os.stat(self.root / 'manifest.json').st_mode & 0o777, 0o600)

    @unittest.skipUnless(shutil.which('xcrun'), 'needs the Swift toolchain')
    def test_recorder_writes_the_admitted_profile_and_format(self):
        recorder = ROOT / 'scripts' / 'record-dictation-field-corpus.swift'
        source = recorder.read_text(encoding='utf-8')
        self.assertIn(f'.{field.PROFILE}.wav', source)
        self.assertIn('AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1', source)
        self.assertIn('AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false', source)
        checked = subprocess.run(['xcrun', 'swiftc', '-typecheck', str(recorder)],
                                 capture_output=True, text=True, check=False)
        self.assertEqual(checked.returncode, 0, checked.stderr)


def receipt(model, cases, rate=0.0, critical_errors=(), peak=600, load=1.0, failed=(), clean_critical=False):
    cells = []
    for case in cases:
        family = DOCUMENT['families'][[f['id'] for f in DOCUMENT['families']].index(case.rsplit('.', 1)[0])]
        words = len(family['acceptedTexts'][0].split())
        wer = 0.5 if case in critical_errors else (0.0 if clean_critical and family['critical'] else rate)
        score = None if case in failed else {
            'wordErrorRate': wer, 'characterErrorRate': wer, 'referenceWords': words,
            'hypothesisWords': words, 'exactReferenceMatch': wer == 0, 'legacyCleanupChangedText': False}
        cells.append({'model': comparison.MODELS[model], 'caseID': case, 'group': family['group'],
                      'shape': family['shape'], 'critical': family['critical'], 'score': score})
    return {'kind': 'dictation-model-comparison-observation', 'schemaVersion': 2, 'corpus': 'field-microphone',
            'corpusSHA256': corpus.CORPUS_SHA256, 'manifestSHA256': 'b' * 64,
            'models': [{'model': comparison.MODELS[model], 'revision': 'r', 'loadSeconds': load,
                        'footprintBeforeLoadBytes': 100,
                        'footprintAfterLoadBytes': 100 + peak * 1_048_576 // 2,
                        'footprintAfterCellsBytes': 0, 'peakFootprintBytes': peak * 1_048_576}],
            'cells': cells}


class ComparisonRuleTests(unittest.TestCase):
    def evaluate(self, v3, ultra, kind='field-microphone'):
        return comparison.report(kind, {'v3': v3, 'ultra': ultra}, {'v3': v3, 'ultra': ultra}, DOCUMENT)

    def test_ultra_becomes_the_dictation_default_only_when_every_criterion_holds(self):
        result = self.evaluate(receipt('v3', SPEECH, rate=0.2), receipt('ultra', SPEECH, rate=0.1))
        self.assertEqual(result['decision'], {'verdict': 'default-for-dictation', 'failedCriteria': []})
        self.assertEqual((result['ultraBetterCells'], result['ultraWorseCells']), (56, 0))

    def test_each_criterion_alone_keeps_ultra_opt_in(self):
        critical = [case for case in SPEECH if field.field_cells(DOCUMENT)[case]['critical']][:1]
        cases = {
            'en relative WER reduction below 15%': {'rate': 0.2, 'ultra_rate': 0.18},
            'more critical cells with errors than v3': {'ultra_critical': critical},
            'peak footprint exceeds v3 by more than 150 MiB': {'ultra_peak': 751},
            'warm load exceeds v3 by more than 1 s': {'ultra_load': 2.01},
        }
        for criterion, options in cases.items():
            with self.subTest(criterion=criterion):
                v3 = receipt('v3', SPEECH, rate=options.get('rate', 0.2), clean_critical=True)
                ultra = receipt('ultra', SPEECH, rate=options.get('ultra_rate', 0.0),
                                critical_errors=options.get('ultra_critical', ()),
                                peak=options.get('ultra_peak', 600), load=options.get('ultra_load', 1.0))
                decision = self.evaluate(v3, ultra)['decision']
                self.assertEqual(decision['verdict'], 'stay-opt-in')
                self.assertIn(criterion, decision['failedCriteria'])

    def test_synthetic_evidence_never_promotes_ultra(self):
        result = self.evaluate(receipt('v3', SPEECH, rate=0.3), receipt('ultra', SPEECH), kind='public-synthetic')
        self.assertEqual(result['decision']['verdict'], 'not-applicable')

    def test_a_failed_cell_counts_every_reference_word_as_an_error(self):
        case = 'en-short-chat.field'
        result = self.evaluate(receipt('v3', [case]), receipt('ultra', [case], failed=[case]))
        self.assertEqual(result['models']['ultra']['wordErrorRate'], 1.0)
        self.assertEqual(result['models']['ultra']['failedCells'], 1)
        self.assertEqual(result['ultraWorseCells'], 1)


class ComparisonRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.audio = self.root / 'audio'
        self.audio.mkdir()
        for case in SPEECH:
            write_wav(self.audio / f'{case}.wav', value=SPEECH.index(case))
        manifest, _ = field.build(self.audio, 'built-in', DOCUMENT)
        (self.audio / 'manifest.json').write_text(json.dumps(manifest))
        (self.root / 'models').mkdir()
        (self.root / 'tests.xctest').mkdir()
        (self.root / 'xctest').touch()
        self.calls, self.cases = [], []

    def invoke(self, rates):
        def fake(arguments, env, **_):
            model = env['PORTAVOZ_ASR_COMPARE_MODEL']
            self.calls.append((model, env['PORTAVOZ_ASR_COMPARE_OUTPUT']))
            cases = env['PORTAVOZ_ASR_COMPARE_CASES'].split(',')
            self.cases.append(cases)
            Path(env['PORTAVOZ_ASR_COMPARE_OUTPUT']).write_text(json.dumps(receipt(model, cases, rate=rates[model])))
            return subprocess.CompletedProcess(arguments, 0)
        return fake

    def run_comparison(self, rates, cases=None):
        return comparison.run(self.audio, self.root / 'models', self.root / 'tests.xctest', self.root / 'xctest',
                              self.root / 'out', cases, invoke=self.invoke(rates))

    def test_each_model_warms_up_then_runs_in_its_own_process(self):
        result = self.run_comparison({'v3': 0.2, 'ultra': 0.1})
        self.assertEqual([model for model, _ in self.calls], ['v3', 'v3', 'ultra', 'ultra'])
        self.assertEqual(len({path for _, path in self.calls}), 4)
        self.assertEqual([len(cases) for cases in self.cases], [1, 56, 1, 56])
        self.assertEqual(result['decision']['verdict'], 'default-for-dictation')
        published = json.loads((self.root / 'out' / 'report.json').read_text())
        self.assertEqual(published['cellCount'], 56)

    def test_unknown_cells_and_existing_output_are_refused(self):
        with self.assertRaises(corpus.CorpusError):
            self.run_comparison({'v3': 0, 'ultra': 0}, cases=['en-accent.clean'])
        (self.root / 'out').mkdir()
        with self.assertRaises(FileExistsError):
            self.run_comparison({'v3': 0, 'ultra': 0})


if __name__ == '__main__':
    unittest.main()
