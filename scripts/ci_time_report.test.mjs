import test from 'node:test';
import assert from 'node:assert/strict';
import {exactRunReport} from './ci_time_report.mjs';

const base = Date.UTC(2026, 10, 1);
const at = seconds => new Date(base + 1000 * seconds).toISOString();
const job = (id, name, start, end, extra = {}) => ({id, name, run_id: 7, run_attempt: 1,
  conclusion: 'success', runner_id: 1, created_at: at(0), started_at: at(start), completed_at: at(end), ...extra});
const evidence = () => ({repository: 'owner/repo', run: {id: 7, head_sha: 'a'.repeat(40),
  path: '.github/workflows/ci.yml', created_at: at(0)}, attempts: [{ownershipVerified: true, jobsComplete: true, metadata: {run_attempt: 1,
    run_started_at: at(0), conclusion: 'success'}, jobs: [job(1, 'scope', 1, 2), job(2, 'build-and-test', 2, 20),
    job(3, 'gate', 20, 22)]}]});

test('reports an exact gate and job queue proxies but never infers scope or execution', () => {
  const r = exactRunReport(evidence(), 9);
  assert.equal(r.attempts[0].totalSeconds, 22);
  assert.equal(r.attempts[0].executionSeconds, null);
  assert.equal(r.attempts[0].scope, 'unknown');
  assert.equal(r.attempts[0].jobs[1].queueProxySeconds, 2);
});
test('a missing or skipped gate stays unknown', () => {
  const a = evidence(); a.attempts[0].jobs.pop();
  assert.equal(exactRunReport(a, 9).attempts[0].totalSeconds, null);
  const b = evidence(); b.attempts[0].jobs[2].conclusion = 'skipped';
  assert.equal(exactRunReport(b, 9).attempts[0].totalSeconds, null);
});

test('invalid calendar dates do not produce a job duration or queue proxy', () => {
  const e = evidence();
  e.attempts[0].jobs[1].created_at = '2026-02-30T00:00:00Z';
  e.attempts[0].jobs[1].started_at = '2026-02-30T00:00:00Z';
  e.attempts[0].jobs[1].completed_at = '2026-03-02T00:00:05Z';
  const j = exactRunReport(e, 9).attempts[0].jobs[1];
  assert.equal(j.durationSeconds, null);
  assert.equal(j.queueProxySeconds, null);
});

test('invalid runner IDs never produce queue or duration observations', () => {
  for (const runner_id of ['1', -1, 0, null]) {
    const e = evidence(); e.attempts[0].jobs[1].runner_id = runner_id;
    const j = exactRunReport(e, 9).attempts[0].jobs[1];
    assert.equal(j.durationSeconds, null);
    assert.equal(j.queueProxySeconds, null);
  }
});

// Exercise the production collection-to-report path without network or Python.
const {readExactRun} = await import('./ci_time_github.mjs');
const identity = {repository: 'owner/repo', runId: 7, prNumber: 9, headSha: 'a'.repeat(40)};
const step = (name, extra = {}) => ({number: 1, name, status: 'completed', conclusion: 'failure', ...extra});
const product = 'Current-SDK build and selected test suite';
async function collectedReport(jobs, {conclusion = 'failure', attempts = 1} = {}) {
  const run = {id: 7, head_sha: identity.headSha, path: '.github/workflows/ci.yml', event: 'pull_request',
    status: 'completed', repository: {full_name: identity.repository}, workflow_id: 42,
    pull_requests: [{number: 9, head: {sha: identity.headSha}}], run_attempt: attempts,
    created_at: at(0), run_started_at: at(0), updated_at: at(100), conclusion};
  const get = async path => {
    if (path.endsWith('/actions/runs/7')) return {...run};
    const number = Number(path.match(/\/attempts\/(\d+)/)?.[1]);
    if (!number) throw Error(`Unexpected fixture request: ${path}`);
    if (path.includes('/jobs?')) return {total_count: jobs.length, jobs: jobs.map(j =>
      ({...j, head_sha: identity.headSha, status: 'completed'}))};
    return {...run, run_attempt: number};
  };
  return exactRunReport(await readExactRun(get, identity), 9);
}
const outcomeOf = async (jobs, options) => (await collectedReport(jobs, options)).attempts.at(-1).outcome;

test('collector to report classifies a product failure and its dependent gate', async () => {
  const result = await collectedReport([
    job(1, 'build-and-test', 1, 20, {conclusion: 'failure', steps: [step(product)]}),
    job(2, 'gate', 20, 22, {conclusion: 'failure', steps: [step('Require every lane the selection asked for')]})]);
  assert.deepEqual(result.attempts[0].outcome, {category: 'product', origin: 'job-steps'});
  assert.equal(result.attempts[0].scope, 'unknown');
  assert.equal(result.attempts[0].executionSeconds, null);
});

test('collector to report identifies infrastructure, refused reruns and matrix failures', async () => {
  for (const [name, failedStep, category] of [
    ['build-and-test', 'Set up job', 'infrastructure'],
    ['ui-test-gate', 'Refuse to manufacture evidence on a rerun', 'rerun-refused'],
    ['scoped-ui-tests (en)', 'Run functional UI evidence', 'product']]) {
    assert.deepEqual(await outcomeOf([job(1, name, 1, 20, {conclusion: 'failure', steps: [step(failedStep)]})]),
      {category, origin: 'job-steps'});
  }
});

test('an API timeout has explicit provenance and beats a sibling failure', async () => {
  assert.deepEqual(await outcomeOf([
    job(1, 'build-and-test', 1, 20, {conclusion: 'failure', steps: [step(product)]}),
    job(2, 'lint', 1, 20, {conclusion: 'timed_out'})]), {category: 'timeout', origin: 'api-conclusion'});
});

test('cancelled jobs cannot become inferred timeouts or mask uncertain supersession', async () => {
  for (const conclusion of ['failure', 'cancelled']) {
    assert.deepEqual(await outcomeOf([
      job(1, 'build-and-test', 1, 3600, {conclusion: 'cancelled'}),
      job(2, 'gate', 3600, 3601, {conclusion: 'failure', steps: [step('Require every lane the selection asked for')]})
    ], {conclusion}), {category: 'unknown', origin: null});
  }
  assert.deepEqual(await outcomeOf([job(1, 'lint', 1, 20, {conclusion: 'timed_out'})], {conclusion: 'cancelled'}),
    {category: 'timeout', origin: 'api-conclusion'});
});

test('missing, malformed, mixed and unknown failed step evidence stays unknown', async () => {
  for (const steps of [undefined, [], [null], [step('Unknown product test')],
    [step(product, {status: 'in_progress'})], [step(product, {number: 0})],
    [step(product), step('Set up job')], [step(product, {conclusion: 'cancelled'})],
    [step(product), step('Unknown product test', {number: 2})],
    [step('Fail the lane when its evidence is not complete')]]) {
    assert.deepEqual(await outcomeOf([job(1, 'build-and-test', 1, 20, {conclusion: 'failure', steps})]),
      {category: 'unknown', origin: null});
  }
});

test('green jobs, alert and carried failure/timeout never manufacture current outcomes', async () => {
  assert.deepEqual(await outcomeOf([job(1, 'gate', 1, 20)], {conclusion: 'success'}), {category: 'unknown', origin: null});
  for (const conclusion of ['failure', 'timed_out']) {
    const extra = {conclusion, steps: [step(product)]};
    assert.deepEqual(await outcomeOf([job(1, 'alert', 1, 20, extra)]), {category: 'unknown', origin: null});
    assert.deepEqual(await outcomeOf([job(1, 'build-and-test', 1, 20, extra)], {attempts: 2}),
      {category: 'unknown', origin: null});
  }
});

test('raw report input without collector attestations cannot assert an outcome', () => {
  const e = evidence(); e.run.event = 'pull_request';
  e.attempts[0].jobs[1].conclusion = 'timed_out';
  assert.deepEqual(exactRunReport(e, 9).attempts[0].outcome, {category: 'unknown', origin: null});
});

test('successful or unknown attempt states cannot become causal failures from continue-on-error jobs', async () => {
  for (const conclusion of ['success', 'neutral', null, 'unexpected']) {
    for (const jobConclusion of ['failure', 'timed_out']) {
      assert.deepEqual(await outcomeOf([job(1, 'build-and-test', 1, 20,
        {conclusion: jobConclusion, steps: [step(product)]})], {conclusion}),
      {category: 'unknown', origin: null});
    }
  }
});

test('a timed-out overall attempt needs API timeout evidence, not just a product step', async () => {
  assert.deepEqual(await outcomeOf([job(1, 'build-and-test', 1, 20,
    {conclusion: 'failure', steps: [step(product)]})], {conclusion: 'timed_out'}),
  {category: 'unknown', origin: null});
  assert.deepEqual(await outcomeOf([job(1, 'lint', 1, 20, {conclusion: 'timed_out'})], {conclusion: 'timed_out'}),
    {category: 'timeout', origin: 'api-conclusion'});
});

const {collectGateScopeObservations} = await import('./ci_time_github.mjs');
const gateLog = 'env:\n  EVENT_NAME: pull_request\n  SCOPE_RESULT: success\n  IOS_REQUIRED: false\n  UI_REQUIRED: true\n  CONTROLS_REQUIRED: false\n  IOS_RESULT: skipped\n  UI_RESULT: success\n  CONTROLS_RESULT: skipped\n##[endgroup]\n';
function scopeEvidence() {
  const e = evidence(); e.run.event = 'pull_request';
  e.attempts[0].ownershipVerified = true; e.attempts[0].jobsComplete = true;
  e.attempts[0].jobs.forEach(j => { j.head_sha = e.run.head_sha; j.status = 'completed'; });
  return e;
}
test('exact gate observation reaches report without claiming verified scope or execution', async () => {
  const e = await collectGateScopeObservations(async path => {
    assert.equal(path, 'repos/owner/repo/actions/jobs/3/logs'); return gateLog;
  }, scopeEvidence());
  const r = exactRunReport(e, 9).attempts[0];
  assert.equal(r.scopeObservation.status, 'observed');
  assert.equal(r.scopeObservation.jobId, 3);
  assert.equal(r.scopeObservation.attempt, 1);
  assert.equal(r.scopeObservation.selection.uiRequired, true);
  assert.equal(r.scopeObservation.selection.verified, false);
  assert.match(r.scopeObservation.sha256, /^[a-f0-9]{64}$/);
  assert.equal(r.scope, 'unknown'); assert.equal(r.executionSeconds, null);
});
test('missing gate logs are explicit and do not erase exact timing', async () => {
  const e = await collectGateScopeObservations(async () => { throw Error('offline'); }, scopeEvidence());
  const r = exactRunReport(e, 9).attempts[0];
  assert.equal(r.scopeObservation.status, 'unavailable'); assert.equal(r.totalSeconds, 22);
});
test('ambiguous gate log fields stay unknown', async () => {
  const e = await collectGateScopeObservations(async () => gateLog + gateLog, scopeEvidence());
  assert.equal(exactRunReport(e, 9).attempts[0].scopeObservation.status, 'unparseable');
});
test('a carried gate cannot attest the current selection or trigger a log read', async () => {
  const e = scopeEvidence(); e.attempts[0].metadata.run_attempt = 2;
  const result = await collectGateScopeObservations(async () => assert.fail('must not read'), e);
  assert.equal(result.attempts[0].scopeObservation.status, 'missing-exact-gate');
});
test('unverified inventory cannot trigger a scope log read', async () => {
  const e = scopeEvidence(); e.attempts[0].ownershipVerified = false;
  const result = await collectGateScopeObservations(async () => assert.fail('must not read'), e);
  assert.equal(result.attempts[0].scopeObservation.status, 'unverified-inventory');
});
test('unknown PR association is not presented as an attributed PR', () => {
  const e = evidence(); e.prAssociation = {status: 'unknown', source: 'run-api-empty-pull-requests'};
  const r = exactRunReport(e, 9);
  assert.equal(r.prNumber, null); assert.equal(r.requestedPrNumber, 9);
  assert.equal(r.prAssociation.status, 'unknown'); assert.equal(r.attempts[0].totalSeconds, 22);
});

test('a verified PR cannot be relabeled by a different report argument', () => {
  const e = evidence();
  e.prAssociation = {status: 'verified', source: 'run-api-pull-requests', prNumber: 238};
  assert.throws(() => exactRunReport(e, 239), /PR attribution mismatch/);
  assert.equal(exactRunReport(e, 238).prNumber, 238);
});

test('incomplete or unverified collection cannot publish a total even with a plausible gate', () => {
  const complete = evidence();
  assert.equal(exactRunReport(complete, 9).attempts[0].totalSeconds, 22);
  const incomplete = evidence(); incomplete.attempts[0].jobsComplete = false;
  assert.equal(exactRunReport(incomplete, 9).attempts[0].totalSeconds, null);
  const unverified = evidence(); unverified.attempts[0].ownershipVerified = false;
  assert.equal(exactRunReport(unverified, 9).attempts[0].totalSeconds, null);
});
