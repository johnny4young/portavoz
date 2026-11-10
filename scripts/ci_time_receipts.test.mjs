import test from 'node:test';
import assert from 'node:assert/strict';
import {bindUIArtifact, reconcileUIReceipts} from './ci_time_receipts.mjs';
const headSha = 'a'.repeat(40), zipHash = 'b'.repeat(64);
const first = 'PortavozUITests/LibraryUITests/testFirst';
const second = 'PortavozUITests/LibraryUITests/testSecond';
const later = 'PortavozUITests/LibraryUITests/testLater';
const identity = {repositoryId: 1, headRepositoryId: 1, runId: 2, headSha, attempt: 1};
function artifact() { return {id: 3, name: 'ui-receipts-2-1', expired: false, size_in_bytes: 100,
  digest: `sha256:${zipHash}`, workflow_run: {id: 2, head_sha: headSha, repository_id: 1, head_repository_id: 1}}; }
function documents() {
  const tests = [{identifier: 'LibraryUITests/testFirst()', result: 'Passed', durationSeconds: 1},
    {identifier: 'LibraryUITests/testSecond()', result: 'Passed', durationSeconds: 2}];
  return {lane: {schemaVersion: 1, locale: 'en', sha: headSha, attempt: 1, outcome: 'success',
    runtimeReceiptPresent: true, testDurationSeconds: 3, executed: structuredClone(tests), notExecuted: [],
    selection: {selected: [first, second], cut: [], deferred: 1, scopeUnknown: false}},
  runtime: {schemaVersion: 3, locale: 'en', measurementPolicy: 'xcresult-duration-with-activity-boundary-exclusions-v2',
    selectorCount: 2, caseCount: 2, testDurationSeconds: 3, tests, budgetStatus: 'passed', budgetViolations: []},
  execution: {schemaVersion: 1, locale: 'en', logSHA256: 'c'.repeat(64), classification: 'completed',
    failureSignature: null, selectorCount: 2, xcodebuildExitStatus: 0, runtimeReceiptPresent: true, resultBundlePresent: true},
  outcome: 'success\n'};
}
test('binds only the requested run, head, attempt and archive digest', () => {
  const r = bindUIArtifact({...artifact(), actor: 'not retained'}, identity, zipHash);
  assert.equal(r.metadataMatched, true); assert.equal(r.independentlyFetched, false);
  assert.equal(r.attempt, 1); assert.equal('actor' in r, false);
});
test('refuses expired, oversized, foreign or mismatched artifact metadata', () => {
  for (const patch of [{id: 0}, {name: 'ui-receipts-2-2'}, {expired: true}, {size_in_bytes: 1024 * 1024 + 1},
    {digest: `sha256:${'d'.repeat(64)}`}, {workflow_run: {...artifact().workflow_run, id: 4}},
    {workflow_run: {...artifact().workflow_run, head_sha: 'd'.repeat(40)}},
    {workflow_run: {...artifact().workflow_run, head_repository_id: 9}}]) {
    assert.throws(() => bindUIArtifact({...artifact(), ...patch}, identity, zipHash), /mismatch/);
  }
});
test('does not relabel a carried receipt as a later attempt', () => {
  assert.throws(() => bindUIArtifact(artifact(), {...identity, attempt: 2}, zipHash), /mismatch/);
  assert.throws(() => reconcileUIReceipts(documents(), {...identity, attempt: 2}), /identity/);
});
test('binds a fork only to the independently supplied head repository', () => {
  const a = artifact(); a.workflow_run.head_repository_id = 9;
  const bound = bindUIArtifact(a, {...identity, headRepositoryId: 9}, zipHash);
  assert.equal(bound.headRepositoryId, 9);
  assert.throws(() => bindUIArtifact(a, identity, zipHash), /mismatch/);
  assert.throws(() => bindUIArtifact(a, {...identity, headRepositoryId: undefined}, zipHash), /identity/);
});
test('reconciles exact identities while deferral names and acceptance remain unknown', () => {
  const r = reconcileUIReceipts(documents(), identity);
  assert.equal(r.selectedExecutionComplete, true); assert.equal(r.allRecordedCasesPassed, true);
  assert.equal(r.reportedExecutionCompleted, true); assert.equal(r.deferredCount, 1);
  assert.equal(r.deferredSelectors, null); assert.equal(r.preFitMatched, null);
  assert.equal(r.catalogueMatched, null); assert.equal(r.acceptance, null);
});
test('same count with a different selected identity is rejected', () => {
  const d = documents(); d.lane.selection.selected[1] = later;
  assert.throws(() => reconcileUIReceipts(d, identity), /not selected/);
});
test('lane and runtime must agree on identities, results and durations', () => {
  for (const patch of [{identifier: 'LibraryUITests/testLater()'}, {result: 'Failed'}, {durationSeconds: 2.001}]) {
    const d = documents(); Object.assign(d.lane.executed[1], patch);
    assert.throws(() => reconcileUIReceipts(d, identity), /disagree/);
  }
});
test('rejects duplicated selectors or executed cases instead of deduplicating coverage', () => {
  for (const change of [d => d.lane.selection.selected.push(first),
    d => d.lane.selection.cut.push(later, later), d => d.runtime.tests.push(d.runtime.tests[0]),
    d => d.lane.executed.push(d.lane.executed[0])]) {
    const d = documents(); change(d); assert.throws(() => reconcileUIReceipts(d, identity));
  }
});
test('partial execution remains partial and the exact missing selector must be named', () => {
  const d = documents(); d.lane.executed.pop(); d.runtime.tests.pop(); d.runtime.caseCount = 1;
  d.runtime.testDurationSeconds = d.lane.testDurationSeconds = 1; d.lane.notExecuted = [second];
  d.execution.classification = 'evidence-failure';
  assert.equal(reconcileUIReceipts(d, identity).selectedExecutionComplete, false);
  d.lane.notExecuted = [];
  assert.throws(() => reconcileUIReceipts(d, identity), /Not-executed/);
});
test('an empty invocation cannot become complete through vacuous all-passed checks', () => {
  const d = documents(); d.lane.executed = []; d.runtime.tests = []; d.runtime.caseCount = 0;
  d.runtime.testDurationSeconds = d.lane.testDurationSeconds = 0; d.lane.notExecuted = [first, second];
  d.execution.classification = 'evidence-failure';
  const r = reconcileUIReceipts(d, identity);
  assert.equal(r.selectedExecutionComplete, false); assert.equal(r.allRecordedCasesPassed, false);
  d.execution.classification = 'completed';
  assert.throws(() => reconcileUIReceipts(d, identity), /Completed/);
});
test('retains failed tests and failed execution instead of manufacturing a pass', () => {
  const d = documents(); d.lane.executed[0].result = d.runtime.tests[0].result = 'Failed';
  d.lane.outcome = d.outcome = 'failure'; d.execution.classification = 'test-failure'; d.execution.xcodebuildExitStatus = 65;
  const r = reconcileUIReceipts(d, identity);
  assert.equal(r.selectedExecutionComplete, true); assert.equal(r.allRecordedCasesPassed, false);
  assert.equal(r.reportedExecutionCompleted, false); assert.equal(r.reportedOutcome, 'failure');
});
test('runtime drift is reported without promoting it to performance acceptance', () => {
  const d = documents(); d.runtime.budgetStatus = 'failed'; d.runtime.budgetViolations = ['full suite: 3.000s > 2.000s'];
  const r = reconcileUIReceipts(d, identity);
  assert.equal(r.reportedRuntimeBudgetStatus, 'failed'); assert.equal(r.acceptance, null);
});
test('checks the pre-fit selected/cut partition and does not equate cuts with all deferrals', () => {
  const d = documents(); d.lane.selection.cut = [later]; d.lane.selection.deferred = 10;
  const r = reconcileUIReceipts(d, {...identity, preFitSelection: [first, second, later]});
  assert.equal(r.preFitMatched, true); assert.equal(r.cut.length, 1); assert.equal(r.deferredCount, 10);
  assert.equal(r.deferredSelectors, null);
  assert.throws(() => reconcileUIReceipts(d, {...identity, preFitSelection: [first, second]}), /Pre-fit/);
});
test('enumerates deferrals only against the supplied catalogue and checks its counts', () => {
  const r = reconcileUIReceipts(documents(), {...identity, catalogue: [first, second, later]});
  assert.deepEqual(r.deferredSelectors, [later]); assert.equal(r.catalogueMatched, true);
  assert.throws(() => reconcileUIReceipts(documents(), {...identity, catalogue: [first, second]}), /Deferred/);
  assert.throws(() => reconcileUIReceipts(documents(), {...identity, catalogue: [first, later]}), /outside/);
});
test('rejects head, locale, schema, outcome, counter and execution contradictions', () => {
  for (const change of [d => {d.lane.sha = 'd'.repeat(40);}, d => {d.runtime.locale = 'es';},
    d => {d.execution.schemaVersion = 2;}, d => {d.outcome = 'failure';}, d => {d.runtime.caseCount = true;},
    d => {d.execution.selectorCount = 3;}, d => {d.lane.selection.scopeUnknown = null;},
    d => {d.execution.xcodebuildExitStatus = 65;}, d => {d.execution.resultBundlePresent = false;},
    d => {d.execution.runtimeReceiptPresent = false;}, d => {d.lane.selection.cut = [first];},
    d => {d.runtime.budgetViolations = ['unexpected'];}]) {
    const d = documents(); change(d); assert.throws(() => reconcileUIReceipts(d, identity));
  }
});
test('rejects unsupported selector and numeric shapes before returning evidence', () => {
  for (const change of [d => {d.lane.selection.selected[0] = 'OtherTarget/LibraryUITests/testFirst';},
    d => {d.lane.selection.selected[0] = 'PortavozUITests/LibraryUITests';},
    d => {d.lane.executed[0].durationSeconds = NaN;}, d => {d.lane.selection.deferred = -1;},
    d => {d.lane.executed[0].result = 'arbitrary output';}]) {
    const d = documents(); change(d); assert.throws(() => reconcileUIReceipts(d, identity));
  }
});
