import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {attemptRow, buildLogDigest, exemptFromChanges, ghCompare, issueAction, issueBody, parseLimit,
  sloArguments, summarize} from './ci_time_slo.mjs';

const sha = 'b'.repeat(40);
const run = {id: 9, head_sha: sha, repository: {full_name: 'owner/repo'}};
const at = minute => new Date(Date.UTC(2026, 10, 11, 12, minute)).toISOString().replace('.000Z', 'Z');
const job = (name, start, end, extra = {}) => ({id: start * 100 + end, name, run_attempt: 1, runner_id: 3,
  created_at: at(start), started_at: at(start), completed_at: at(end), ...extra});
const attempt = (jobs, extra = {}) => ({metadata: {run_attempt: 1, run_started_at: at(0), conclusion: 'success', ...extra}, jobs});
const changes = (files = ['Sources/x.swift'], workflowPatches = '') => ({files, workflowPatches});
const row = (jobs, options = {}) => attemptRow({run, attempt: attempt(jobs, options.metadata),
  changes: 'changes' in options ? options.changes : changes(), buildLog: options.buildLog ?? null,
  prRunStarts: options.prRunStarts ?? []});

test('execution is the longest fresh blocking job and total ends at the last blocking job', () => {
  const result = row([job('repository-hygiene', 0, 2), job('build-and-test', 1, 9, {created_at: at(0)}),
    job('gate', 9, 10), job('alert', 10, 30), job('meeting-review-comparison', 10, 40)]);
  assert.equal(result.execution, 8 * 60);
  assert.equal(result.total, 10 * 60);
  assert.equal(result.longestJob, 'build-and-test');
  assert.equal(result.macosQueue, 60);
  assert.equal(result.ordinary, true);
});

test('carried and runner-less jobs never set the attempt timing', () => {
  const result = row([job('build-and-test', 0, 50, {run_attempt: 0}), job('ui-tests', 0, 40, {runner_id: 0}),
    job('lint', 0, 1), job('gate', 1, 2)]);
  assert.equal(result.execution, 60);
  assert.equal(result.total, 120);
});

test('interruption controls and an Xcode pin leave the ordinary set; unknown files do not', () => {
  assert.equal(row([job('interruption', 0, 5), job('gate', 5, 6)]).ordinary, false);
  assert.equal(row([job('gate', 0, 1)], {changes: changes(['scripts/verify-ci-toolchain.sh'])}).ordinary, false);
  assert.equal(row([job('gate', 0, 1)], {changes: changes(['.github/workflows/ci.yml'], '+  X: /Applications/Xcode_27.1.app')}).ordinary, false);
  assert.equal(row([job('gate', 0, 1)], {changes: null}).ordinary, true);
  assert.equal(row([job('gate', 0, 1)], {changes: null}).filesKnown, false);
  assert.equal(exemptFromChanges(changes(['.github/workflows/ci.yml'], ' context Xcode_26.6')), false);
});

test('only a cancelled attempt with a newer run on its pull request is superseded', () => {
  const jobs = [job('build-and-test', 0, 6), job('gate', 6, 7)];
  assert.equal(row(jobs, {metadata: {conclusion: 'cancelled'}, prRunStarts: [at(0), at(5)]}).superseded, true);
  assert.equal(row(jobs, {metadata: {conclusion: 'cancelled'}, prRunStarts: [at(0), at(8)]}).superseded, false);
  assert.equal(row(jobs, {metadata: {conclusion: 'failure'}, prRunStarts: [at(5)]}).superseded, false);
});

test('the build log names the cache state and the Swift coverage', () => {
  const log = lines => lines.map(text => `2026-11-11T12:00:00.0000000Z ${text}`).join('\n');
  assert.deepEqual(buildLogDigest(log(['Cache hit for: k', '  PORTAVOZ_SWIFT_TEST_SCOPE: '])), {cache: 'exact', coverage: 'full'});
  assert.deepEqual(buildLogDigest(log(['Cache hit for restore-key: k', '  PORTAVOZ_SWIFT_TEST_SCOPE: Tooling'])),
    {cache: 'fallback', coverage: 'contract-only'});
  assert.equal(buildLogDigest(log(['Cache not found for input keys: k'])).cache, 'miss');
  assert.equal(buildLogDigest(log(['Cache hit for: k', '##[warning]Cached Swift build state failed freshness verification'])).cache, 'rejected');
  // The workflow script is echoed without a timestamp; only the annotation counts.
  assert.equal(buildLogDigest('echo "::warning::Cached Swift build state failed freshness"').cache, 'unknown');
  assert.deepEqual(buildLogDigest(null), {cache: 'unknown', coverage: 'unknown'});
});

const measured = (execution, total, extra = {}) => ({head: `h${execution}-${total}`, execution, total, ordinary: true,
  superseded: false, filesKnown: true, macosQueue: 0, cache: 'fallback', coverage: 'full', url: 'u', longestJob: 'gate', ...extra});

test('a p95 equal to the limit passes and one second over breaches', () => {
  assert.equal(summarize([measured(600, 1200)]).executionBreached, false);
  assert.equal(summarize([measured(600, 1200)]).totalBreached, false);
  assert.equal(summarize([measured(601, 1200)]).executionBreached, true);
  assert.equal(summarize([measured(600, 1201)]).totalBreached, true);
});

test('exempt and superseded attempts stay out of the p95', () => {
  const rows = [measured(100, 200), measured(5000, 9000, {ordinary: false}), measured(4000, 8000, {superseded: true})];
  const summary = summarize(rows);
  assert.equal(summary.attempts, 1);
  assert.equal(summary.execution.p95, 100);
});

test('no measured ordinary attempt is unknown, never healthy', () => {
  assert.throws(() => summarize([]), /No ordinary attempt/);
  assert.throws(() => summarize([measured(null, null)]), /No ordinary attempt/);
  assert.throws(() => summarize([measured(100, 200, {ordinary: false})]), /No ordinary attempt/);
});

test('missing measurements are counted, not erased', () => {
  const summary = summarize([measured(100, 200), measured(null, 300)]);
  assert.equal(summary.missing, 1);
  assert.equal(summary.execution.n, 1);
});

test('the issue opens, updates, closes or stays closed', () => {
  const over = summarize([measured(700, 100)]), within = summarize([measured(100, 100)]);
  assert.deepEqual(issueAction(over, null), {kind: 'create'});
  assert.deepEqual(issueAction(over, 4), {kind: 'edit', number: 4});
  assert.deepEqual(issueAction(within, 4), {kind: 'close', number: 4});
  assert.deepEqual(issueAction(within, null), {kind: 'none'});
  assert.match(issueBody(over, {headsRequested: 20, runUrl: 'r'}), /execution p95 11:40 > 10:00/);
  assert.match(issueBody(within, {headsRequested: 20, runUrl: 'r'}), /^Within the SLO/);
});

test('limits and arguments reject anything but plain positive integers', () => {
  for (const bad of ['0', '-1', '1e3', '600 ', '600;true', '9999999', 'abc']) {
    assert.throws(() => parseLimit(bad, 1), /Invalid limit/, bad);
  }
  assert.equal(parseLimit('', 600), 600);
  assert.equal(parseLimit(undefined, 600), 600);
  assert.equal(parseLimit('1', 600), 1);
  const ok = ['--repository', 'o/r', '--run-url', 'u'];
  assert.deepEqual(sloArguments(ok, {SLO_EXECUTION_SECONDS: '1'}).limits, {execution: 1, total: 1200});
  assert.throws(() => sloArguments(['--repository', 'o/r']), /Missing or invalid/);
  assert.throws(() => sloArguments(['--repository', '../r', '--run-url', 'u']), /Missing or invalid/);
  assert.throws(() => sloArguments([...ok, '--heads', '91']), /At most 90/);
  assert.throws(() => sloArguments([...ok, '--ref', 'x']), /Usage/);
  assert.throws(() => sloArguments(ok, {SLO_TOTAL_SECONDS: '$(id)'}), /Invalid limit/);
});

test('the compare read accepts only a plain ref and a full SHA', async () => {
  for (const [repository, ref, head] of [['o/r', 'a..b', sha], ['o/r', 'main', 'abc'], ['o/../r', 'main', sha],
    ['o/r', 'main;x', sha]]) {
    await assert.rejects(ghCompare(repository, ref, head), /Invalid compare identity/);
  }
});

test('the workflow reads metadata only, with the least permission and no injected input', () => {
  const workflow = readFileSync(new URL('../.github/workflows/ci-time-slo.yml', import.meta.url), 'utf8');
  assert.doesNotMatch(workflow, /pull_request|ref:|download-artifact|upload-artifact/);
  assert.match(workflow, /^permissions:\n  contents: read\n/m);
  assert.match(workflow, /    permissions:\n      actions: read\n      contents: read\n      issues: write\n    steps:/);
  assert.match(workflow, /persist-credentials: false/);
  const run = workflow.split('\n').filter(text => text.trim().startsWith('run:'));
  assert.equal(run.length, 1);
  assert.doesNotMatch(run[0], /\$\{\{/);
  assert.match(workflow, /SLO_EXECUTION_SECONDS: \$\{\{ inputs\.execution_limit_seconds \}\}/);
});
