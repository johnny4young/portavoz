import test from 'node:test';
import assert from 'node:assert/strict';
import {allPages, readExactRun, scopeFromGateLog, discoverHeads} from './ci_time_github.mjs';

const sha = 'a'.repeat(40);
const run = {id: 7, head_sha: sha, path: '.github/workflows/ci.yml', event: 'pull_request',
  status: 'completed', repository: {full_name: 'owner/repo'}, workflow_id: 42,
  pull_requests: [{number: 238, head: {sha}}], run_attempt: 1, created_at: '2026-11-01T00:00:00Z',
  run_started_at: '2026-11-01T00:00:00Z', updated_at: '2026-11-01T00:02:00Z'};
const job = {id: 1, run_id: 7, run_attempt: 1, head_sha: sha, status: 'completed',
  name: 'gate', completed_at: '2026-11-01T00:02:00Z'};
const identity = {repository: 'owner/repo', runId: 7, headSha: sha, prNumber: 238};
const api = (attemptJobs = [job]) => async path => {
  if (path.endsWith('/actions/runs/7')) return {...run};
  if (path.endsWith('/attempts/1')) return {...run};
  if (path.includes('/attempts/1/jobs?')) return {total_count: attemptJobs.length, jobs: attemptJobs};
  throw Error(`Unexpected path ${path}`);
};

test('reads exact completed run and all attempts without claiming scope', async () => {
  const result = await readExactRun(api(), identity);
  assert.equal(result.attempts.length, 1);
  assert.equal(result.attempts[0].jobs[0].id, 1);
  assert.equal('scopeEvidence' in result, false);
});
test('follows pages and rejects missing or duplicate jobs', async () => {
  const pages = [{total_count: 3, jobs: [{id: 1}, {id: 2}]}, {total_count: 3, jobs: [{id: 3}]}];
  let i = 0;
  assert.deepEqual((await allPages(async () => pages[i++], 'p', 'jobs', 2)).map(x => x.id), [1, 2, 3]);
  i = 0;
  await assert.rejects(allPages(async () => [{total_count: 3, jobs: [{id: 1}, {id: 2}]},
    {total_count: 3, jobs: [{id: 2}]}][i++], 'p', 'jobs', 2), /duplicated/);
  await assert.rejects(allPages(async () => ({total_count: 2, jobs: [{id: 1}]}), 'p', 'jobs', 2), /Incomplete/);
});
test('rejects a changing total across pages', async () => {
  let i = 0;
  await assert.rejects(allPages(async () => [{total_count: 3, jobs: [{id: 1}, {id: 2}]},
    {total_count: 4, jobs: [{id: 3}]}][i++], 'p', 'jobs', 2), /changed/);
});
test('rejects a different head, workflow or unfinished run', async () => {
  for (const patch of [{head_sha: 'b'.repeat(40)}, {path: '.github/workflows/other.yml'}, {status: 'in_progress'}]) {
    const get = async path => path.endsWith('/actions/runs/7') ? {...run, ...patch} : api()(path);
    await assert.rejects(readExactRun(get, identity), /identity or state/);
  }
});
test('rejects jobs from another run, head or a later attempt', async () => {
  for (const patch of [{run_id: 8}, {head_sha: 'b'.repeat(40)}, {run_attempt: 2}]) {
    await assert.rejects(readExactRun(api([{...job, ...patch}]), identity), /Job identity/);
  }
});
test('rejects a run whose latest attempt changes during the read', async () => {
  let reads = 0;
  const get = async path => path.endsWith('/actions/runs/7') && ++reads === 2 ? {...run, run_attempt: 2} : api()(path);
  await assert.rejects(readExactRun(get, identity), /changed/);
});
test('rejects malformed identities before any API call', async () => {
  let called = false;
  await assert.rejects(readExactRun(async () => {called = true;}, {...identity, repository: '../x'}), /Invalid/);
  assert.equal(called, false);
});

test('a carried job must match an earlier attempt of the same run', async () => {
  const second = {...run, run_attempt: 2, run_started_at: '2026-11-01T00:03:00Z'};
  const later = {...job, id: 2, run_attempt: 2, name: 'gate'};
  const get = async path => {
    if (path.endsWith('/actions/runs/7')) return second;
    if (path.endsWith('/attempts/1')) return run;
    if (path.endsWith('/attempts/2')) return second;
    if (path.includes('/attempts/1/jobs?')) return {total_count: 1, jobs: [job]};
    if (path.includes('/attempts/2/jobs?')) return {total_count: 2, jobs: [job, later]};
    throw Error('Unexpected path');
  };
  assert.equal((await readExactRun(get, identity)).attempts.length, 2);
  const forged = async path => path.includes('/attempts/2/jobs?')
    ? {total_count: 2, jobs: [{...job, name: 'other'}, later]} : get(path);
  await assert.rejects(readExactRun(forged, identity), /Unproven carried/);
});

test('rejects a mismatched repository, PR or workflow identity', async () => {
  for (const patch of [{repository: {full_name: 'other/repo'}},
    {pull_requests: [{number: 239, head: {sha}}]}, {workflow_id: null}]) {
    const get = async path => path.endsWith('/actions/runs/7') ? {...run, ...patch} : api()(path);
    await assert.rejects(readExactRun(get, identity), /identity or state/);
  }
});

const gateEnv = ['env:', '  EVENT_NAME: pull_request', '  SCOPE_RESULT: success', '  IOS_REQUIRED: false',
  '  IOS_RESULT: skipped', '  UI_REQUIRED: true', '  UI_RESULT: success', '  CONTROLS_REQUIRED: false',
  '  CONTROLS_RESULT: skipped', '##[endgroup]'].join('\n');
test('extracts only a complete and consistent gate scope block', () => {
  assert.deepEqual(scopeFromGateLog(gateEnv), {verified: false, source: 'unattested-gate-log', iosRequired: false, uiRequired: true, interruptionRequired: false});
  assert.equal(scopeFromGateLog(gateEnv.replace('  UI_REQUIRED: true\n', '')), null);
  assert.equal(scopeFromGateLog(gateEnv.replace('  UI_REQUIRED: true', '  UI_REQUIRED: maybe')), null);
  assert.equal(scopeFromGateLog(gateEnv.replace('  UI_REQUIRED: true', '  UI_REQUIRED: true\n  UI_REQUIRED: false')), null);
  assert.equal(scopeFromGateLog(`${gateEnv}\n${gateEnv}`), null);
});
test('does not infer from a failed scope or contradictory unselected lane', () => {
  assert.equal(scopeFromGateLog(gateEnv.replace('SCOPE_RESULT: success', 'SCOPE_RESULT: failure')), null);
  assert.equal(scopeFromGateLog(gateEnv.replace('IOS_RESULT: skipped', 'IOS_RESULT: success')), null);
  assert.equal(scopeFromGateLog(gateEnv.replace('UI_REQUIRED: true', 'UI_REQUIRED: false')
    .replace('UI_RESULT: success', 'UI_RESULT: skipped').replace('CONTROLS_REQUIRED: false', 'CONTROLS_REQUIRED: true')), null);
});

const discoveryRun = (id, head, created, status = 'completed') => ({id, head_sha: head.repeat(40),
  created_at: `2026-11-01T00:00:${String(created).padStart(2, '0')}Z`, event: 'pull_request', status});
test('discovers distinct heads across pages and preserves in-flight runs', async () => {
  const pages = {1: {total_count: 4, workflow_runs: [discoveryRun(1, 'a', 4), discoveryRun(2, 'a', 3)]},
    2: {total_count: 4, workflow_runs: [discoveryRun(3, 'b', 2, 'in_progress'), discoveryRun(4, 'c', 1)]}};
  const get = async path => pages[Number(new URLSearchParams(path.split('?')[1]).get('page'))];
  const result = await discoverHeads(get, {repository: 'owner/repo', cutoff: '2026-11-02T00:00:00Z', limit: 2, pageSize: 2});
  assert.deepEqual(result.heads.map(x => x.headSha), ['a'.repeat(40), 'b'.repeat(40)]);
  assert.equal(result.heads[1].runs[0].status, 'in_progress');
  assert.equal(result.selectionComplete, true);
});
test('a tied boundary is reported as incomplete', async () => {
  const page = {total_count: 3, workflow_runs: [discoveryRun(1, 'a', 3), discoveryRun(2, 'b', 2), discoveryRun(3, 'c', 2)]};
  const result = await discoverHeads(async () => page, {repository: 'owner/repo', cutoff: '2026-11-02T00:00:00Z', limit: 2});
  assert.equal(result.selectionComplete, false);
  assert.equal(result.boundaryTie, true);
});
test('rejects discovery pages that change between passes', async () => {
  let calls = 0;
  const get = async () => ({total_count: 1, workflow_runs: [discoveryRun(++calls, 'a', 1)]});
  await assert.rejects(discoverHeads(get, {repository: 'owner/repo', cutoff: '2026-11-02T00:00:00Z'}), /changed/);
});

test('rejects a changed carried job and a fresh job reusing an earlier ID', async () => {
  const second = {...run, run_attempt: 2, run_started_at: '2026-11-01T00:03:00Z'};
  const get = async (path, replacement) => {
    if (path.endsWith('/actions/runs/7')) return second;
    if (path.endsWith('/attempts/1')) return run;
    if (path.endsWith('/attempts/2')) return second;
    if (path.includes('/attempts/1/jobs?')) return {total_count: 1, jobs: [job]};
    if (path.includes('/attempts/2/jobs?')) return {total_count: 1, jobs: [replacement]};
    throw Error('Unexpected path');
  };
  for (const patch of [{started_at: '2026-11-01T00:00:01Z'}, {conclusion: 'failure'}, {runner_id: 999}]) {
    await assert.rejects(readExactRun(path => get(path, {...job, ...patch}), identity), /Unproven carried/);
  }
  await assert.rejects(readExactRun(path => get(path, {...job, run_attempt: 2}), identity), /ID reused/);
});

test('rejects a malformed job name rather than amplifying it in a report', async () => {
  assert.equal((await readExactRun(api(), identity)).attempts[0].jobs[0].name, 'gate');
  await assert.rejects(readExactRun(api([{...job, name: Array(100).fill(0)}]), identity), /shape mismatch/);
});

test('carried step evidence must match its original exact attempt', async () => {
  const first = {...job, steps: [{number: 1, name: 'Set up job', status: 'completed', conclusion: 'failure'}]};
  const second = {...run, run_attempt: 2};
  const get = async (path, steps) => {
    if (path.endsWith('/actions/runs/7') || path.endsWith('/attempts/2')) return second;
    if (path.endsWith('/attempts/1')) return run;
    if (path.includes('/attempts/1/jobs?')) return {total_count: 1, jobs: [first]};
    if (path.includes('/attempts/2/jobs?')) return {total_count: 1, jobs: [{...first, steps}]};
    throw Error('Unexpected fixture request');
  };
  const equal = structuredClone(first.steps);
  assert.equal((await readExactRun(path => get(path, equal), identity)).attempts[1].ownershipVerified, true);
  for (const changed of [undefined, [], [{...equal[0], name: 'Current-SDK build and selected test suite'}]]) {
    await assert.rejects(readExactRun(path => get(path, changed), identity), /Unproven carried/);
  }
});

test('empty PR association preserves exact run and jobs but does not attribute the PR', async () => {
  const get = async path => { const body = await api()(path); return body.id === 7 ? {...body, pull_requests: []} : body; };
  const result = await readExactRun(get, identity);
  assert.deepEqual(result.prAssociation, {status: 'unknown', prNumber: null, source: 'run-api-empty-pull-requests'});
  assert.equal(result.run.head_sha, sha); assert.equal(result.attempts[0].jobs[0].id, 1);
});
test('PR association changes during collection are rejected', async () => {
  let reads = 0;
  const get = async path => { const body = await api()(path);
    return path.endsWith('/actions/runs/7') && ++reads === 2 ? {...body, pull_requests: []} : body; };
  await assert.rejects(readExactRun(get, identity), /Run changed/);
});
test('attempt PR association must agree with run association', async () => {
  const get = async path => { const body = await api()(path);
    return path.endsWith('/attempts/1') ? {...body, pull_requests: []} : body; };
  await assert.rejects(readExactRun(get, identity), /Attempt identity/);
});
