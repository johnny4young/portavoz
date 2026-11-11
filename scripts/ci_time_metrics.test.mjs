import test from 'node:test';
import assert from 'node:assert/strict';
import { measureAttempt, nearestRank, summarizeAttempts as rawAttempts, summarizeViews as rawViews } from './ci_time_metrics.mjs';

const normalized = rows => rows.map((row, i) => ({runId: i + 1, attemptNumber: 1, ordinal: 1, outcome: 'passed', ...row, attemptStartedAt: row.attemptStartedAt ?? row.createdAt}));
const summarizeAttempts = rows => rawAttempts(normalized(rows), {inventoryComplete: true});
const summarizeViews = rows => rawViews(normalized(rows), {inventoryComplete: true});
const at = seconds => new Date(Date.UTC(2026, 10, 1) + seconds * 1000).toISOString();
let nextJobId = 1;
const job = (name, start, end, extra = {}) => ({ id: nextJobId++, name, workflow: 'ci.yml', required: true,
  carried: false, runnerAssigned: true, conclusion: 'success', runId: 123, attemptNumber: 1, startedAt: at(start), completedAt: at(end), ...extra });
const attempt = (extra = {}) => ({ head: 'a', runId: 123, attemptNumber: 1, ordinary: true, outcome: 'passed', createdAt: at(0), attemptStartedAt: at(0),
  jobsComplete: true, scopeEvidence: {verified: true, uiRequired: false, interruptionRequired: false, iosRequired: false}, jobs: [job('repository-hygiene', 1, 2), job('lint', 1, 2), job('scope', 1, 2), job('build-and-test', 5, 25), job('gate', 25, 27), ...['ui-tests', 'interruption', 'ios-portability'].map(name => job(name, 0, 0, {required: false, runnerAssigned: false, conclusion: 'skipped', startedAt: null, completedAt: null}))], ...extra });

test('measures from workflow creation to the exact gate, not the last job', () => {
  const a = attempt();
  const value = measureAttempt({...a, jobs: [...a.jobs, job('alert', 27, 80, {required: false})]});
  assert.equal(value.execution, 20);
  assert.equal(value.total, 27);
});
test('does not substitute missing, carried, foreign, or duplicate gates', () => {
  const a = attempt();
  assert.equal(measureAttempt(a).total, 27);
  for (const jobs of [a.jobs.filter(j => j.name !== 'gate'),
    a.jobs.map(j => j.name === 'gate' ? {...j, carried: true} : j),
    a.jobs.map(j => j.name === 'gate' ? {...j, workflow: 'other.yml'} : j),
    [...a.jobs, job('gate', 25, 27)]]) assert.equal(measureAttempt({...a, jobs}).total, null);
});
test('missing, reversed or out-of-window required timestamps make execution unknown', () => {
  const a = attempt();
  assert.equal(measureAttempt(a).execution, 20);
  for (const patch of [{startedAt: null}, {startedAt: at(26), completedAt: at(25)},
    {startedAt: at(-2), completedAt: at(-1)}, {completedAt: at(26)}]) {
    const jobs = a.jobs.map(j => j.name === 'build-and-test' ? {...j, ...patch} : j);
    assert.equal(measureAttempt({...a, jobs}).execution, null);
  }
});
test('nearest-rank does not interpolate and rejects invalid values', () => {
  assert.equal(nearestRank([1, 100, 2, 3], 0.95), 100);
  assert.equal(nearestRank([], 0.95), null);
  assert.throws(() => nearestRank([1, NaN], 0.95));
});
test('only ordinary heads contribute to exact seven-day window', () => {
  const rows = Array.from({length: 30}, (_, i) => ({head: String(i), ordinary: true, outcome: 'passed',
    createdAt: at(i * 100), execution: 1, total: 1}));
  assert.equal(summarizeAttempts([...rows, {head: 'exempt', ordinary: false, createdAt: at(-8 * 86400)}]).windowMet, false);
  const spread = seconds => rows.map((row, i) => ({...row, createdAt: at(Math.floor(i * seconds / 29))}));
  assert.equal(summarizeAttempts(spread(7 * 86400 - 1)).windowMet, false);
  assert.equal(summarizeAttempts(spread(7 * 86400)).windowMet, true);
});
test('incomplete data is visible and cannot be called within limit', () => {
  const rows = [{head: 'a', ordinary: true, createdAt: at(0), execution: 100, total: 100},
    {head: 'b', ordinary: true, createdAt: at(1), execution: null, total: null, outcome: 'timeout'}];
  const result = summarizeAttempts(rows);
  assert.equal(result.attempts, 2);
  assert.deepEqual([result.execution.expected, result.execution.n, result.execution.observedP95WithinLimit], [2, 1, null]);
  assert.deepEqual([result.total.expected, result.total.n, result.total.observedP95WithinLimit], [2, 1, null]);
});
test('keeps failures, timeouts and superseded attempts visible', () => {
  const rows = ['passed', 'failure', 'timeout', 'superseded'].map((outcome, i) => ({head: String(i),
    ordinary: true, outcome, createdAt: at(i), execution: i + 1, total: i + 1}));
  assert.equal(summarizeAttempts(rows).attempts, 4);
  assert.equal(summarizeAttempts(rows).execution.max, 4);
});

test('a later rerun does not stretch the distinct-head window', () => {
  const rows = Array.from({length: 30}, (_, i) => ({head: String(i), ordinary: true, outcome: 'passed',
    createdAt: at(i * 100), execution: 1, total: 1}));
  rows.push({...rows[0], ordinal: 2, createdAt: at(8 * 86400)});
  assert.equal(summarizeAttempts(rows).windowMet, false);
});
test('invalid date and gate timestamps produce unknown values', () => {
  assert.equal(measureAttempt(attempt({createdAt: '2026-02-30T00:00:00Z'})).total, null);
  const a = attempt();
  const jobs = a.jobs.map(j => j.name === 'gate' ? {...j, startedAt: at(28)} : j);
  assert.equal(measureAttempt({...a, jobs}).total, null);
});

test('attempt, first-head, and last-head views are separate and explicit', () => {
  const rows = [{head: 'a', runId: 99, attemptNumber: 1, ordinal: 1, ordinary: true, createdAt: at(0), execution: 10, total: 20},
    {head: 'a', runId: 99, attemptNumber: 2, ordinal: 2, ordinary: true, createdAt: at(0), attemptStartedAt: at(2), execution: 20, total: 30},
    {head: 'b', ordinal: 1, ordinary: true, createdAt: at(1), execution: 5, total: 7}];
  const result = summarizeViews(rows);
  assert.equal(result.all.attempts, 3);
  assert.equal(result.first.attempts, 2);
  assert.equal(result.first.total.max, 20);
  assert.equal(result.last.total.max, 30);
});
test('head views are unknown when ordinal is absent or duplicated', () => {
  const row = {head: 'a', ordinal: 1, ordinary: true, createdAt: at(0), execution: 10, total: 20};
  assert.equal(summarizeViews([row, {...row}]).first, null);
  assert.equal(summarizeViews([{...row, ordinal: null}]).orderingComplete, false);
});

test('requires matching job and attempt identity and complete classification', () => {
  const a = attempt();
  assert.equal(measureAttempt(a).total, 27);
  const wrongAttempt = a.jobs.map(j => j.name === 'gate' ? {...j, attemptNumber: 2} : j);
  const unclassified = a.jobs.map(j => j.name === 'lint' ? {...j, required: null} : j);
  assert.equal(measureAttempt({...a, jobs: wrongAttempt}).total, null);
  assert.equal(measureAttempt({...a, jobs: unclassified}).execution, null);
});
test('unclassified cohort cannot make a partial p95 or window appear valid', () => {
  const row = {head: 'a', ordinal: 1, ordinary: true, createdAt: at(0), execution: 10, total: 20};
  const result = summarizeViews([row, {...row, head: 'b', ordinary: null}]);
  assert.equal(result.all.scopeUnknown, 1);
  assert.equal(result.all.windowMet, null);
  assert.equal(result.all.total.observedP95WithinLimit, null);
  assert.equal(result.first, null);
});

test('missing inventory or mandatory job prevents any timing claim', () => {
  assert.equal(measureAttempt(attempt({jobsComplete: false})).execution, null);
  assert.equal(measureAttempt(attempt({jobs: [job('gate', 1, 2)]})).execution, null);
  assert.equal(measureAttempt(attempt({jobsComplete: false})).total, null);
});
test('duplicate identities or incomplete page inventory prevent a green claim', () => {
  const row = {head: 'a', ordinal: 1, runId: 123, attemptNumber: 1, ordinary: true,
    outcome: 'passed', createdAt: at(0), attemptStartedAt: at(0), execution: 10, total: 20};
  assert.equal(rawAttempts([row], {inventoryComplete: true}).total.observedP95WithinLimit, true);
  assert.equal(rawAttempts([row, row], {inventoryComplete: true}).total.observedP95WithinLimit, null);
  assert.equal(rawAttempts([row]).total.observedP95WithinLimit, null);
});
test('a missing earlier ordinal prevents first and last head views', () => {
  const row = {head: 'a', ordinal: 2, ordinary: true, createdAt: at(0), execution: 10, total: 20};
  assert.equal(summarizeViews([row]).orderingComplete, false);
});
test('head views reuse the complete inventory window, not a later rerun', () => {
  const rows = Array.from({length: 30}, (_, i) => ({head: String(i), ordinal: 1, ordinary: true,
    createdAt: at(i * 100), execution: 1, total: 1}));
  rows.push({...rows[0], ordinal: 2, createdAt: at(8 * 86400)});
  const result = summarizeViews(rows);
  assert.equal(result.all.windowMet, false);
  assert.equal(result.last.windowMet, false);
});
test('unknown outcome cannot be counted as complete evidence', () => {
  const row = {head: 'a', ordinal: 1, runId: 123, attemptNumber: 1, ordinary: true,
    outcome: 'passed', createdAt: at(0), attemptStartedAt: at(0), execution: 10, total: 20};
  assert.equal(rawAttempts([row], {inventoryComplete: true}).total.observedP95WithinLimit, true);
  row.outcome = null;
  assert.equal(rawAttempts([row], {inventoryComplete: true}).total.observedP95WithinLimit, null);
});

test('missing lane-classification evidence makes measurements unknown', () => {
  assert.equal(measureAttempt(attempt({scopeEvidence: null})).execution, null);
  assert.equal(measureAttempt(attempt({scopeEvidence: null})).total, 27);
});
test('missing head or a hole in attempt inventory cannot assert a p95', () => {
  const base = {head: 'a', ordinal: 1, runId: 123, attemptNumber: 1, ordinary: true,
    outcome: 'passed', createdAt: at(0), attemptStartedAt: at(0), execution: 10, total: 20};
  assert.equal(rawAttempts([base], {inventoryComplete: true}).total.observedP95WithinLimit, true);
  assert.equal(rawAttempts([{...base, head: null}], {inventoryComplete: true}).total.observedP95WithinLimit, null);
  assert.equal(rawAttempts([{...base, ordinal: 2}], {inventoryComplete: true}).total.observedP95WithinLimit, null);
});

test('conditional required lanes must be present and classified as required', () => {
  const a = attempt();
  const scopeEvidence = {...a.scopeEvidence, uiRequired: true};
  assert.equal(measureAttempt({...a, scopeEvidence}).execution, null);
  const ui = job('ui-tests', 5, 15);
  assert.equal(measureAttempt({...a, scopeEvidence, jobs: [...a.jobs.filter(j => j.name !== 'ui-tests'), {...ui, required: false}]}).execution, null);
  assert.equal(measureAttempt({...a, scopeEvidence, jobs: [...a.jobs.filter(j => j.name !== 'ui-tests'), ui]}).execution, 20);
});
test('carried jobs must originate in an earlier attempt of the same run', () => {
  const a = attempt();
  const jobs = a.jobs.map(j => j.name === 'gate' ? {...j, attemptNumber: 2, startedAt: at(27), completedAt: at(29)} :
    j.runnerAssigned ? {...j, carried: true} : {...j, attemptNumber: 2});
  assert.equal(measureAttempt({...a, attemptNumber: 2, attemptStartedAt: at(26), jobs}).total, 29);
  const forged = jobs.map(j => j.name === 'lint' ? {...j, attemptNumber: 2} : j);
  const result = measureAttempt({...a, attemptNumber: 2, attemptStartedAt: at(26), jobs: forged});
  assert.equal(result.execution, null);
  assert.equal(result.total, 29);
});
test('run attempt ordering must match ordinals and include the first attempt', () => {
  const a = {head: 'a', runId: 5, attemptNumber: 1, ordinal: 1, ordinary: true,
    outcome: 'passed', createdAt: at(0), attemptStartedAt: at(0), execution: 10, total: 20};
  const b = {...a, attemptNumber: 2, ordinal: 2, attemptStartedAt: at(3)};
  assert.equal(rawViews([a, b], {inventoryComplete: true}).orderingComplete, true);
  assert.equal(rawViews([{...a, ordinal: 2}, {...b, ordinal: 1}], {inventoryComplete: true}).orderingComplete, false);
  assert.equal(rawViews([{...b, ordinal: 1}], {inventoryComplete: true}).orderingComplete, false);
});

test('orders reruns by attempt start, not original workflow creation', () => {
  const row = {head: 'a', ordinary: true, outcome: 'passed', execution: 1, total: 1};
  const rows = [{...row, runId: 1, attemptNumber: 1, ordinal: 1, createdAt: at(0), attemptStartedAt: at(0)},
    {...row, runId: 2, attemptNumber: 1, ordinal: 2, createdAt: at(10), attemptStartedAt: at(10)},
    {...row, runId: 1, attemptNumber: 2, ordinal: 3, createdAt: at(0), attemptStartedAt: at(20)}];
  assert.equal(rawViews(rows, {inventoryComplete: true}).orderingComplete, true);
  const incorrectlyOrdered = [rows[0], {...rows[1], ordinal: 3}, {...rows[2], ordinal: 2}];
  assert.equal(rawViews(incorrectlyOrdered, {inventoryComplete: true}).orderingComplete, false);
  assert.equal(rawViews([{...rows[0], attemptStartedAt: at(10)}, {...rows[1], attemptStartedAt: at(10)}], {inventoryComplete: true}).orderingComplete, false);
});

test('contradictory scope and actually-run unselected lanes cannot produce execution', () => {
  const a = attempt();
  assert.equal(measureAttempt({...a, scopeEvidence: {...a.scopeEvidence, interruptionRequired: true}}).execution, null);
  for (const name of ['ui-tests', 'interruption', 'ios-portability']) {
    const jobs = a.jobs.map(j => j.name === name ? {...j, runnerAssigned: true, conclusion: 'success',
      startedAt: at(1), completedAt: at(24)} : j);
    assert.equal(measureAttempt({...a, jobs}).execution, null);
  }
});
test('exact gate duration remains measurable if a required lane never started', () => {
  const a = attempt();
  const jobs = a.jobs.map(j => j.name === 'build-and-test' ? {...j, startedAt: null, completedAt: null} : j);
  const result = measureAttempt({...a, jobs});
  assert.equal(result.execution, null);
  assert.equal(result.total, 27);
});

test('a selected job skipped without a runner never counts as execution', () => {
  const a = attempt();
  for (const name of ['build-and-test', 'ui-tests']) {
    const scopeEvidence = {...a.scopeEvidence, uiRequired: name === 'ui-tests'};
    const jobs = a.jobs.map(j => j.name === name ? {...j, required: true, runnerAssigned: false,
      conclusion: 'skipped', startedAt: at(10), completedAt: at(10)} : j);
    const result = measureAttempt({...a, scopeEvidence, jobs});
    assert.equal(result.execution, null);
    assert.equal(result.total, 27);
  }
});

test('a skipped gate or a causal contradiction cannot produce a total', () => {
  const a = attempt();
  assert.equal(measureAttempt(a).total, 27);
  const skipped = a.jobs.map(j => j.name === 'gate' ? {...j, runnerAssigned: false, conclusion: 'skipped'} : j);
  assert.equal(measureAttempt({...a, jobs: skipped}).total, null);
  const impossible = a.jobs.map(j => j.name === 'build-and-test' ? {...j, completedAt: at(26)} : j);
  assert.equal(measureAttempt({...a, jobs: impossible}).total, null);
});

test("mixed eligibility within a head cannot silently redefine its last attempt", () => {
  const first = {head: "same", runId: 91, attemptNumber: 1, ordinal: 1, ordinary: true,
    outcome: "passed", createdAt: at(0), attemptStartedAt: at(0), execution: 1, total: 1};
  const laterExempt = {...first, attemptNumber: 2, ordinal: 2, ordinary: false,
    attemptStartedAt: at(60), execution: 999, total: 999};
  const result = rawViews([first, laterExempt], {inventoryComplete: true});
  assert.equal(result.all.attempts, 1);
  assert.equal(result.first, null);
  assert.equal(result.last, null);
  assert.equal(result.orderingComplete, false);
  const reverse = rawViews([{...first, ordinary: false}, {...laterExempt, ordinary: true}],
    {inventoryComplete: true});
  assert.equal(reverse.first, null);
  assert.equal(reverse.last, null);
  assert.equal(reverse.orderingComplete, false);
});

test("nonpositive run or job IDs cannot establish measurement evidence", () => {
  const a = attempt();
  const invalidRun = {...a, runId: 0, jobs: a.jobs.map(j => ({...j, runId: 0}))};
  assert.equal(measureAttempt(invalidRun).total, null);
  assert.equal(measureAttempt(invalidRun).execution, null);
  const invalidJobs = {...a, jobs: a.jobs.map((j, i) => ({...j, id: -i - 1}))};
  assert.equal(measureAttempt(invalidJobs).total, null);
  const row = {head: "a", runId: 0, attemptNumber: 1, ordinal: 1, ordinary: true,
    outcome: "passed", createdAt: at(0), attemptStartedAt: at(0), execution: 1, total: 1};
  assert.equal(rawAttempts([row], {inventoryComplete: true}).total.observedP95WithinLimit, null);
});
