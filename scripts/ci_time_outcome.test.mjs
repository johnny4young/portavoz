import test from 'node:test';
import assert from 'node:assert/strict';
import {classifyOutcome, rerunRefusedStep, uiLaneFailedStep, uiReceiptsStep} from './ci_time_outcome.mjs';

// Synthetic normalized rows only: no workflow execution, logs, API or Python.
const productStep = 'Current-SDK build and selected test suite';
const gateStep = 'Require every lane the selection asked for';
const job = (name = 'build-and-test', extra = {}) => ({name, carried: false,
  conclusion: 'success', durationSeconds: 300, failedSteps: [], ...extra});
const failed = (name, ...steps) => job(name, {conclusion: 'failure', failedSteps: steps});
const outcome = (jobs, extra = {}) => classifyOutcome(jobs, {event: 'pull_request', ownershipVerified: true, jobsComplete: true,
  timeouts: {}, superseded: false, runCancelled: false, advisory: false, capacity: false, ...extra});

test('conservative difference: pagination and green observed jobs do not prove passed', () => {
  assert.equal(outcome([job(), job('interruption-controls', {conclusion: 'skipped', durationSeconds: null})]), null);
  assert.equal(outcome([job('scope'), job(), job('gate')]), null);
});

test('a positively classified build/test failure is product', () => {
  assert.equal(outcome([failed('build-and-test', productStep)]), 'product');
  assert.equal(outcome([failed('build-and-test', productStep, productStep)]), 'product');
});

test('setup, checkout, cache, toolchain and pinned-install failures are infrastructure', () => {
  for (const step of ['Set up job', 'Run actions/checkout@3d3c', 'Restore compatible Swift build state',
    'Verify fixed Tahoe toolchain', 'Install checksum-pinned XcodeGen 2.46.0']) {
    assert.equal(outcome([failed('build-and-test', step)]), 'infrastructure', step);
  }
});

test('a refused rerun is distinct from product and beats capacity/cancellation flags', () => {
  assert.equal(outcome([failed('ui-test-gate', rerunRefusedStep)]), 'rerun-refused');
  assert.equal(outcome([failed('ui-test-gate', rerunRefusedStep)],
    {capacity: true, advisory: true, runCancelled: true, superseded: true}), 'rerun-refused');
});

test('an explicit API timeout beats failure, advisory, capacity and supersession', () => {
  const failure = failed('build-and-test', productStep);
  const timeout = job('lint', {conclusion: 'timed_out'});
  for (const jobs of [[failure, timeout], [timeout, failure]]) {
    assert.equal(outcome(jobs, {advisory: true, capacity: true, runCancelled: true, superseded: true}), 'timeout');
  }
});

test('a cancelled job at the configured boundary is a timeout unless superseded', () => {
  for (const seconds of [1740, 1800]) {
    const jobs = [job('build-and-test', {conclusion: 'cancelled', durationSeconds: seconds})];
    assert.equal(outcome(jobs, {timeouts: {'build-and-test': 30}}), 'timeout');
    assert.equal(outcome(jobs, {timeouts: {'build-and-test': 30}, superseded: true}), 'superseded');
  }
  assert.equal(outcome([job(undefined, {conclusion: 'cancelled', durationSeconds: 1739})],
    {timeouts: {'build-and-test': 30}}), 'cancelled');
});

test('timeouts use a matrix base name and a timeout beats a sibling product failure', () => {
  const jobs = [failed('build-and-test', productStep),
    job('scoped-ui-tests (en)', {conclusion: 'cancelled', durationSeconds: 1260})];
  assert.equal(outcome(jobs, {timeouts: {'scoped-ui-tests': 22}}), 'timeout');
  assert.equal(outcome(jobs, {timeouts: {'scoped-ui-tests': 22}, superseded: true}), 'product');
});

test('a generic UI lane failure needs proven provenance; an independent product step stays product', () => {
  const jobs = [failed('ui-tests', uiLaneFailedStep), failed('gate', gateStep)];
  assert.equal(outcome(jobs, {advisory: true}), null);
  assert.equal(outcome(jobs), null);
  assert.equal(outcome([failed('ui-tests', uiLaneFailedStep, productStep)], {advisory: true}), 'product');
});

test('failed receipt collection takes priority over other gate steps', () => {
  assert.equal(outcome([failed('gate', uiReceiptsStep, gateStep)]), 'infrastructure');
  assert.equal(outcome([failed('gate', gateStep)]), 'product');
});

test('a failed gate takes the cause of its cancelled need, including legacy matrix jobs', () => {
  const jobs = [job('scoped-ui-tests (en)', {conclusion: 'cancelled'}),
    failed('ui-test-gate', 'Require selected evidence and allow an honest no-UI skip')];
  assert.equal(outcome(jobs, {superseded: true}), 'superseded');
  assert.equal(outcome(jobs, {timeouts: {'scoped-ui-tests': 22}}), 'cancelled');
  // An obsolete gate step can be ignored only when a known need supplies the cause.
  assert.equal(outcome(jobs.slice(1)), null);
});

test('a failed gate takes its non-gate failure cause rather than its own product step', () => {
  const gate = failed('ui-test-gate', gateStep);
  assert.equal(outcome([failed('build-ui-products', 'Install checksum-pinned XcodeGen 2.46.0'), gate]), 'infrastructure');
  assert.equal(outcome([failed('build-ui-products', 'Build the UI host and runner once'), gate]), 'product');
  // Conservative difference from legacy: this retired name is not in the
  // current positive step policy, so it must not become product by exclusion.
  assert.equal(outcome([failed('build-ui-products', 'Build selected UI products once'), gate]), null);
});

test('product failure beats a cancelled sibling and capacity/advisory evidence', () => {
  const jobs = [failed('build-and-test', productStep), job('lint', {conclusion: 'cancelled'})];
  assert.equal(outcome(jobs, {capacity: true, advisory: true, runCancelled: true, superseded: true}), 'product');
});

test('unproven capacity hints cannot classify cancellation, including superseded attempts', () => {
  const jobs = [job(undefined, {conclusion: 'cancelled', durationSeconds: null})];
  assert.equal(outcome(jobs, {capacity: true}), null);
  assert.equal(outcome(jobs, {capacity: true, superseded: true}), null);
  assert.equal(outcome([], {capacity: true, runCancelled: true}), null);
});

test('early cancellation is superseded only with explicit newer-run evidence', () => {
  const jobs = [job(undefined, {conclusion: 'cancelled'})];
  assert.equal(outcome(jobs, {timeouts: {'build-and-test': 30}}), 'cancelled');
  assert.equal(outcome(jobs, {timeouts: {'build-and-test': 30}, superseded: true}), 'superseded');
  assert.equal(outcome(jobs, {advisory: true, timeouts: {'build-and-test': 30}}), 'cancelled');
  assert.equal(outcome([], {runCancelled: true}), 'cancelled');
  assert.equal(outcome([], {runCancelled: true, superseded: true}), 'superseded');
});

test('an unproven hosted advisory cannot classify a successful gate', () => {
  assert.equal(outcome([job('ui-test-gate')], {advisory: true}), null);
  // A legacy gate alone does not prove selection and all required job states.
  assert.equal(outcome([job('ui-test-gate')]), null);
});

test('alert is excluded regardless of its conclusion, duration or failed steps', () => {
  for (const extra of [{conclusion: 'failure', failedSteps: [productStep]},
    {conclusion: 'timed_out'}, {conclusion: 'future-conclusion'},
    {conclusion: 'cancelled', durationSeconds: 999999}]) {
    assert.equal(outcome([failed('build-and-test', productStep), job('alert', {...extra, carried: undefined})]), 'product');
  }
  assert.equal(outcome([failed('build-and-test', 'Set up job'), failed('alert', productStep)]), 'infrastructure');
  assert.equal(outcome([job('alert')]), null);
});

test('push uses its release blocking list, not the pull request UI gates', () => {
  assert.equal(outcome([failed('build-and-test', 'Set up job'), job('ios-portability'), failed('gate', gateStep)],
    {event: 'push'}), 'infrastructure');
  assert.equal(outcome([failed('ios-portability', 'Compile transport-neutral iOS 26 surface')], {event: 'push'}), 'product');
  assert.equal(outcome([job()], {event: 'push', superseded: true}), null);
});

test('reused jobs say nothing about this attempt and cannot invent its outcome', () => {
  const reused = job(undefined, {carried: true, conclusion: 'timed_out'});
  assert.equal(outcome([failed('lint', 'Set up job'), reused]), 'infrastructure');
  assert.equal(outcome([reused]), null);
});

test('conservative difference: empty or incomplete evidence is UNKNOWN, not legacy passed', () => {
  assert.equal(outcome([]), null);
  assert.equal(outcome([job()], {jobsComplete: false}), null);
  assert.equal(outcome([failed('build-and-test', productStep)], {jobsComplete: false}), null);
  assert.equal(outcome([job()], {jobsComplete: undefined}), null);
  assert.equal(classifyOutcome([job()]), null);
  assert.equal(classifyOutcome(null), null);
  assert.equal(classifyOutcome([job()], null), null);
});

test('conservative difference: missing failed-step evidence is UNKNOWN, not legacy infrastructure', () => {
  for (const failedSteps of [undefined, null, [], {}, 'Set up job']) {
    assert.equal(outcome([job(undefined, {conclusion: 'failure', failedSteps})]), null);
  }
});

test('conservative difference: unknown steps are UNKNOWN, not legacy product by exclusion', () => {
  for (const step of ['New build step not yet classified', '', null, 42, {}]) {
    assert.equal(outcome([failed('build-and-test', step)]), null);
    assert.equal(outcome([failed('build-and-test', productStep, step)]), null);
    assert.equal(outcome([failed('gate', uiReceiptsStep, step)]), null);
  }
  // A recognized sibling failure does not fill another causal job's missing steps.
  assert.equal(outcome([failed('build-and-test', productStep), failed('lint')]), null);
});

test('conservative difference: a refusal plus infrastructure alone does not prove product', () => {
  assert.equal(outcome([failed('build-and-test', rerunRefusedStep, 'Set up job')]), null);
  assert.equal(outcome([failed('build-and-test', rerunRefusedStep, productStep)]), 'product');
});

test('conservative difference: missing or unrecognized conclusions never infer success/product', () => {
  for (const conclusion of [undefined, null, '', 'neutral', 'action_required', 'stale', 'in_progress', 'future-result', {}]) {
    const unknown = job('lint', {conclusion});
    assert.equal(outcome([unknown]), null);
    assert.equal(outcome([job(), unknown]), null);
    assert.equal(outcome([failed('build-and-test', productStep), unknown]), null);
  }
});

test('conservative difference: unknown job policy and unproven attempt ownership are UNKNOWN', () => {
  for (const unknown of [job('future-job'), job(undefined, {name: null}), null,
    job(undefined, {carried: undefined}), job(undefined, {carried: 'false'})]) {
    assert.equal(outcome([job('lint'), unknown]), null);
  }
  assert.equal(outcome([job()], {event: 'workflow_dispatch'}), null);
});

test('unknown flags, timeout configuration or cancellation duration cannot make a claim', () => {
  for (const flag of ['superseded', 'runCancelled', 'advisory', 'capacity']) {
    for (const value of [undefined, null, 0, 'false']) assert.equal(outcome([job()], {[flag]: value}), null);
  }
  for (const timeouts of [undefined, null, [], {'build-and-test': '30'}, {lint: 0}, {lint: -1}, {lint: Infinity}]) {
    assert.equal(outcome([job()], {timeouts}), null);
  }
  for (const durationSeconds of [undefined, NaN, Infinity, -1, '1800']) {
    assert.equal(outcome([job(undefined, {conclusion: 'cancelled', durationSeconds})],
      {timeouts: {'build-and-test': 30}}), null);
  }
});

test('classification does not mutate synthetic job evidence or option objects', () => {
  const steps = Object.freeze([productStep]);
  const jobs = Object.freeze([Object.freeze(failed('build-and-test', ...steps))]);
  Object.freeze(jobs[0].failedSteps);
  const options = Object.freeze({event: 'pull_request', ownershipVerified: true, jobsComplete: true, timeouts: Object.freeze({}),
    superseded: false, runCancelled: false, advisory: false, capacity: false});
  assert.equal(classifyOutcome(jobs, options), 'product');
  assert.deepEqual(jobs[0].failedSteps, [productStep]);
});

// Unlike legacy, an unproven timeout must not be relabeled cancellation.
test('conservative difference: cancellation needs a known limit and measured duration', () => {
  const cancelled = durationSeconds => job(undefined, {conclusion: 'cancelled', durationSeconds});
  assert.equal(outcome([cancelled(1800)]), null);
  assert.equal(outcome([cancelled(null)], {timeouts: {'build-and-test': 30}}), null);
  assert.equal(outcome([cancelled(undefined)], {timeouts: {'build-and-test': 30}}), null);
  assert.equal(outcome([cancelled(300)], {timeouts: {'build-and-test': 30}}), 'cancelled');
  assert.equal(outcome([cancelled(1800)], {superseded: true}), 'superseded');
  assert.equal(outcome([cancelled(null)], {superseded: true}), 'superseded');
  assert.equal(outcome([cancelled(null)], {capacity: true}), null);
  assert.equal(outcome([cancelled(null), failed('lint', productStep)]), null);
  assert.equal(outcome([cancelled(null), failed('lint', productStep)], {superseded: true}), 'product');
  assert.equal(outcome([cancelled(null), job('lint', {conclusion: 'timed_out'})]), 'timeout');
  assert.equal(outcome([cancelled(1800)], {advisory: true}), null);
});

test('conservative difference: skipped, gateless or scope-unknown attempts never prove passed', () => {
  const names = ['repository-hygiene', 'lint', 'scope', 'build-and-test', 'gate'];
  assert.equal(outcome(names.map(name => job(name, {conclusion: 'skipped'}))), null);
  assert.equal(outcome([job()]), null);
  assert.equal(outcome(names.filter(name => name !== 'gate').map(name => job(name))), null);
  // Even a green current gate plus green jobs cannot attest to which optional
  // lanes were required. This row-only slice deliberately leaves passed UNKNOWN
  // until a future integration supplies verified gate and selection evidence.
  assert.equal(outcome(names.map(name => job(name))), null);
  assert.equal(outcome(['repository-hygiene', 'lint', 'build-and-test', 'ios-portability']
    .map(name => job(name)), {event: 'push'}), null);
});

test('an explicit eligible timeout survives an unknown sibling without claiming inventory completeness', () => {
  const timeout = job('lint', {conclusion: 'timed_out'});
  const unknown = job(undefined, {conclusion: null});
  assert.equal(outcome([unknown, timeout]), 'timeout');
  assert.equal(outcome([timeout, unknown]), 'timeout');
  assert.equal(outcome([unknown, timeout], {jobsComplete: false}), 'timeout');
  assert.equal(outcome([unknown, {...timeout, carried: true}]), null);
  assert.equal(outcome([unknown, {...timeout, name: 'alert'}]), null);
});

test('receipt download is an independent gate failure, not merely its cancelled need', () => {
  const cancelled = job('ui-tests', {conclusion: 'cancelled'});
  const gate = failed('gate', uiReceiptsStep, gateStep);
  assert.equal(outcome([cancelled, gate], {timeouts: {'ui-tests': 22}}), 'infrastructure');
  assert.equal(outcome([cancelled, gate], {timeouts: {'ui-tests': 22}, superseded: true}), 'infrastructure');
  assert.equal(outcome([cancelled, failed('gate', uiReceiptsStep, 'Unknown gate step')]), null);
  // Two independently failed lanes with different causes are not collapsed
  // into one gate-derived cause in this conservative slice.
  assert.equal(outcome([failed('build-and-test', productStep), gate]), null);
});

test('unproven capacity/advisory flags cannot establish infrastructure or erase a proven failure', () => {
  assert.equal(outcome([], {capacity: true}), null);
  assert.equal(outcome([], {advisory: true}), null);
  assert.equal(outcome([failed('ui-tests', uiLaneFailedStep, 'Set up job')], {advisory: true}), null);
  assert.equal(outcome([failed('build-and-test', productStep)], {capacity: true, advisory: true}), 'product');
  assert.equal(outcome([failed('build-and-test', 'Set up job')], {capacity: true, advisory: true}), 'infrastructure');
});


test('a timeout requires caller attestation of exact attempt ownership', () => {
  const timed = [job('lint', {conclusion: 'timed_out'})];
  assert.equal(classifyOutcome(timed, {event: 'pull_request'}), null);
  assert.equal(classifyOutcome(timed, {event: 'pull_request', ownershipVerified: false}), null);
  assert.equal(classifyOutcome(timed, {event: 'pull_request', ownershipVerified: true}), 'timeout');
});


test('a gate setup failure is not erased by a cancelled sibling', () => {
  const cancelled = job('lint', {conclusion: 'cancelled', durationSeconds: 300});
  for (const superseded of [false, true]) {
    assert.equal(outcome([cancelled, failed('gate', 'Set up job')],
      {timeouts: {lint: 30}, superseded}), 'infrastructure');
    assert.equal(outcome([cancelled, failed('gate', gateStep, 'Set up job')],
      {timeouts: {lint: 30}, superseded}), 'infrastructure');
  }
});

test('an unknown gate failure is never erased by a cancelled sibling', () => {
  const cancelled = job('lint', {conclusion: 'cancelled', durationSeconds: 300});
  for (const superseded of [false, true]) {
    assert.equal(outcome([cancelled, failed('gate', 'New gate integrity check')],
      {timeouts: {lint: 30}, superseded}), null);
    assert.equal(outcome([cancelled, job('gate', {conclusion: 'failure', failedSteps: []})],
      {timeouts: {lint: 30}, superseded}), null);
  }
});

test('only known dependency aggregation can defer gate cause to a failed sibling', () => {
  const productFailure = failed('build-and-test', productStep);
  for (const superseded of [false, true]) {
    assert.equal(outcome([productFailure, failed('gate', gateStep)], {superseded}), 'product');
    assert.equal(outcome([productFailure, failed('gate', 'Set up job')], {superseded}), null);
    assert.equal(outcome([productFailure, failed('gate', 'New gate integrity check')], {superseded}), null);
  }
});


test('unknown timeout evidence cannot be hidden by a lower-priority failure', () => {
  const unknownDuration = job('lint', {conclusion: 'cancelled', durationSeconds: null});
  const knownDuration = job('lint', {conclusion: 'cancelled', durationSeconds: 300});
  for (const ownFailure of [failed('gate', 'Set up job'), failed('build-and-test', productStep)]) {
    assert.equal(outcome([unknownDuration, ownFailure], {timeouts: {lint: 30}}), null);
    assert.equal(outcome([knownDuration, ownFailure]), null);
    assert.notEqual(outcome([knownDuration, ownFailure], {timeouts: {lint: 30}}), null);
    assert.notEqual(outcome([unknownDuration, ownFailure], {superseded: true}), null);
  }
});
