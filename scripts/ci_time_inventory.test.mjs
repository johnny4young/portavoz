import test from 'node:test';
import assert from 'node:assert/strict';
import {collectRunInventory, inventoryArguments} from './ci_time_inventory.mjs';

const repository = 'owner/repo', cutoff = '2026-11-02T00:00:00Z';
const a = 'a'.repeat(40), b = 'b'.repeat(40);
const at = seconds => new Date(Date.UTC(2026, 10, 1) + seconds * 1000).toISOString().replace('.000Z', 'Z');
const run = (id, head = a, seconds = id, patch = {}) => ({id, head_sha: head,
  created_at: at(seconds), updated_at: at(seconds + 1), event: 'pull_request',
  status: 'completed', conclusion: 'success', run_attempt: 1, workflow_id: 42,
  repository: {full_name: repository}, path: '.github/workflows/ci.yml',
  pull_requests: [{number: 9, head: {sha: head}}], ...patch});
function api(rows, intercept = () => undefined) {
  const calls = [];
  const get = async path => {
    calls.push(path);
    assert.ok(path.startsWith('repos/owner/repo/actions/workflows/ci.yml/runs?'));
    const q = new URLSearchParams(path.split('?')[1]);
    assert.equal(q.get('event'), 'pull_request');
    assert.equal(q.get('created'), '<=' + cutoff);
    const override = intercept({q, path, calls});
    if (override !== undefined) return structuredClone(override);
    const selected = rows.filter(r => !q.has('head_sha') || r.head_sha === q.get('head_sha'))
      .slice().sort((x, y) => y.created_at.localeCompare(x.created_at) || y.id - x.id);
    const size = Number(q.get('per_page')), start = (Number(q.get('page')) - 1) * size;
    return structuredClone({total_count: selected.length, workflow_runs: selected.slice(start, start + size)});
  };
  return {get, calls};
}
const collect = (get, fields = {}) => collectRunInventory(get, {repository, cutoff, ...fields});

test('collects every selected-head run, preserving retries, pending and failed runs', async () => {
  const {get} = api([run(4), run(3, b, 3, {status: 'in_progress', conclusion: null}),
    run(2, a, 2, {run_attempt: 3, conclusion: 'failure'}), run(1)]);
  const result = await collect(get);
  assert.equal(result.selectedHeads, 2); assert.equal(result.runCount, 4);
  assert.equal(result.expectedAttemptCount, 6); assert.equal(result.pendingRuns, 1);
  assert.deepEqual(result.heads[0].runs.map(r => r.runId), [1, 2, 4]);
  assert.equal(result.heads[0].runs[1].conclusion, 'failure');
  assert.equal(result.runInventoryVerified, true); assert.equal(result.attemptDetailsCollected, false);
  assert.equal(result.acceptance, null); assert.match(result.digest, /^[a-f0-9]{64}$/);
});
test('full head history is fetched beyond the discovery page boundary', async () => {
  const rows = Array.from({length: 105}, (_, index) => run(index + 1, index === 103 ? b : a));
  const {get, calls} = api(rows);
  const result = await collect(get, {limit: 1});
  assert.equal(result.selectedHeads, 1); assert.equal(result.runCount, 104);
  assert.ok(calls.some(path => path.includes('head_sha=') && path.endsWith('page=2')));
  assert.equal(result.heads[0].runs[0].runId, 1);
});
test('keeps unknown PR linkage instead of inventing a number', async () => {
  const r = await collect(api([run(1, a, 1, {pull_requests: []})]).get);
  assert.deepEqual(r.heads[0].runs[0].prNumbers, []);
});
test('an empty window is explicit and never establishes acceptance', async () => {
  const r = await collect(api([]).get);
  assert.equal(r.selectedHeads, 0); assert.equal(r.runCount, 0);
  assert.equal(r.workflowId, null); assert.equal(r.acceptance, null);
});
test('repeated reads are deterministic and digest binds the cutoff and run attempt', async () => {
  const first = await collect(api([run(1)]).get);
  const same = await collect(api([run(1)]).get);
  assert.deepEqual(same, first);
  const rerun = await collect(api([run(1, a, 1, {run_attempt: 2})]).get);
  assert.notEqual(rerun.digest, first.digest);
});
test('rejects tied selection boundaries rather than choosing a head arbitrarily', async () => {
  await assert.rejects(collect(api([run(1), run(2, b, 1)]).get, {limit: 1}), /Ambiguous/);
});
test('rejects run searches at the GitHub ceiling', async () => {
  const {get} = api([run(1)], ({q}) => q.has('head_sha') ? {total_count: 1000, workflow_runs: []} : undefined);
  await assert.rejects(collect(get), /1000-result ceiling/);
});
test('rejects a selected head that disappears from its full history', async () => {
  const {get} = api([run(1)], ({q}) => q.has('head_sha') ? {total_count: 0, workflow_runs: []} : undefined);
  await assert.rejects(collect(get), /no runs/);
});
test('rejects history truncation and duplicate run IDs', async () => {
  for (const body of [{total_count: 2, workflow_runs: [run(1)]},
    {total_count: 2, workflow_runs: [run(1), run(1)]}]) {
    const {get} = api([run(1)], ({q}) => q.has('head_sha') ? body : undefined);
    await assert.rejects(collect(get), /Incomplete|duplicated/);
  }
});
test('rejects a changed attempt during the second full-history pass', async () => {
  let reads = 0;
  const {get} = api([run(1)], ({q}) => q.has('head_sha') && ++reads > 1
    ? {total_count: 1, workflow_runs: [run(1, a, 1, {run_attempt: 2})]} : undefined);
  await assert.rejects(collect(get), /inventory changed/);
});
test('rejects late-discovered head changes after histories were read', async () => {
  let discovery = 0;
  const {get} = api([run(1)], ({q}) => !q.has('head_sha') && ++discovery > 2
    ? {total_count: 1, workflow_runs: [run(2, b, 2)]} : undefined);
  await assert.rejects(collect(get), /selection changed/);
});
test('rejects discovery/history disagreement even when both history reads would match', async () => {
  const {get} = api([run(1)], ({q}) => q.has('head_sha')
    ? {total_count: 1, workflow_runs: [run(1, a, 1, {run_attempt: 2})]} : undefined);
  await assert.rejects(collect(get), /disagree/);
});
for (const [label, patch] of Object.entries({
  repository: {repository: {full_name: 'other/repo'}}, workflow: {workflow_id: 0},
  path: {path: '.github/workflows/other.yml'}, attempt: {run_attempt: 0},
  timestamp: {updated_at: '2026-02-30T00:00:00Z'}, chronology: {updated_at: at(0)},
  status: {status: 'mystery'}, conclusion: {conclusion: 'unknown'},
  pendingConclusion: {status: 'queued', conclusion: 'success'}, noAssociations: {pull_requests: null},
  wrongPRHead: {pull_requests: [{number: 9, head: {sha: b}}]},
  duplicatePR: {pull_requests: [{number: 9, head: {sha: a}}, {number: 9, head: {sha: a}}]},
})) test(`rejects malformed ${label} evidence`, async () => {
  await assert.rejects(collect(api([run(1, a, 1, patch)]).get), /mismatch|association/);
});
test('rejects a different workflow identity across selected heads', async () => {
  await assert.rejects(collect(api([run(1), run(2, b, 2, {workflow_id: 43})]).get), /Workflow identity changed/);
});
test('invalid inputs fail before API calls', async () => {
  for (const fields of [{limit: 0}, {limit: 101}, {limit: 1.5}, {limit: NaN},
    {repository: '../repo'}, {cutoff: 'yesterday'}, {cutoff: '2026-02-30T00:00:00Z'}]) {
    let calls = 0;
    await assert.rejects(collect(async () => { calls++; }, fields));
    assert.equal(calls, 0);
  }
});
test('CLI arguments are explicit, bounded and reject duplicates or unknown flags', () => {
  assert.deepEqual(inventoryArguments(['--repository', repository, '--cutoff', cutoff]), {repository, cutoff, limit: 50});
  assert.equal(inventoryArguments(['--repository', repository, '--cutoff', cutoff, '--limit', '30']).limit, 30);
  for (const args of [[], ['--repository', repository], ['--cutoff'], ['--extra', 'x'],
    ['--repository', repository, '--repository', repository], ['--repository', repository, '--cutoff', cutoff, '--limit', '2x']]) {
    assert.throws(() => inventoryArguments(args));
  }
});

test('global discovery at the search ceiling cannot prove fewer than requested heads', async () => {
  const rows = Array.from({length: 1000}, (_, index) => run(index + 1, index % 2 ? a : b));
  await assert.rejects(collect(api(rows).get), /ceiling/);
});
test('full history cannot add a run inside the already discovered prefix', async () => {
  for (const extra of [run(4, a, 4), run(3, a, 2)]) {
    const {get} = api([run(2, a, 3), run(1, b, 1)], ({q}) => q.get('head_sha') === a
      ? {total_count: 2, workflow_runs: [run(2, a, 3), extra]} : undefined);
    await assert.rejects(collect(get), /disagree/);
  }
});
test('a complete head boundary before the global ceiling remains usable', async () => {
  const rows = Array.from({length: 1000}, (_, index) => run(index + 1, index % 2 ? a : b));
  const result = await collect(api(rows).get, {limit: 1});
  assert.equal(result.selectedHeads, 1); assert.equal(result.runCount, 500);
});
test('aggregate attempt counts cannot exceed safe numeric precision', async () => {
  await assert.rejects(collect(api([run(1, a, 1, {run_attempt: Number.MAX_SAFE_INTEGER}),
    run(2, b, 2, {run_attempt: Number.MAX_SAFE_INTEGER})]).get), /Unsafe aggregate/);
});
test('an exhausted discovery cannot omit any older selected-head run', async () => {
  const {get} = api([run(2, a, 3)], ({q}) => q.has('head_sha')
    ? {total_count: 2, workflow_runs: [run(2, a, 3), run(1, a, 1)]} : undefined);
  await assert.rejects(collect(get), /disagree/);
});
