// Reconcile supplied compact UI evidence; this does not replace the hosted gate.
import {createHash} from 'node:crypto';
const positive = value => Number.isSafeInteger(value) && value > 0;
const natural = value => Number.isSafeInteger(value) && value >= 0;
const finite = value => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const sha = value => typeof value === 'string' && /^[a-f0-9]{40}$/.test(value);
const hash = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const selector = /^PortavozUITests\/[A-Za-z_][A-Za-z0-9_]*\/test[A-Za-z0-9_]+$/;
const identifier = /^[A-Za-z_][A-Za-z0-9_]*\/test[A-Za-z0-9_]+\(\)$/;
const runtimeKey = value => value.split('/').slice(1).join('/') + '()';
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function selected(values, label) {
  if (!Array.isArray(values) || values.length > 5000 || !values.every(v => typeof v === 'string' &&
    v.length <= 512 && selector.test(v)) || new Set(values).size !== values.length) throw new Error(`Invalid ${label}`);
  return values.slice().sort();
}
function cases(values) {
  if (!Array.isArray(values) || values.length > 5000 || values.some(row => !row ||
    typeof row.identifier !== 'string' || row.identifier.length > 512 || !identifier.test(row.identifier) ||
    !['Passed', 'Failed', 'Skipped'].includes(row.result) || !finite(row.durationSeconds))) {
    throw new Error('Invalid executed cases');
  }
  if (new Set(values.map(row => row.identifier)).size !== values.length) throw new Error('Duplicate executed case');
  return values.map(row => ({identifier: row.identifier, result: row.result, durationSeconds: row.durationSeconds}))
    .sort((a, b) => a.identifier.localeCompare(b.identifier, 'en'));
}

export function bindUIArtifact(artifact, identity, archiveSha256) {
  const {repositoryId, headRepositoryId, runId, headSha, attempt} = identity;
  if (!positive(repositoryId) || !positive(headRepositoryId) || !positive(runId) || !sha(headSha) || !positive(attempt) || !hash(archiveSha256)) {
    throw new Error('Invalid requested artifact identity');
  }
  if (!positive(artifact?.id) || artifact.name !== `ui-receipts-${runId}-${attempt}` ||
    artifact.expired !== false || !positive(artifact.size_in_bytes) || artifact.size_in_bytes > 1024 * 1024 ||
    artifact.digest !== `sha256:${archiveSha256}` || artifact.workflow_run?.id !== runId ||
    artifact.workflow_run.head_sha !== headSha || artifact.workflow_run.repository_id !== repositoryId ||
    artifact.workflow_run.head_repository_id !== headRepositoryId) throw new Error('Artifact identity or digest mismatch');
  return {artifactId: artifact.id, runId, headSha, attempt, repositoryId, headRepositoryId, archiveSha256,
    metadataMatched: true, independentlyFetched: false};
}

export function reconcileUIReceipts(documents, {headSha, attempt, preFitSelection = null, catalogue = null}) {
  if (!sha(headSha) || !positive(attempt)) throw new Error('Invalid requested receipt identity');
  const {lane, runtime, execution, outcome} = documents;
  if (!lane || !runtime || !execution || typeof outcome !== 'string' || outcome.length > 32 ||
    lane.schemaVersion !== 1 || lane.sha !== headSha || lane.attempt !== attempt || lane.locale !== 'en' ||
    runtime.schemaVersion !== 3 || runtime.locale !== 'en' ||
    runtime.measurementPolicy !== 'xcresult-duration-with-activity-boundary-exclusions-v2' ||
    execution.schemaVersion !== 1 || execution.locale !== 'en') throw new Error('Receipt identity mismatch');
  const stepOutcome = outcome.trim();
  if (!['success', 'failure', 'cancelled', 'skipped'].includes(stepOutcome) || lane.outcome !== stepOutcome ||
    lane.runtimeReceiptPresent !== true || execution.runtimeReceiptPresent !== true ||
    typeof execution.resultBundlePresent !== 'boolean' || !hash(execution.logSHA256) ||
    !natural(execution.xcodebuildExitStatus) || execution.xcodebuildExitStatus > 255 ||
    !natural(execution.selectorCount) || !natural(runtime.selectorCount) || !natural(runtime.caseCount)) {
    throw new Error('Receipt execution fields mismatch');
  }
  const selection = lane.selection;
  if (!selection || !natural(selection.deferred) || selection.deferred > 5000 ||
    typeof selection.scopeUnknown !== 'boolean') throw new Error('Invalid lane selection');
  const requested = selected(selection.selected, 'selected tests');
  const cut = selected(selection.cut, 'cut tests');
  const notExecuted = selected(lane.notExecuted, 'not-executed tests');
  if (!requested.length || runtime.selectorCount !== requested.length || execution.selectorCount !== requested.length ||
    cut.some(s => requested.includes(s)) || cut.length > selection.deferred) throw new Error('Selection counts or partition mismatch');
  const executed = cases(lane.executed), measured = cases(runtime.tests);
  if (!equal(executed, measured) || measured.length !== runtime.caseCount ||
    !finite(lane.testDurationSeconds) || lane.testDurationSeconds !== runtime.testDurationSeconds) {
    throw new Error('Lane and runtime cases disagree');
  }
  const requestedKeys = new Set(requested.map(runtimeKey)), executedKeys = new Set(executed.map(c => c.identifier));
  if (executed.some(c => !requestedKeys.has(c.identifier))) throw new Error('Executed case was not selected');
  const missing = requested.filter(s => !executedKeys.has(runtimeKey(s)));
  if (!equal(missing, notExecuted)) throw new Error('Not-executed evidence contradicts selected identities');
  let reportedExecutionCompleted = false;
  switch (execution.classification) {
    case 'completed':
      if (execution.xcodebuildExitStatus !== 0 || !execution.resultBundlePresent || !executed.length ||
        execution.failureSignature !== null) throw new Error('Completed execution contradicts evidence');
      reportedExecutionCompleted = true; break;
    case 'test-failure':
    case 'unclassified-failure':
      if (execution.xcodebuildExitStatus === 0 || execution.failureSignature !== null) throw new Error('Failed execution contradicts evidence');
      break;
    case 'evidence-failure':
      if (execution.failureSignature !== null) throw new Error('Invalid evidence failure signature');
      break;
    default: throw new Error('Unsupported execution classification with runtime receipt');
  }
  if (!['passed', 'failed'].includes(runtime.budgetStatus) || !Array.isArray(runtime.budgetViolations) ||
    runtime.budgetViolations.some(v => typeof v !== 'string' || !v.length || v.length > 2048) ||
    (runtime.budgetStatus === 'passed') !== (runtime.budgetViolations.length === 0)) throw new Error('Invalid reported budget state');
  let preFitMatched = null, deferredSelectors = null;
  if (preFitSelection !== null) {
    const before = selected(preFitSelection, 'pre-fit tests');
    if (!equal(before, [...requested, ...cut].sort())) throw new Error('Pre-fit selection differs from selected plus cut');
    preFitMatched = true;
  }
  if (catalogue !== null) {
    const all = selected(catalogue, 'catalogue tests');
    if (requested.concat(cut).some(s => !all.includes(s))) throw new Error('Selection outside supplied catalogue');
    deferredSelectors = all.filter(s => !requested.includes(s));
    if (deferredSelectors.length !== selection.deferred) throw new Error('Deferred count differs from supplied catalogue');
  }
  return {headSha, attempt, locale: 'en', selected: requested, executed,
    notExecuted: missing, cut, deferredCount: selection.deferred, deferredSelectors,
    scopeUnknown: selection.scopeUnknown, selectedExecutionComplete: missing.length === 0 && executed.length > 0,
    allRecordedCasesPassed: executed.length > 0 && executed.every(c => c.result === 'Passed'),
    reportedOutcome: stepOutcome, reportedExecutionCompleted, preFitMatched,
    catalogueMatched: catalogue === null ? null : true, reportedRuntimeBudgetStatus: runtime.budgetStatus,
    evidenceDigest: createHash('sha256').update(JSON.stringify(documents)).digest('hex'),
    acceptance: null,
    limitations: ['Matching receipt identities is not independent proof that GitHub executed them.',
      'Pre-fit selection and catalogue comparisons apply only to supplied lists; their historical provenance is separate.',
      'Deferred names remain unknown without a supplied historical catalogue; budget cuts are only a subset of deferrals.',
      'Runtime budgets, adjustments, selector policy, nightly discharge, required jobs, cohort and p95 are not qualified.',
      'This diagnostic does not replace the hosted functional gate or silently promote failed execution.']};
}
