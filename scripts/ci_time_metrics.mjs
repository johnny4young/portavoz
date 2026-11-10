// Calculations for the current single-workflow PR contract. A collector must
// establish complete pagination and supply classifications for the exact run.
const DAY_MS = 86_400_000;
const positive = value => Number.isSafeInteger(value) && value > 0;
const ISO_UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;
const REQUIRED_JOBS = ['repository-hygiene', 'lint', 'scope', 'build-and-test', 'gate'];
const OUTCOMES = new Set(['passed', 'success', 'failure', 'product', 'infrastructure', 'timeout',
  'timed_out', 'cancelled', 'rerun-refused', 'superseded']);

function timestamp(value) {
  if (typeof value !== 'string' || !ISO_UTC.test(value)) return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) && new Date(parsed).toISOString().slice(0, 19) === value.slice(0, 19)
    ? parsed : null;
}

function elapsed(start, end) {
  const first = timestamp(start);
  const last = timestamp(end);
  return first === null || last === null || last < first ? null : (last - first) / 1000;
}

export function nearestRank(values, fraction) {
  if (!Number.isFinite(fraction) || fraction <= 0 || fraction > 1) throw new RangeError('Invalid percentile');
  if (!values.length) return null;
  if (values.some(value => !Number.isFinite(value) || value < 0)) throw new TypeError('Invalid measurement');
  const ordered = [...values].sort((a, b) => a - b);
  return ordered[Math.ceil(ordered.length * fraction) - 1];
}

export function measureAttempt(attempt) {
  const jobs = Array.isArray(attempt.jobs) ? attempt.jobs : [];
  const identityKnown = positive(attempt.runId) && positive(attempt.attemptNumber);
  const classified = jobs.every(job => typeof job.required === 'boolean' && typeof job.carried === 'boolean');
  const scope = attempt.scopeEvidence;
  const scopeKnown = scope?.verified === true && [scope.uiRequired, scope.interruptionRequired,
    scope.iosRequired].every(value => typeof value === 'boolean') &&
    (scope.uiRequired || !scope.interruptionRequired);
  const expected = [...REQUIRED_JOBS, ...(scope?.uiRequired ? ['ui-tests'] : []),
    ...(scope?.interruptionRequired ? ['interruption'] : []),
    ...(scope?.iosRequired ? ['ios-portability'] : [])];
  const dynamic = [['ui-tests', scope?.uiRequired], ['interruption', scope?.interruptionRequired],
    ['ios-portability', scope?.iosRequired]];
  const dynamicsConsistent = scopeKnown && dynamic.every(([name, selected]) => {
    const matches = jobs.filter(job => job.workflow === 'ci.yml' && job.name === name);
    return matches.length === 1 && (selected ? matches[0].required === true :
      matches[0].required === false && matches[0].conclusion === 'skipped' && matches[0].runnerAssigned === false);
  });
  const jobIds = jobs.map(job => job.id);
  const uniqueJobs = jobIds.every(positive) && new Set(jobIds).size === jobIds.length;
  const inventoryKnown = attempt.jobsComplete === true && classified && dynamicsConsistent && uniqueJobs &&
    expected.every(name => jobs.filter(job => job.workflow === 'ci.yml' && job.name === name &&
      job.required === true).length === 1);
  const required = jobs.filter(job => job.required === true && job.carried === false);
  const durations = required.map(job => elapsed(job.startedAt, job.completedAt));
  const ranRequired = jobs.filter(job => job.required).every(job => job.runnerAssigned === true &&
    ['success', 'failure', 'cancelled', 'timed_out'].includes(job.conclusion));
  const ownershipKnown = identityKnown && elapsed(attempt.createdAt, attempt.attemptStartedAt) !== null &&
    jobs.every(job => job.runId === attempt.runId && Number.isSafeInteger(job.attemptNumber) &&
      (job.carried ? job.attemptNumber >= 1 && job.attemptNumber < attempt.attemptNumber &&
        elapsed(job.completedAt, attempt.attemptStartedAt) !== null :
        job.attemptNumber === attempt.attemptNumber && (job.required === false && job.runnerAssigned === false ||
          elapsed(attempt.attemptStartedAt, job.startedAt) !== null)));
  const gates = jobs.filter(job => job.workflow === 'ci.yml' && job.name === 'gate' && job.carried === false);
  const gate = gates.length === 1 ? gates[0] : null;
  const chronologyKnown = gate && elapsed(attempt.createdAt, gate.startedAt) !== null &&
    elapsed(gate.startedAt, gate.completedAt) !== null && jobs.filter(job => job.required).every(job =>
      elapsed(attempt.createdAt, job.startedAt) !== null && elapsed(job.startedAt, job.completedAt) !== null &&
      (job === gate || elapsed(job.completedAt, gate.startedAt) !== null));
  const execution = inventoryKnown && ownershipKnown && chronologyKnown && ranRequired && required.length &&
    durations.every(value => value !== null) ? Math.max(...durations) : null;
  // Total can survive a lane that never started; its exact gate must still be proven.
  const contradictoryEnd = gate && jobs.filter(job => job.required && job !== gate &&
    timestamp(job.completedAt) !== null).some(job => elapsed(job.completedAt, gate.startedAt) === null);
  const gateKnown = attempt.jobsComplete === true && uniqueJobs && identityKnown && gate &&
    gate.runnerAssigned === true && ['success', 'failure', 'cancelled', 'timed_out'].includes(gate.conclusion) &&
    !contradictoryEnd && gate.runId === attempt.runId && gate.attemptNumber === attempt.attemptNumber &&
    elapsed(attempt.createdAt, attempt.attemptStartedAt) !== null &&
    elapsed(attempt.attemptStartedAt, gate.startedAt) !== null && elapsed(gate.startedAt, gate.completedAt) !== null;
  const total = gateKnown ? elapsed(attempt.createdAt, gate.completedAt) : null;
  return { ...attempt, execution, total };
}

function metric(rows, field, limit, evidenceComplete) {
  const values = rows.map(row => row[field]).filter(value => value !== null && value !== undefined);
  const complete = evidenceComplete && rows.length > 0 && values.length === rows.length;
  const p95 = nearestRank(values, 0.95);
  return { expected: rows.length, n: values.length, p50: nearestRank(values, 0.5),
    p90: nearestRank(values, 0.9), p95, max: values.length ? Math.max(...values) : null,
    complete, observedP95WithinLimit: complete ? p95 <= limit : null };
}

export function summarizeAttempts(rows, {inventoryComplete = false} = {}) {
  const identities = rows.map(row => positive(row.runId) && positive(row.attemptNumber)
    ? `${row.runId}:${row.attemptNumber}` : null);
  const identitiesKnown = identities.every(Boolean) && new Set(identities).size === identities.length;
  const scopeUnknown = rows.filter(row => typeof row.ordinary !== 'boolean' || !OUTCOMES.has(row.outcome)).length;
  // Superseded attempts remain visible; absent timing is unknown, not erased.
  const included = rows.filter(row => row.ordinary === true);
  const allHeadsKnown = rows.every(row => typeof row.head === 'string' && row.head.length > 0);
  const groups = new Map();
  const runs = new Map();
  for (const row of rows) {
    const group = groups.get(row.head) ?? []; group.push(row); groups.set(row.head, group);
    const run = runs.get(row.runId) ?? []; run.push(row); runs.set(row.runId, run);
  }
  const runsKnown = [...runs.values()].every(run => run.every(row => row.head === run[0].head &&
    row.createdAt === run[0].createdAt && Number.isSafeInteger(row.attemptNumber)) &&
    run.map(row => row.attemptNumber).sort((a, b) => a - b).every((number, index) => number === index + 1));
  const ordinalsKnown = [...groups.values()].every(group => {
    if (group.some(row => elapsed(row.createdAt, row.attemptStartedAt) === null ||
      !Number.isSafeInteger(row.ordinal))) return false;
    const ordered = group.slice().sort((a, b) => timestamp(a.attemptStartedAt) - timestamp(b.attemptStartedAt));
    return ordered.every((row, index) => row.ordinal === index + 1 && (index === 0 ||
      timestamp(row.attemptStartedAt) > timestamp(ordered[index - 1].attemptStartedAt))) &&
      ordered.every((row, index) => !ordered.slice(0, index).some(previous =>
        previous.runId === row.runId && previous.attemptNumber >= row.attemptNumber));
  });
  const evidenceComplete = inventoryComplete && identitiesKnown && allHeadsKnown && runsKnown && ordinalsKnown && scopeUnknown === 0;
  const byHead = new Map();
  for (const row of included) {
    const start = timestamp(row.createdAt);
    if (start === null) { byHead.set(row.head, null); continue; }
    if (!byHead.has(row.head)) byHead.set(row.head, start);
    else if (byHead.get(row.head) !== null) byHead.set(row.head, Math.min(byHead.get(row.head), start));
  }
  const starts = [...byHead.values()];
  const completeStarts = starts.length > 0 && starts.every(value => value !== null);
  const spanMs = completeStarts ? Math.max(...starts) - Math.min(...starts) : null;
  const heads = new Set(included.map(row => row.head).filter(Boolean)).size;
  return { heads, attempts: included.length, spanMs, scopeUnknown, evidenceComplete,
    // This is only the minimum size and time window, not full acceptance.
    windowMet: !evidenceComplete || !allHeadsKnown || spanMs === null ? null : heads >= 30 && spanMs >= 7 * DAY_MS,
    execution: metric(included, 'execution', 600, evidenceComplete),
    total: metric(included, 'total', 1200, evidenceComplete) };
}

// Never silently choose how reruns weight the p95. All views share the same
// head window, computed over the complete inventory rather than a chosen retry.
export function summarizeViews(rows, {inventoryComplete = false} = {}) {
  const all = summarizeAttempts(rows, {inventoryComplete});
  const eligible = rows.filter(row => row.ordinary === true);
  if (!all.evidenceComplete) return {all, first: null, last: null, orderingComplete: false};
  // A head with both ordinary and exempt attempts has no agreed first/last
  // head view; filtering first would silently substitute an older attempt.
  const eligibility = new Map();
  for (const row of rows) {
    if (eligibility.has(row.head) && eligibility.get(row.head) !== row.ordinary)
      return {all, first: null, last: null, orderingComplete: false};
    eligibility.set(row.head, row.ordinary);
  }
  const groups = new Map();
  for (const row of eligible) {
    if (typeof row.head !== 'string' || !row.head || !Number.isSafeInteger(row.ordinal) || row.ordinal < 1) {
      return {all, first: null, last: null, orderingComplete: false};
    }
    const group = groups.get(row.head) ?? [];
    if (group.some(other => other.ordinal === row.ordinal)) {
      return {all, first: null, last: null, orderingComplete: false};
    }
    group.push(row);
    groups.set(row.head, group);
  }
  const ordered = [...groups.values()].map(group => group.sort((a, b) => a.ordinal - b.ordinal));
  if (ordered.some(group => group.some((row, index) => row.ordinal !== index + 1))) {
    return {all, first: null, last: null, orderingComplete: false};
  }
  const summarize = selected => ({heads: selected.length, attempts: selected.length,
    spanMs: all.spanMs, scopeUnknown: 0, evidenceComplete: true, windowMet: all.windowMet,
    execution: metric(selected, 'execution', 600, true), total: metric(selected, 'total', 1200, true)});
  return {all, first: summarize(ordered.map(group => group[0])),
    last: summarize(ordered.map(group => group[group.length - 1])), orderingComplete: true};
}
