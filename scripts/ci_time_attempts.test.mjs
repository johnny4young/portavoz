import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {validateRunInventory, collectInventoryAttempts, attemptsArgument} from './ci_time_attempts.mjs';
const repository = 'owner/repo', cutoff = '2026-11-02T00:00:00Z';
const at = seconds => new Date(Date.UTC(2026, 10, 1) + seconds * 1000).toISOString().replace('.000Z', 'Z');
const head = id => id.toString(16).padStart(40, '0');
const run = (id, patch = {}) => ({id, head_sha: head(id), workflow_id: 42,
  path: '.github/workflows/ci.yml', event: 'pull_request', repository: {full_name: repository},
  created_at: at(0), updated_at: at(100), run_started_at: at(0), run_attempt: 1,
  status: 'completed', conclusion: 'success', pull_requests: [], ...patch});
const row = r => ({runId: r.id, headSha: r.head_sha, workflowId: r.workflow_id,
  createdAt: r.created_at, updatedAt: r.updated_at, latestAttempt: r.run_attempt,
  status: r.status, conclusion: r.conclusion, prNumbers: r.pull_requests.map(p => p.number)});
function seal(input) {
  input.digest = createHash('sha256').update(JSON.stringify({repository: input.repository,
    cutoff: input.cutoff, heads: input.heads})).digest('hex');
  return input;
}
function inventory(runs) {
  return seal({schemaVersion: 1, repository, workflow: '.github/workflows/ci.yml',
    workflowId: runs.length ? 42 : null, cutoff, requestedHeads: 50, selectedHeads: runs.length,
    selectionComplete: true, runInventoryVerified: true, attemptDetailsCollected: false,
    runCount: runs.length, expectedAttemptCount: runs.reduce((a, r) => a + r.run_attempt, 0),
    pendingRuns: runs.filter(r => r.status !== 'completed').length,
    heads: runs.map(r => ({headSha: r.head_sha, latestCreatedAt: r.created_at, runs: [row(r)]}))});
}
const job = (r, number, patch = {}) => ({id: r.id * 100 + number, run_id: r.id,
  run_attempt: number, head_sha: r.head_sha, name: 'gate', status: 'completed', conclusion: 'success',
  runner_id: 1, created_at: at(0), started_at: at((number - 1) * 20 + 2), completed_at: at((number - 1) * 20 + 10),
  steps: [{number: 1, name: 'Require every lane the selection asked for', status: 'completed', conclusion: 'success'}], ...patch});
function api(runs, intercept = () => undefined) {
  const calls = [];
  const get = async path => {
    calls.push(path);
    const id = Number(path.match(/\/runs\/(\d+)/)?.[1]);
    const r = runs.find(run => run.id === id);
    assert.ok(r, path);
    const number = Number(path.match(/\/attempts\/(\d+)/)?.[1]);
    const replacement = intercept({path, r, number, calls});
    if (replacement !== undefined) return structuredClone(replacement);
    if (path.includes('/jobs?')) return {total_count: 1, jobs: [job(r, number)]};
    return structuredClone({...r, run_attempt: number || r.run_attempt,
      run_started_at: at(((number || r.run_attempt) - 1) * 20)});
  };
  return {get, calls};
}

test('collects all declared runs and attempts without inventing missing PR linkage or acceptance', async () => {
  const runs = [run(1), run(2, {run_attempt: 2, conclusion: 'failure'})];
  const {get} = api(runs);
  const result = await collectInventoryAttempts(get, inventory(runs));
  assert.equal(result.collectedRuns, 2); assert.equal(result.collectedAttempts, 3);
  assert.equal(result.collectedJobRows, 3); assert.equal(result.totalsKnown, 3);
  assert.equal(result.attemptJobCoverageComplete, true); assert.equal(result.acceptance, null);
  assert.equal(result.selectionReverified, false);
  assert.equal(result.results[0].report.prNumber, null);
  assert.equal(result.results[0].report.attempts[0].totalSeconds, 10);
  assert.equal(result.results[1].report.attempts[1].totalSeconds, 30);
  assert.equal(result.results[1].report.attempts[0].executionSeconds, null);
});
test('preserves uniquely verified PR attribution and failure/cancellation metadata', async () => {
  const runs = [run(1, {pull_requests: [{number: 9, head: {sha: head(1)}}], conclusion: 'failure'}),
    run(2, {conclusion: 'cancelled'})];
  const result = await collectInventoryAttempts(api(runs).get, inventory(runs));
  assert.equal(result.results[0].report.prNumber, 9);
  assert.deepEqual(result.results.map(r => r.attempts[0].conclusion), ['failure', 'cancelled']);
});
test('retains distinct attempt timestamps and runnerless cancellation without shortening total time', async () => {
  const runs = [run(1, {run_attempt: 2, conclusion: 'cancelled'})];
  const {get} = api(runs, ({path, r, number}) => {
    if (path.includes('/jobs?')) return {total_count: 2, jobs: [job(r, number),
      job(r, number, {id: 900 + number, name: 'build-and-test', runner_id: 0, conclusion: 'cancelled',
        started_at: at((number - 1) * 20), completed_at: at((number - 1) * 20 + 1)})]};
    if (number) return {...r, run_attempt: number, created_at: at((number - 1) * 20 + 1),
      run_started_at: at((number - 1) * 20)};
  });
  const result = await collectInventoryAttempts(get, inventory(runs));
  assert.equal(result.attemptJobCoverageComplete, true);
  assert.equal(result.collectedAttempts, 2);
  const r = result.results[0];
  assert.deepEqual(r.attempts.map(a => a.createdAt), [at(1), at(21)]);
  assert.equal(r.report.workflowCreatedAt, at(0));
  assert.equal(r.report.attempts[1].totalSeconds, 30);
  for (const a of r.report.attempts) {
    assert.equal(a.executionSeconds, null);
    assert.equal(a.jobs[1].durationSeconds, null);
    assert.equal(a.jobs[1].queueProxySeconds, null);
  }
  assert.equal(result.acceptance, null);
});
test('a pending run remains visible and does not prevent independent completed runs', async () => {
  const runs = [run(1, {status: 'queued', conclusion: null}), run(2)];
  const {get, calls} = api(runs);
  const r = await collectInventoryAttempts(get, inventory(runs));
  assert.equal(r.attemptJobCoverageComplete, false); assert.equal(r.collectedRuns, 1);
  assert.equal(r.results[0].reason, 'pending-in-source-inventory');
  assert.equal(calls.some(path => path.includes('/runs/1')), false);
});
test('a stale run is refused before job downloads; other runs still complete', async () => {
  const runs = [run(1), run(2)];
  const {get, calls} = api(runs, ({r}) => r.id === 1 ? {...r, run_attempt: 2} : undefined);
  const result = await collectInventoryAttempts(get, inventory(runs));
  assert.equal(result.collectedRuns, 1); assert.equal(result.results[0].status, 'not-collected');
  assert.equal(calls.some(path => path.includes('/runs/1/attempts/')), false);
});
test('failed final reread removes plausible timings and job evidence', async () => {
  const runs = [run(1)]; let reads = 0;
  const {get} = api(runs, ({path, r}) => path.endsWith('/runs/1') && ++reads === 3
    ? {...r, updated_at: at(101)} : undefined);
  const result = await collectInventoryAttempts(get, inventory(runs));
  assert.equal(result.collectedRuns, 0); assert.equal(result.totalsKnown, 0);
  assert.equal(result.results[0].reason, 'changed-or-unavailable-on-final-read');
  assert.equal('report' in result.results[0], false); assert.equal('attempts' in result.results[0], false);
});
test('API failures stay explicit, omit sensitive error text, and preserve independent rows', async () => {
  const runs = [run(1), run(2)];
  const {get} = api(runs, ({r}) => { if (r.id === 1) throw Error('PRIVATE-SENTINEL'); });
  const result = await collectInventoryAttempts(get, inventory(runs));
  assert.equal(result.collectedRuns, 1); assert.equal(result.attemptJobCoverageComplete, false);
  assert.equal(JSON.stringify(result).includes('PRIVATE-SENTINEL'), false);
});
test('retained metadata is allowlisted, including step fields', async () => {
  const runs = [run(1, {actor: {email: 'PRIVATE-SENTINEL'}})];
  const {get} = api(runs, ({path, r, number}) => path.includes('/jobs?') ? {total_count: 1,
    jobs: [job(r, number, {runner_name: 'PRIVATE-SENTINEL', extra: 'PRIVATE-SENTINEL',
      steps: [{number: 1, name: 'Set up job', status: 'completed', conclusion: 'success', secret: 'PRIVATE-SENTINEL'}]})]} : undefined);
  const result = await collectInventoryAttempts(get, inventory(runs));
  assert.equal(result.collectedRuns, 1); assert.equal(JSON.stringify(result).includes('PRIVATE-SENTINEL'), false);
});
test('carried jobs retain their earlier attempt identity', async () => {
  const runs = [run(1, {run_attempt: 2})];
  const carried = job(runs[0], 1, {id: 99, name: 'scope', completed_at: at(1)});
  const {get} = api(runs, ({path, r, number}) => path.includes('/jobs?')
    ? {total_count: 2, jobs: [carried, job(r, number)]} : undefined);
  const result = await collectInventoryAttempts(get, inventory(runs));
  assert.equal(result.collectedAttempts, 2); assert.equal(result.collectedJobRows, 4);
  assert.equal(result.results[0].attempts[1].jobs[0].run_attempt, 1);
});
test('a changed carried job invalidates its whole run', async () => {
  const runs = [run(1, {run_attempt: 2})];
  const carried = job(runs[0], 1, {id: 99, name: 'scope'});
  const {get} = api(runs, ({path, r, number}) => path.includes('/jobs?')
    ? {total_count: 2, jobs: [{...carried, name: number === 2 ? 'altered' : 'scope'}, job(r, number)]} : undefined);
  const result = await collectInventoryAttempts(get, inventory(runs));
  assert.equal(result.collectedRuns, 0); assert.equal(result.attemptJobCoverageComplete, false);
});
test('duplicate job identity across runs cannot qualify complete coverage', async () => {
  const runs = [run(1), run(2)];
  const {get} = api(runs, ({path, r, number}) => path.includes('/jobs?')
    ? {total_count: 1, jobs: [job(r, number, {id: 1})]} : undefined);
  const result = await collectInventoryAttempts(get, inventory(runs));
  assert.equal(result.collectedRuns, 1); assert.equal(result.attemptJobCoverageComplete, false);
});
test('truncated jobs cannot leave an apparently complete run', async () => {
  const runs = [run(1)];
  const {get} = api(runs, ({path, r, number}) => path.includes('/jobs?')
    ? {total_count: 2, jobs: [job(r, number)]} : undefined);
  const result = await collectInventoryAttempts(get, inventory(runs));
  assert.equal(result.collectedRuns, 0); assert.equal(result.collectedAttempts, 0);
});
test('invalid or modified manifest evidence fails before API requests', async () => {
  for (const mutate of [v => v.digest = 'bad', v => v.runCount++, v => v.expectedAttemptCount++,
    v => v.pendingRuns++, v => v.selectionComplete = false, v => v.repository = '../repo',
    v => v.selectedHeads++, v => v.heads[0].latestCreatedAt = at(5),
    v => v.heads[0].runs[0].latestAttempt = 1001, v => v.heads.push(v.heads[0]),
    v => v.heads[0].runs.push(v.heads[0].runs[0])]) {
    const value = inventory([run(1)]); mutate(value); let calls = 0;
    await assert.rejects(collectInventoryAttempts(async () => { calls++; }, value));
    assert.equal(calls, 0);
  }
});
test('empty inventory never establishes complete coverage', async () => {
  const result = await collectInventoryAttempts(() => { throw Error('must not call'); }, inventory([]));
  assert.equal(result.attemptJobCoverageComplete, false); assert.equal(result.acceptance, null);
});
test('CLI requires exactly one explicit inventory file', () => {
  assert.equal(attemptsArgument(['--inventory', 'a.json']), 'a.json');
  for (const args of [[], ['a.json'], ['--other', 'a.json'], ['--inventory', ''], ['--inventory', 'a.json', '--extra']]) {
    assert.throws(() => attemptsArgument(args));
  }
});
test('caller mutation during API reads cannot rewrite the source snapshot', async () => {
  const runs = [run(1)], source = inventory(runs), originalDigest = source.digest;
  const {get} = api(runs, () => { source.heads[0].runs[0].latestAttempt = 20; source.digest = 'modified'; });
  const result = await collectInventoryAttempts(get, source);
  assert.equal(result.collectedRuns, 1); assert.equal(result.expectedAttempts, 1);
  assert.equal(result.sourceInventoryDigest, originalDigest);
});
test('latest attempt cannot contradict the source conclusion', async () => {
  const runs = [run(1)];
  const {get} = api(runs, ({path, r}) => path.endsWith('/attempts/1')
    ? {...r, conclusion: 'failure'} : undefined);
  const result = await collectInventoryAttempts(get, inventory(runs));
  assert.equal(result.attemptJobCoverageComplete, false);
  assert.equal(result.collectedRuns, 0);
});
test('source snapshot bounds every root read before undeclared attempt traversal', async () => {
  const runs = [run(1)]; let roots = 0;
  const {get, calls} = api(runs, ({path, r}) => {
    if (path.endsWith('/runs/1') && ++roots > 1) return {...r, run_attempt: 1001};
    if (path.includes('/attempts/2')) throw Error('undeclared attempt requested');
  });
  const result = await collectInventoryAttempts(get, inventory(runs));
  assert.equal(result.collectedRuns, 0);
  assert.equal(calls.some(path => path.includes('/attempts/2')), false);
});
test('an earlier failed attempt may differ from the final successful attempt', async () => {
  const runs = [run(1, {run_attempt: 2})];
  const {get} = api(runs, ({path, r}) => path.endsWith('/attempts/1')
    ? {...r, run_attempt: 1, run_started_at: at(0), conclusion: 'failure'} : undefined);
  const result = await collectInventoryAttempts(get, inventory(runs));
  assert.equal(result.attemptJobCoverageComplete, true);
  assert.deepEqual(result.results[0].attempts.map(a => a.conclusion), ['failure', 'success']);
});
