import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {checkoutObservation, historicalWorkflow, collectHistoricalSources} from './ci_time_source.mjs';

const repository = 'owner/repo', head = 'a'.repeat(40), base = 'b'.repeat(40), merge = 'c'.repeat(40);
const action = 'd'.repeat(40), rootTree = 'e'.repeat(40), githubTree = 'f'.repeat(40), workflowTree = '1'.repeat(40);
const content = 'name: CI\njobs:\n  gate:\n    runs-on: ubuntu-latest\n';
const bytes = Buffer.from(content), blobSha = createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const log = (commit = merge) => [`##[group]Run actions/checkout@${action}`, 'with:', '  token: ***',
  '##[endgroup]', `Syncing repository: ${repository}`, '[command]/usr/bin/git log -1 --format=%H', commit]
  .map(line => `2026-11-01T00:00:02.1234567Z ${line}`).join('\n');
const run = {id: 7, head_sha: head, workflow_id: 8, path: '.github/workflows/ci.yml', event: 'pull_request',
  repository: {full_name: repository}, run_attempt: 1, status: 'completed', conclusion: 'success',
  created_at: '2026-11-01T00:00:00Z', updated_at: '2026-11-01T00:02:00Z', pull_requests: []};
const job = (id, name) => ({id, name, run_id: 7, run_attempt: 1, head_sha: head, runner_id: 10, status: 'completed'});
const evidence = () => ({repository, run: structuredClone(run), attempts: [{metadata: {run_attempt: 1},
  ownershipVerified: true, jobsComplete: true, jobs: [job(11, 'scope'), job(12, 'gate')]}]});
function api(intercept = () => undefined) {
  const calls = [];
  const get = async path => {
    calls.push(path);
    const custom = intercept(path, calls);
    if (custom !== undefined) return structuredClone(custom);
    const root = `repos/${repository}`;
    const data = {
      [`${root}/actions/runs/7`]: run,
      [`${root}/git/commits/${merge}`]: {sha: merge, tree: {sha: rootTree}, parents: [{sha: base}, {sha: head}], author: 'discard'},
      [`${root}/git/trees/${rootTree}`]: {sha: rootTree, truncated: false, tree: [{path: '.github', type: 'tree', mode: '040000', sha: githubTree}]},
      [`${root}/git/trees/${githubTree}`]: {sha: githubTree, truncated: false, tree: [{path: 'workflows', type: 'tree', mode: '040000', sha: workflowTree}]},
      [`${root}/git/trees/${workflowTree}`]: {sha: workflowTree, truncated: false, tree: [{path: 'ci.yml', type: 'blob', mode: '100644', sha: blobSha}]},
      [`${root}/git/blobs/${blobSha}`]: {sha: blobSha, encoding: 'base64', size: bytes.length, content: bytes.toString('base64')},
    };
    assert.ok(path in data, path);
    return structuredClone(data[path]);
  };
  return {get, calls};
}
const identity = {repository, checkoutCommit: merge, headSha: head};

test('observes one exact checkout without retaining raw logs or token fields', () => {
  assert.deepEqual(checkoutObservation(log(), repository), {checkoutCommit: merge, checkoutAction: action,
    logSha256: createHash('sha256').update(log()).digest('hex')});
});
test('rejects missing, echoed, unpinned and duplicate checkout observations', () => {
  for (const value of ['', merge, log().replace('[command]', 'echo [command]'),
    log().replace(action, 'v7'), log().replace(merge, 'bad-sha'), log() + '\n' + log(),
    log().replace(`Syncing repository: ${repository}`, 'Syncing repository: other/repo'),
    log().replace('Syncing repository:', 'echo Syncing repository:')]) {
    assert.equal(checkoutObservation(value, repository), null);
  }
});
test('rejects oversized logs and malformed repository input', () => {
  assert.equal(checkoutObservation('x'.repeat(16 * 1024 * 1024 + 1), repository), null);
  assert.equal(checkoutObservation(log(), '../repo'), null);
});
test('checkout command must follow sync within the same checkout step', () => {
  const strip = value => value.split('\n').map(l => l.replace(/^\S+Z /, ''));
  const lines = strip(log());
  assert.equal(checkoutObservation([...lines.slice(-2), ...lines.slice(0, -2)].join('\n'), repository), null);
  assert.equal(checkoutObservation([...lines.slice(0, -2), '##[group]Run unrelated diagnostic',
    ...lines.slice(-2)].join('\n'), repository), null);
  assert.equal(checkoutObservation([...lines.slice(0, 4), ...lines.slice(-2), lines[4]].join('\n'), repository), null);
  assert.equal(checkoutObservation(log() + '\n##[group]Run unrelated diagnostic\n[command]git log -1 --format=%H\n' + base,
    repository)?.checkoutCommit, merge);
});
test('recovers bytes from the exact merge tree and verifies their Git blob hash', async () => {
  const {get, calls} = api();
  const r = await historicalWorkflow(get, identity);
  assert.equal(r.baseParent, base); assert.equal(r.headParent, head);
  assert.equal(r.workflow.text, content); assert.equal(r.workflow.blobSha, blobSha);
  assert.equal(calls.length, 5);
  assert.ok(calls.every(path => path.startsWith(`repos/${repository}/git/`)));
  assert.equal('author' in r, false);
});
test('rejects wrong parents, octopus merges and mismatched commit identity', async () => {
  for (const patch of [{sha: base}, {parents: [{sha: head}, {sha: base}]},
    {parents: [{sha: base}]}, {parents: [{sha: base}, {sha: head}, {sha: action}]},
    {parents: [{sha: head}, {sha: head}]}]) {
    const {get} = api(path => path.includes('/commits/') ? {sha: merge, tree: {sha: rootTree},
      parents: [{sha: base}, {sha: head}], ...patch} : undefined);
    await assert.rejects(historicalWorkflow(get, identity), /merge parents/);
  }
});
test('rejects truncated, duplicate, wrong-identity or symbolic-link source trees', async () => {
  const valid = {sha: workflowTree, truncated: false, tree: [{path: 'ci.yml', type: 'blob', mode: '100644', sha: blobSha}]};
  for (const patch of [{truncated: true}, {sha: rootTree}, {tree: []},
    {tree: [valid.tree[0], valid.tree[0]]}, {tree: [{...valid.tree[0], mode: '120000'}]}]) {
    const {get} = api(path => path.endsWith(`/trees/${workflowTree}`) ? {...valid, ...patch} : undefined);
    await assert.rejects(historicalWorkflow(get, identity), /source tree|source path/);
  }
});
test('rejects malformed, oversized and changed blob contents', async () => {
  const valid = {sha: blobSha, encoding: 'base64', size: bytes.length, content: bytes.toString('base64')};
  for (const patch of [{sha: base}, {encoding: 'none'}, {size: 2 * 1024 * 1024},
    {size: 1}, {content: '!!!!'}, {content: Buffer.from('changed').toString('base64')}]) {
    const {get} = api(path => path.includes('/blobs/') ? {...valid, ...patch} : undefined);
    await assert.rejects(historicalWorkflow(get, identity));
  }
});
test('collects agreeing current jobs but never claims executed workflow or scope attestation', async () => {
  const paths = [];
  const r = await collectHistoricalSources(api().get, async path => { paths.push(path); return log(); }, evidence());
  assert.equal(r.observedAttempts, 1); assert.equal(r.acceptance, null);
  assert.equal(r.attempts[0].verified, false);
  assert.equal(r.attempts[0].source.workflow.text, content);
  assert.deepEqual(paths, [`repos/${repository}/actions/jobs/11/logs`, `repos/${repository}/actions/jobs/12/logs`]);
  assert.equal(JSON.stringify(r).includes('token:'), false);
});
test('missing, carried, runnerless, duplicate or foreign jobs do not fetch logs', async () => {
  for (const mutate of [e => e.attempts[0].jobs.pop(), e => e.attempts[0].jobs.push(job(13, 'gate')),
    e => {e.attempts[0].jobs[0].runner_id = 0;}, e => {e.attempts[0].jobs[0].run_attempt = 0;},
    e => {e.attempts[0].jobs[0].run_id = 9;}, e => {e.attempts[0].jobs[0].id = 12;}]) {
    const e = evidence(); mutate(e);
    const r = await collectHistoricalSources(api().get, async () => {throw Error('Must not fetch');}, e);
    assert.equal(r.attempts[0].status, 'missing-current-scope-or-gate');
  }
});
test('mismatched or unavailable checkout logs stay unknown without fetching Git objects', async () => {
  for (const getText of [async path => log(path.includes('/11/') ? merge : head),
    async () => {throw Error('sensitive API error');}, async () => 'unparseable']) {
    const {get, calls} = api();
    const r = await collectHistoricalSources(get, getText, evidence());
    assert.equal(r.observedAttempts, 0);
    assert.equal(r.attempts[0].status, 'unavailable-or-inconsistent-source');
    assert.ok(calls.every(path => path.endsWith('/actions/runs/7')));
    assert.equal(JSON.stringify(r).includes('sensitive'), false);
  }
});
test('stale source before or after collection removes plausible observations', async () => {
  for (const when of [1, 2]) {
    let reads = 0;
    const {get} = api(path => path.endsWith('/actions/runs/7') && ++reads === when ? {...run, run_attempt: 2} : undefined);
    const r = await collectHistoricalSources(get, async () => log(), evidence());
    assert.equal(r.observedAttempts, 0);
    assert.deepEqual(r.attempts, [{attempt: 1, status: 'stale-or-unavailable-run', verified: false}]);
  }
});
test('unverified or incomplete attempt inventory is rejected before requests', async () => {
  for (const mutate of [e => e.attempts.pop(), e => {e.attempts[0].jobsComplete = false;},
    e => {e.attempts[0].ownershipVerified = false;}, e => {e.run.run_attempt = 1001;}]) {
    const e = evidence(); mutate(e); let calls = 0;
    await assert.rejects(collectHistoricalSources(async () => { calls++; }, async () => '', e), /Invalid exact-run/);
    assert.equal(calls, 0);
  }
});
test('one unavailable attempt does not prevent independent later source observations', async () => {
  const e = evidence(); e.run.run_attempt = 2;
  e.attempts.push({metadata: {run_attempt: 2}, ownershipVerified: true, jobsComplete: true,
    jobs: [job(21, 'scope'), job(22, 'gate')].map(j => ({...j, run_attempt: 2}))});
  const {get} = api(path => path.endsWith('/actions/runs/7') ? e.run : undefined);
  const r = await collectHistoricalSources(get, async path => path.includes('/11/') ? '' : log(), e);
  assert.deepEqual(r.attempts.map(a => a.status), ['unavailable-or-inconsistent-source', 'observed']);
  assert.equal(r.expectedAttempts, 2); assert.equal(r.observedAttempts, 1);
});
test('immutable Git reads are reused across attempts but each job log is bound separately', async () => {
  const e = evidence(); e.run.run_attempt = 2;
  e.attempts.push({metadata: {run_attempt: 2}, ownershipVerified: true, jobsComplete: true,
    jobs: [job(21, 'scope'), job(22, 'gate')].map(j => ({...j, run_attempt: 2}))});
  const {get, calls} = api(path => path.endsWith('/actions/runs/7') ? e.run : undefined);
  const logs = [];
  const r = await collectHistoricalSources(get, async path => { logs.push(path); return log(); }, e);
  assert.equal(r.observedAttempts, 2); assert.equal(logs.length, 4);
  assert.equal(calls.filter(path => path.includes('/git/')).length, 5);
  assert.equal(r.attempts[1].logs[0].jobId, 21);
});
test('retained UTF-8 source preserves BOM bytes and refuses binary or invalid UTF-8', async () => {
  for (const data of [Buffer.from('\ufeff' + content), Buffer.from([0xff]), Buffer.from('bad\0text')]) {
    const hash = createHash('sha1').update(`blob ${data.length}\0`).update(data).digest('hex');
    const {get} = api(path => path.endsWith(`/trees/${workflowTree}`)
      ? {sha: workflowTree, truncated: false, tree: [{path: 'ci.yml', type: 'blob', mode: '100644', sha: hash}]}
      : path.includes('/blobs/') ? {sha: hash, encoding: 'base64', size: data.length, content: data.toString('base64')} : undefined);
    if (data[0] === 0xef) {
      assert.deepEqual(Buffer.from((await historicalWorkflow(get, identity)).workflow.text), data);
    } else await assert.rejects(historicalWorkflow(get, identity));
  }
});
