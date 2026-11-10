import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, mkdtempSync, writeFileSync, existsSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {blockingJobs, nonBlockingJobs, productSteps, classifyStep, declaredTimeouts, workflowJobNames} from './ci_time_workflow.mjs';

const workflow = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
const timeouts = declaredTimeouts([workflow]);

test('job-level timeout parsing ignores step-level limits and absent values', () => {
  const input = 'jobs:\n  lint:\n    runs-on: x\n    timeout-minutes: 15\n    steps:\n' +
    '      - run: y\n        timeout-minutes: 2\n  other:\n    runs-on: x\n';
  assert.deepEqual(declaredTimeouts([input]), {lint: 15});
});
test('timeout expression extracts the pull request ceiling', () => {
  assert.deepEqual(declaredTimeouts(['jobs:\n  lane:\n    timeout-minutes: ${{ inputs.full_ui && 90 || 22 }}\n']), {lane: 22});
});
test('all jobs with parsed timeouts are explicitly blocking or nonblocking', () => {
  assert.ok(Object.keys(timeouts).length > 0);
  for (const job of Object.keys(timeouts)) assert.ok(blockingJobs.pull_request.has(job) || nonBlockingJobs.has(job), job);
  for (const job of nonBlockingJobs) assert.equal(blockingJobs.pull_request.has(job), false, job);
});
test('push release jobs and current required jobs declare timeouts', () => {
  for (const job of [...blockingJobs.push, 'scope', 'gate', 'ui-tests']) assert.ok(Object.hasOwn(timeouts, job), job);
  assert.equal(blockingJobs.push.has('alert'), false);
});
test('each named step is classified, and product policy contains no obsolete or infrastructure steps', () => {
  const names = new Set([...workflow.matchAll(/^\s+- name: (.*)$/gm)].map(match => match[1]));
  assert.ok(names.size > 0);
  for (const name of names) assert.ok(classifyStep(name), `Unclassified: ${name}`);
  for (const name of productSteps) {
    assert.ok(names.has(name), `Removed product step: ${name}`);
    assert.equal(classifyStep(name), 'product', name);
  }
  assert.equal(classifyStep('unknown newly introduced step'), null);
  assert.equal(classifyStep('Restore compatible Swift build state'), 'infrastructure');
});
test('current suite step exists and the legacy refusal is absent', () => {
  assert.match(workflow, /^\s+- name: Current-SDK build/m);
  const legacyRefusal = /^\s+- name: Refuse to manufacture evidence on a rerun/m;
  assert.doesNotMatch(workflow, legacyRefusal);
  assert.match("      - name: Refuse to manufacture evidence on a rerun (legacy)", legacyRefusal);
});

const expectedProductSteps = [
  'Repository, evidence, and CI policy contracts', 'Release performance ledger rules', 'Legacy tooling contracts',
  'Select the Swift test scope', 'Select the iOS lane',
  'Current-SDK build and selected test suite', 'Compile transport-neutral iOS 26 surface',
  'Strict SwiftLint 0.65.0 from checksum-pinned official archive', 'Validate the selector catalog',
  'Select UI evidence', 'Verify interruption safety at the shared callback',
  'Build the UI host and runner once', 'Fit the selection to what remains of the job',
  'Run functional UI evidence', 'Classify functional evidence and hosted runtime drift',
  'Require every lane the selection asked for', 'Fail the lane when its evidence is not complete',
];

test('product step expectations are independent of the classifier policy', () => {
  assert.deepEqual([...productSteps].sort(), [...expectedProductSteps].sort());
  for (const name of expectedProductSteps) assert.equal(classifyStep(name), 'product');
});
test('discover jobs independently of timeout declarations and cover current workflow', () => {
  const fixture = 'jobs:\n  known:\n    timeout-minutes: 5\n  missing-timeout:\n    runs-on: x\nnext:\n  not-a-job:\n    timeout-minutes: 8\n';
  assert.deepEqual(workflowJobNames(fixture), ['known', 'missing-timeout']);
  assert.deepEqual(declaredTimeouts([fixture]), {known: 5});
  for (const job of workflowJobNames(workflow)) {
    assert.ok(blockingJobs.pull_request.has(job) || nonBlockingJobs.has(job), job);
    assert.ok(Object.hasOwn(timeouts, job), 'missing timeout: ' + job);
  }
});
test('timeout parser accepts CR line endings', () => {
  assert.deepEqual(declaredTimeouts(['jobs:\r  lane:\r    timeout-minutes: 7\r']), {lane: 7});
});


test('job discovery handles comments and rejects unsupported YAML instead of omitting jobs', () => {
  assert.deepEqual(workflowJobNames('jobs:\n  future-job: # comment\n    timeout-minutes: 5\n'), ['future-job']);
  assert.throws(() => workflowJobNames('jobs:\n  "quoted-job":\n    timeout-minutes: 5\n'));
  assert.throws(() => workflowJobNames('jobs:\n  inline-job: { runs-on: ubuntu-latest }\n'));
  assert.throws(() => workflowJobNames('name: no jobs\n'));
});


test('blocking and nonblocking policies match independent historical expectations', () => {
  const expectedPR = ['repository-hygiene', 'lint', 'scope', 'swift-scope', 'build-and-test',
    'ios-portability', 'build-ui-products', 'scoped-ui-tests', 'interruption-controls',
    'ui-test-gate', 'ui-tests', 'interruption', 'gate'];
  const expectedPush = ['repository-hygiene', 'lint', 'build-and-test', 'ios-portability'];
  assert.deepEqual([...blockingJobs.pull_request].sort(), expectedPR.sort());
  assert.deepEqual([...blockingJobs.push].sort(), expectedPush.sort());
  assert.deepEqual([...nonBlockingJobs].sort(), ['alert', 'meeting-review-comparison']);
});

test('diagnostic tests are mandatory in hygiene and run on the declared Node runtime', () => {
  const hygiene = readFileSync(new URL('./check-repository-hygiene.sh', import.meta.url), 'utf8');
  assert.match(hygiene, /^set -euo pipefail$/m);
  assert.match(hygiene, /^node --test scripts\/ci_time_\*.test.mjs scripts\/repository_hygiene.test.mjs$/m);
  const lane = workflow.split('  repository-hygiene:\n')[1].split('\n  lint:')[0];
  assert.match(lane, /uses: actions\/setup-node@[a-f0-9]{40}/);
  assert.match(lane, /node-version-file: .node-version/);
  assert.match(lane, /package-manager-cache: false/);
  assert.ok(lane.indexOf('uses: actions/setup-node@') < lane.indexOf('run: scripts/check-repository-hygiene.sh'));
  assert.equal(readFileSync(new URL('../.node-version', import.meta.url), 'utf8').trim(), '26.13.0');
});

test('a diagnostic failure stops hygiene before any legacy tool executes', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'ci-time-gate-'));
  try {
    writeFileSync(join(scratch, 'node'), '#!/bin/sh\nexit 42\n', {mode: 0o700});
    writeFileSync(join(scratch, 'python3'), '#!/bin/sh\ntouch "$CI_LEGACY_MARKER"\nexit 0\n', {mode: 0o700});
    const marker = join(scratch, 'legacy-executed');
    const result = spawnSync('/bin/bash', [fileURLToPath(new URL('./check-repository-hygiene.sh', import.meta.url))],
      {encoding: 'utf8', env: {...process.env, PATH: scratch + ':' + process.env.PATH, CI_LEGACY_MARKER: marker}});
    assert.equal(result.error, undefined);
    assert.equal(result.status, 42, result.stderr);
    assert.equal(existsSync(marker), false);
  } finally { rmSync(scratch, {recursive: true, force: true}); }
});
