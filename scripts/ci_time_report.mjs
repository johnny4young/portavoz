#!/usr/bin/env node
// Exact-run CI timing; scope/cohort stay unknown until separately attested.
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {ghJSON, ghText, readExactRun, collectGateScopeObservations} from './ci_time_github.mjs';
import {classifyOutcome} from './ci_time_outcome.mjs';
import {blockingJobs} from './ci_time_workflow.mjs';
import {measureAttempt} from './ci_time_metrics.mjs';

function timestamp(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(value)) return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) && new Date(parsed).toISOString().slice(0, 19) === value.slice(0, 19)
    ? parsed : null;
}

const hasRunner = id => Number.isSafeInteger(id) && id > 0;

function seconds(first, last) {
  const start = timestamp(first), end = timestamp(last);
  return start !== null && end !== null && end >= start ? (end - start) / 1000 : null;
}

// Only complete, unambiguous step rows can establish a causal failed step.
function failedSteps(steps) {
  if (!Array.isArray(steps) || !steps.length) return null;
  const numbers = new Set();
  const names = [];
  for (const step of steps) {
    if (!step || !Number.isSafeInteger(step.number) || step.number <= 0 || numbers.has(step.number) ||
        typeof step.name !== 'string' || !step.name.length || step.name.length > 1024 ||
        step.status !== 'completed' || !['success', 'skipped', 'failure'].includes(step.conclusion)) return null;
    numbers.add(step.number);
    if (step.conclusion === 'failure') names.push(step.name);
  }
  return names;
}

function attemptOutcome(run, attempt) {
  const {metadata, jobs, ownershipVerified, jobsComplete} = attempt;
  // A failing job may be continue-on-error. It cannot turn a successful
  // attempt into a causal failure, nor explain an unknown run state.
  if (!['failure', 'timed_out', 'cancelled'].includes(metadata.conclusion)) {
    return {category: 'unknown', origin: null};
  }
  const rows = jobs.map(job => ({name: job.name, carried: job.run_attempt < metadata.run_attempt,
    conclusion: job.conclusion, failedSteps: failedSteps(job.steps)}));
  // Neither supersession nor historical timeout limits are attested by this
  // collector. Do not infer cancelled timeouts from today's workflow file.
  const cancellation = metadata.conclusion === 'cancelled' || rows.some(job => job.carried === false &&
    blockingJobs.pull_request.has(job.name.split(' (', 1)[0]) && job.conclusion === 'cancelled');
  const cause = classifyOutcome(rows, {event: run.event, ownershipVerified, jobsComplete,
    timeouts: {}, superseded: cancellation ? null : false,
    runCancelled: metadata.conclusion === 'cancelled', advisory: false, capacity: false});
  const category = cause === 'timeout' || metadata.conclusion === 'failure' ? cause : null;
  return {category: category ?? 'unknown',
    origin: category === 'timeout' ? 'api-conclusion' : category ? 'job-steps' : null};
}

export function exactRunReport(evidence, prNumber) {
  const run = evidence.run;
  if (evidence.prAssociation?.status === 'verified' && evidence.prAssociation.prNumber !== prNumber) {
    throw new Error('PR attribution mismatch');
  }
  return {repository: evidence.repository, requestedPrNumber: prNumber,
    prNumber: evidence.prAssociation?.status === 'verified' ? prNumber : null,
    prAssociation: evidence.prAssociation ?? {status: 'unknown', source: null}, runId: run.id, head: run.head_sha,
    workflow: run.path, workflowCreatedAt: run.created_at,
    source: `https://github.com/${evidence.repository}/actions/runs/${run.id}`,
    limitations: ['One run is not p95 or acceptance.', 'Required scope, cache and ordinary cohort are unknown.',
      'Job-created to start is a queue proxy, not independently proven eligibility time.',
      'Outcomes require exact collected jobs; green, cancellation, supersession and inferred timeouts remain unknown.'],
    attempts: evidence.attempts.map(attempt => {
      const {metadata, jobs} = attempt;
      const adapted = jobs.map(job => ({id: job.id, name: job.name, workflow: 'ci.yml', runId: job.run_id,
        attemptNumber: job.run_attempt, carried: job.run_attempt < metadata.run_attempt,
        // This set is only used to reject impossible ordering before gate, never to claim execution.
        required: job.name !== 'alert', runnerAssigned: hasRunner(job.runner_id),
        conclusion: job.conclusion, startedAt: job.started_at, completedAt: job.completed_at}));
      const timing = measureAttempt({runId: run.id, attemptNumber: metadata.run_attempt,
        createdAt: run.created_at, attemptStartedAt: metadata.run_started_at,
        jobsComplete: attempt.jobsComplete === true && attempt.ownershipVerified === true,
        scopeEvidence: null, jobs: adapted});
      return {attempt: metadata.run_attempt, startedAt: metadata.run_started_at, conclusion: metadata.conclusion,
        outcome: attemptOutcome(run, attempt),
        scopeObservation: attempt.scopeObservation ?? {status: 'not-collected', verified: false},
        executionSeconds: null, totalSeconds: timing.total, scope: 'unknown', cohort: 'unknown',
        jobs: jobs.map(job => ({id: job.id, name: job.name, runAttempt: job.run_attempt, conclusion: job.conclusion,
          createdAt: job.created_at, startedAt: job.started_at, completedAt: job.completed_at,
          queueProxySeconds: hasRunner(job.runner_id) ? seconds(job.created_at, job.started_at) : null,
          durationSeconds: hasRunner(job.runner_id) ? seconds(job.started_at, job.completed_at) : null}))};
    })};
}

function argumentsFor(args) {
  const fields = {};
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i];
    if (!['--repository', '--pr', '--run', '--head'].includes(key) || !args[i + 1] || key in fields) {
      throw new Error('Usage: ci_time_report.mjs --repository OWNER/REPO --pr NUMBER --run NUMBER --head SHA');
    }
    fields[key] = args[i + 1];
  }
  if (!fields['--repository'] || !/^\d+$/.test(fields['--pr'] ?? '') ||
    !/^\d+$/.test(fields['--run'] ?? '') || !fields['--head']) throw new Error('Missing or invalid argument');
  return {repository: fields['--repository'], prNumber: Number(fields['--pr']),
    runId: Number(fields['--run']), headSha: fields['--head']};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const identity = argumentsFor(process.argv.slice(2));
    const evidence = await collectGateScopeObservations(ghText, await readExactRun(ghJSON, identity));
    process.stdout.write(`${JSON.stringify(exactRunReport(evidence, identity.prNumber), null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`ci_time_report: ${error.message}\n`);
    process.exitCode = 1;
  }
}
