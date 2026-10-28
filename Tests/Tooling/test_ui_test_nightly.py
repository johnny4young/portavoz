"""Synthetic proof that a successful nightly is not necessarily verified."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
SHA = 'a' * 40
OTHER = 'b' * 40


class NightlyFreshnessRegressionTests(unittest.TestCase):
    def test_success_without_verification_does_not_skip(self):
        # Execute the workflow's actual freshness shell with a green advisory run.
        import textwrap
        workflow = (ROOT / '.github/workflows/ui-nightly.yml').read_text()
        step = workflow.split('        run: |\n', 1)[1].split('\n  build-ui-products:', 1)[0]
        shell = textwrap.dedent(step)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gh = root / 'gh'
            gh.write_text('#!/bin/sh\nprintf "%s\\n" "$GITHUB_SHA"\n')
            gh.chmod(0o700)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       EVENT_NAME='schedule', GITHUB_SHA=SHA,
                       GITHUB_REPOSITORY='owner/repo', GITHUB_OUTPUT=str(root / 'output'),
                       GH_TOKEN='synthetic-token')
            # The new resolver's read-only authority is replaced below; no network.
            stub = root / 'sitecustomize.py'
            stub.write_text('import sys\nsys.path.insert(0, ' + repr(str(ROOT / 'scripts')) + ')\n'
                            'import ui_test_verified_base as m\n'
                            'm.GitHubRESTClient.get = lambda *a, **k: {"workflow_runs": []}\n')
            env['PYTHONPATH'] = str(root)
            run = subprocess.run(['bash', '-euo', 'pipefail', '-c', shell],
                                 cwd=ROOT, env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn('run=true', (root / 'output').read_text())


class NightlyEvidenceTests(unittest.TestCase):
    def setUp(self):
        from ui_test_nightly import qualify, verified_run
        self.qualify = qualify
        self.verified_run = verified_run
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for shard in (1, 2, 3):
            self.write(shard)

    def write(self, shard, *, commit=SHA, verified=True, state='passed'):
        (self.root / f'{shard}.json').write_text(json.dumps({
            'commit': commit, 'shard': shard, 'verified': verified, 'state': state,
        }))

    def qualify_now(self, **changes):
        args = dict(commit=SHA, results=self.root, build='success',
                    controls='success', shards='success', attempt=1)
        return self.qualify(**(args | changes))

    def test_all_shards_verified_and_required_controls_qualify(self):
        self.assertTrue(self.qualify_now())

    def test_known_infrastructure_is_advisory_without_an_anchor(self):
        self.write(2, verified=False, state='infrastructure-advisory')
        self.assertFalse(self.qualify_now())

    def test_real_classifier_advisory_without_runtime_never_establishes_anchor(self):
        from Tests.Tooling.test_ui_test_ci_gate import UITestCIGateTests, execution
        classifier = UITestCIGateTests()
        result = classifier.run_gate(
            english_outcome='failure', receipts={}, executions={'en': execution(
                'en', classification='known-host-infrastructure', exit_status=65,
                runtime_present=False, signature='automation-mode-timeout')})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(classifier.outputs, {'verified': 'false', 'state': 'infrastructure-advisory'})
        self.write(2, verified=classifier.outputs['verified'] == 'true',
                   state=classifier.outputs['state'])
        self.assertFalse(self.qualify_now())

    def test_verified_cli_creates_explicit_exact_sha_attestation(self):
        output = self.root / 'receipt.json'
        run = subprocess.run([sys.executable, str(ROOT / 'scripts/ui_test_nightly.py'),
                              'verify', '--commit', SHA, '--results', str(self.root),
                              '--build', 'success', '--controls', 'success', '--shards', 'success',
                              '--attempt', '1', '--output', str(output)],
                             text=True, capture_output=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        document = json.loads(output.read_text())
        self.assertEqual(document['commit'], SHA)
        self.assertEqual(document['shards'], [1, 2, 3])
        self.assertIs(document['verified'], True)
        self.assertEqual(document['interruptionControls'], 'success')

    def test_wrong_sha_and_absent_evidence_fail_closed(self):
        self.write(2, commit=OTHER)
        with self.assertRaises(ValueError):
            self.qualify_now()
        (self.root / '2.json').unlink()
        with self.assertRaises(ValueError):
            self.qualify_now()

    def test_controls_build_matrix_and_reruns_cannot_qualify(self):
        for key in ('controls', 'build', 'shards'):
            for state in ('failure', 'cancelled', 'skipped', ''):
                with self.subTest(key=key, state=state), self.assertRaises(ValueError):
                    self.qualify_now(**{key: state})
        with self.assertRaises(ValueError):
            self.qualify_now(attempt=2)

    def test_contradictory_or_missing_classifier_result_cannot_qualify(self):
        for verified, state in ((True, 'infrastructure-advisory'), (False, 'passed'),
                                ('true', 'passed'), (False, '')):
            self.write(1, verified=verified, state=state)
            with self.subTest(verified=verified, state=state), self.assertRaises(ValueError):
                self.qualify_now()

    def run_record(self, number=1, commit=SHA, **changes):
        return dict(id=number, head_sha=commit, head_branch='main', run_attempt=1,
                    conclusion='success', event='schedule') | changes

    def artifact(self, commit=SHA, **changes):
        return dict(name=f'nightly-ui-verification-{commit}', expired=False) | changes

    def resolve(self, runs, artifacts):
        class Authority:
            def get(inner, path, query=None):
                if path.endswith('/runs'):
                    return {'workflow_runs': runs}
                return {'artifacts': artifacts.get(int(path.split('/')[-2]), [])}
        return self.verified_run(Authority(), repository='owner/repo', commit=SHA)

    def test_success_and_exact_sha_alone_are_not_evidence(self):
        self.assertIsNone(self.resolve([self.run_record()], {}))
        self.assertIsNone(self.resolve([self.run_record(commit=OTHER)], {1: [self.artifact()]}))
        self.assertIsNone(self.resolve([self.run_record()], {1: [self.artifact(OTHER)]}))

    def test_exact_verified_run_is_eligible(self):
        self.assertEqual(self.resolve([self.run_record()], {1: [self.artifact()]}), 1)

    def test_second_skipped_run_keeps_original_anchor_without_renewal(self):
        runs = [self.run_record(2), self.run_record(1)]
        self.assertEqual(self.resolve(runs, {1: [self.artifact()]}), 1)
        # Once the original expires, the successful skip cannot keep it alive.
        self.assertIsNone(self.resolve(runs, {1: [self.artifact(expired=True)]}))

    def test_failed_rerun_other_branch_and_duplicate_artifacts_never_qualify(self):
        for changes in ({'run_attempt': 2}, {'conclusion': 'failure'},
                        {'head_branch': 'topic'}, {'event': 'pull_request'}):
            self.assertIsNone(self.resolve([self.run_record(**changes)], {1: [self.artifact()]}))
        self.assertIsNone(self.resolve([self.run_record()], {1: [self.artifact()] * 2}))

    def test_advisory_cli_stays_green_without_creating_a_receipt(self):
        self.write(2, verified=False, state='infrastructure-advisory')
        output = self.root / 'receipt.json'
        github_output = self.root / 'output'
        run = subprocess.run([sys.executable, str(ROOT / 'scripts/ui_test_nightly.py'),
                              'verify', '--commit', SHA, '--results', str(self.root),
                              '--build', 'success', '--controls', 'success', '--shards', 'success',
                              '--attempt', '1', '--output', str(output)],
                             env=dict(os.environ, GITHUB_OUTPUT=str(github_output)),
                             text=True, capture_output=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse(output.exists())
        self.assertIn('verified=false', github_output.read_text())


if __name__ == '__main__':
    unittest.main()
