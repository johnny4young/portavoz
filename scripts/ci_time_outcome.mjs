// Pure outcome policy for one complete attempt. The collector must attest to
// complete pagination and exact-attempt ownership; this module does no I/O.
import {blockingJobs, nonBlockingJobs, classifyStep} from './ci_time_workflow.mjs';

export const rerunRefusedStep = 'Refuse to manufacture evidence on a rerun';
export const uiLaneFailedStep = 'Fail the lane when its evidence is not complete';
export const uiReceiptsStep = "Collect the UI lane's receipts";
const gateJobs = new Set(['ui-test-gate', 'gate']);
const conclusions = new Set(['success', 'skipped', 'failure', 'cancelled', 'timed_out']);
const knownJobs = new Set(Object.values(blockingJobs).flatMap(names => [...names]));
const baseName = name => typeof name === 'string' ? name.split(' (', 1)[0] : null;
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);

/**
 * Rows: {name, carried: boolean, conclusion, durationSeconds, failedSteps}.
 * Missing cancelled-job duration/limit cannot rule out timeout. failedSteps
 * is required only for causal failed jobs. Unknown cancellation timing keeps
 * lower-priority outcomes unknown unless supersession rules out inference.
 * All evidence flags must be explicit booleans; absent evidence returns null
 * (UNKNOWN), never a passing or product outcome inferred from missing data.
 * ownershipVerified is a caller attestation, not proof by itself: the collector
 * must establish each row belongs to this exact run and attempt.
 * jobsComplete covers pagination, not scope, timing, cohorts or acceptance.
 * capacity/advisory are unverified hints: this contract carries no annotation
 * provenance. They cannot establish infrastructure or a verified green attempt.
 * Passed remains UNKNOWN until verified selection and gate evidence is added.
 */
export function classifyOutcome(jobs, options = {}) {
  if (!Array.isArray(jobs) || !record(options)) return null;
  const {event, jobsComplete, timeouts, superseded, runCancelled, advisory, capacity} = options;
  if (!Object.hasOwn(blockingJobs, event) || options.ownershipVerified !== true) return null;
  // An observed, exact-attempt eligible API timeout already proves the highest
  // priority cause. It does not assert complete pages or known sibling results.
  if (jobs.some(job => record(job) && job.carried === false &&
      blockingJobs[event].has(baseName(job.name)) && job.conclusion === 'timed_out')) return 'timeout';
  if (jobsComplete !== true ||
      ![superseded, runCancelled, advisory, capacity].every(value => typeof value === 'boolean') ||
      !record(timeouts) || Object.values(timeouts).some(value => !Number.isSafeInteger(value) || value <= 0) ||
      (event !== 'pull_request' && superseded)) return null;

  const blocking = [];
  for (const job of jobs) {
    if (!record(job)) return null;
    const name = baseName(job.name);
    // A downstream alert and reused jobs cannot change this attempt's cause.
    if (nonBlockingJobs.has(name) || job.carried === true) continue;
    if (job.carried !== false || !knownJobs.has(name)) return null;
    if (!blockingJobs[event].has(name)) continue;
    if (!conclusions.has(job.conclusion)) return null;
    blocking.push({job, name});
  }

  // A cancelled job near its limit is a legacy one-minute-tolerance inference,
  // not the API timed_out conclusion. Future output must preserve that origin.
  // Supersession prevents only inferred cancelled timeouts.
  const measured = job => Number.isFinite(job.durationSeconds) && job.durationSeconds >= 0;
  if (blocking.some(({job, name}) => job.conclusion === 'cancelled' && !superseded &&
      Object.hasOwn(timeouts, name) && measured(job) &&
      job.durationSeconds >= timeouts[name] * 60 - 60)) return 'timeout';
  // A missing limit or duration leaves a higher-priority timeout unresolved.
  if (!superseded && blocking.some(({job, name}) => job.conclusion === 'cancelled' &&
      (!Object.hasOwn(timeouts, name) || !measured(job)))) return null;

  let failed = blocking.filter(({job}) => job.conclusion === 'failure');
  const cancelled = blocking.filter(({job}) => job.conclusion === 'cancelled');
  const causes = failed.filter(({name}) => !gateJobs.has(name));
  // Only named dependency-aggregation steps may be explained by a sibling.
  // A gate setup failure, unknown step or absent step evidence is independent
  // or ambiguous; never discard it to manufacture a single sibling cause.
  const aggregateSteps = new Set(['Require every lane the selection asked for',
    'Require selected evidence and allow an honest no-UI skip']);
  const independentGates = failed.filter(({name}) => gateJobs.has(name)).flatMap(({job, name}) => {
    if (!Array.isArray(job.failedSteps) || !job.failedSteps.length) return [{job, name}];
    const steps = job.failedSteps.filter(step => !aggregateSteps.has(step));
    return steps.length ? [{job: {...job, failedSteps: steps}, name}] : [];
  });
  if (causes.length && independentGates.length) return null;
  if (causes.length || cancelled.length) failed = [...causes, ...independentGates];
  if (failed.length) {
    const steps = new Set();
    for (const {job} of failed) {
      if (!Array.isArray(job.failedSteps) || !job.failedSteps.length) return null;
      for (const step of job.failedSteps) {
        if (typeof step !== 'string' || (step !== rerunRefusedStep && classifyStep(step) === null)) return null;
        steps.add(step);
      }
    }
    if (steps.size === 1 && steps.has(rerunRefusedStep)) return 'rerun-refused';
    if (steps.has(uiReceiptsStep)) return 'infrastructure';
    // The generic UI failure can mean product or hosted drift. Without
    // eligible annotation provenance, neither advisory=true nor false proves
    // which. An independently classified product step remains actionable.
    if (steps.has(uiLaneFailedStep) && ![...steps].some(step =>
        step !== uiLaneFailedStep && classifyStep(step) === 'product')) return null;
    if ([...steps].some(step => classifyStep(step) === 'product')) return 'product';
    return [...steps].every(step => classifyStep(step) === 'infrastructure') ? 'infrastructure' : null;
  }
  // A bare capacity hint would change cancellation to infrastructure, but
  // lacks proof that it came from an eligible run/job rather than alert/carried.
  if (capacity) return null;
  if (cancelled.length || runCancelled) {
    if (superseded) return 'superseded';
    if (cancelled.some(({job, name}) => !Object.hasOwn(timeouts, name) || !measured(job))) return null;
    return 'cancelled';
  }
  // Neither green observed jobs nor an advisory hint prove the complete
  // selected/required states and gate outcome. No passed assertion in this slice.
  return null;
}
