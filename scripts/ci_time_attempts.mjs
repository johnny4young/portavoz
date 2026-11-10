#!/usr/bin/env node
// Bind all attempt/job metadata to a declared inventory; never infer acceptance.
import {createHash} from 'node:crypto';
import {readFileSync, statSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {ghJSON, readExactRun, utcTimestamp} from './ci_time_github.mjs';
import {normalizeInventoryRun} from './ci_time_inventory.mjs';
import {exactRunReport} from './ci_time_report.mjs';

const positive = value => Number.isSafeInteger(value) && value > 0;
const sha = value => typeof value === 'string' && /^[a-f0-9]{40}$/.test(value);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');

export function validateRunInventory(input) {
  if (input?.schemaVersion !== 1 || typeof input.repository !== 'string' ||
      !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(input.repository) || input.repository.includes('..') ||
      input.workflow !== '.github/workflows/ci.yml' || utcTimestamp(input.cutoff) === null ||
      input.selectionComplete !== true || input.runInventoryVerified !== true ||
      input.attemptDetailsCollected !== false || !Array.isArray(input.heads) ||
      !positive(input.requestedHeads) || input.requestedHeads > 100 ||
      input.selectedHeads !== input.heads.length || input.heads.length > input.requestedHeads) {
    throw new Error('Invalid source inventory');
  }
  const rows = [], heads = new Set(), ids = new Set();
  for (const head of input.heads) {
    if (!sha(head.headSha) || heads.has(head.headSha) || !Array.isArray(head.runs) || !head.runs.length) {
      throw new Error('Invalid inventory head');
    }
    heads.add(head.headSha);
    for (const row of head.runs) {
      if (row.headSha !== head.headSha || ids.has(row.runId) || row.workflowId !== input.workflowId) {
        throw new Error('Invalid inventory run identity');
      }
      const normalized = normalizeInventoryRun({id: row.runId, head_sha: row.headSha,
        workflow_id: row.workflowId, path: input.workflow, event: 'pull_request',
        repository: {full_name: input.repository}, created_at: row.createdAt, updated_at: row.updatedAt,
        run_attempt: row.latestAttempt, status: row.status, conclusion: row.conclusion,
        pull_requests: row.prNumbers?.map(number => ({number, head: {sha: row.headSha}}))},
      input.repository, head.headSha, input.cutoff);
      if (!same(row, normalized)) throw new Error('Invalid normalized inventory row');
      ids.add(row.runId); rows.push(row);
    }
    if (head.latestCreatedAt !== head.runs.map(run => run.createdAt).sort().at(-1)) {
      throw new Error('Invalid latest head timestamp');
    }
  }
  const expected = rows.reduce((sum, row) => sum + row.latestAttempt, 0);
  if (rows.length > 1000 || expected > 1000 || !Number.isSafeInteger(expected) ||
      input.runCount !== rows.length || input.expectedAttemptCount !== expected ||
      input.pendingRuns !== rows.filter(row => row.status !== 'completed').length ||
      (rows.length === 0 && input.workflowId !== null) ||
      input.digest !== digest({repository: input.repository, cutoff: input.cutoff, heads: input.heads})) {
    throw new Error('Inventory digest, totals or collection bounds mismatch');
  }
  return rows;
}

const jobFields = ['id', 'run_id', 'run_attempt', 'head_sha', 'name', 'status', 'conclusion',
  'created_at', 'started_at', 'completed_at', 'runner_id'];
const stepFields = ['number', 'name', 'status', 'conclusion', 'started_at', 'completed_at'];
const pick = (value, fields) => Object.fromEntries(fields.map(field => [field, value?.[field] ?? null]));
function retainedAttempts(evidence) {
  return evidence.attempts.map(attempt => ({attempt: attempt.metadata.run_attempt,
    createdAt: attempt.metadata.created_at, startedAt: attempt.metadata.run_started_at, conclusion: attempt.metadata.conclusion,
    ownershipVerified: attempt.ownershipVerified, jobsComplete: attempt.jobsComplete,
    jobs: attempt.jobs.map(job => ({...pick(job, jobFields),
      steps: Array.isArray(job.steps) ? job.steps.map(step => pick(step, stepFields)) : null}))}));
}

export async function collectInventoryAttempts(get, inventory, {onProgress = () => {}} = {}) {
  inventory = structuredClone(inventory);
  const declared = validateRunInventory(inventory), results = [], jobOwners = new Map();
  const matches = (actual, row) => same(normalizeInventoryRun(actual, inventory.repository,
    row.headSha, inventory.cutoff), row);
  for (const row of declared) {
    const result = {runId: row.runId, headSha: row.headSha, status: 'not-collected', reason: null};
    results.push(result);
    if (row.status !== 'completed') {
      result.reason = 'pending-in-source-inventory';
    } else {
      try {
        const root = `repos/${inventory.repository}/actions/runs/${row.runId}`;
        // Bind every root read, including readExactRun's first read, before
        // it can traverse a changed or undeclared attempt count.
        const boundGet = async path => {
          const value = await get(path);
          if (path === root && !matches(value, row)) throw new Error('Stale source inventory');
          return value;
        };
        const prNumber = row.prNumbers.length === 1 ? row.prNumbers[0] : null;
        const evidence = await readExactRun(boundGet, {repository: inventory.repository,
          runId: row.runId, headSha: row.headSha, prNumber});
        if (!matches(evidence.run, row) || evidence.attempts.length !== row.latestAttempt) {
          throw new Error('Collected run differs from source inventory');
        }
        const ownedIds = new Set(evidence.attempts.flatMap(attempt => attempt.jobs.map(job => job.id)));
        if ([...ownedIds].some(id => jobOwners.has(id) && jobOwners.get(id) !== row.runId)) {
          throw new Error('Job identity belongs to another collected run');
        }
        result.report = exactRunReport(evidence, prNumber);
        result.attempts = retainedAttempts(evidence);
        result.status = 'collected';
        for (const id of ownedIds) jobOwners.set(id, row.runId);
      } catch {
        delete result.report; delete result.attempts;
        result.reason = 'unavailable-or-inconsistent-run';
      }
    }
    onProgress({runId: result.runId, status: result.status, reason: result.reason});
  }
  // Revalidate every collected run after the full pass. A changed run loses its
  // report rather than leaving a plausible timing in a supposedly complete set.
  for (let index = 0; index < results.length; index++) {
    const result = results[index];
    if (result.status !== 'collected') continue;
    try {
      if (!matches(await get(`repos/${inventory.repository}/actions/runs/${result.runId}`), declared[index])) {
        throw new Error('Run drift');
      }
    } catch {
      result.status = 'not-collected'; result.reason = 'changed-or-unavailable-on-final-read';
      delete result.report; delete result.attempts;
      onProgress({runId: result.runId, status: result.status, reason: result.reason});
    }
  }
  const collected = results.filter(result => result.status === 'collected');
  const attempts = collected.flatMap(result => result.attempts);
  const complete = results.length > 0 && collected.length === declared.length &&
    attempts.length === inventory.expectedAttemptCount;
  return {schemaVersion: 1, repository: inventory.repository, sourceInventoryDigest: inventory.digest,
    sourceCutoff: inventory.cutoff, coverage: 'declared-inventory-only', selectionReverified: false,
    expectedRuns: inventory.runCount, expectedAttempts: inventory.expectedAttemptCount,
    collectedRuns: collected.length, collectedAttempts: attempts.length,
    collectedJobRows: attempts.reduce((sum, attempt) => sum + attempt.jobs.length, 0),
    totalsKnown: collected.reduce((sum, result) => sum + result.report.attempts.filter(a => a.totalSeconds !== null).length, 0),
    attemptJobCoverageComplete: complete, acceptance: null, digest: digest(results), results,
    limitations: ['Only metadata for the declared inventory; the digest is integrity, not independent proof of selection.',
      'Run/attempt/job identities and final metadata are checked; no atomic historical API snapshot is available.',
      'Missing or stale runs remain explicit and make coverage incomplete; their plausible timings are removed.',
      'Job rows include carried jobs across attempts and are not a count of distinct executions.',
      'Required scope, ordinary cohort, historical workflow, cache and executed/deferred receipts remain unverified.',
      'Observed total times are diagnostics, not a qualified p95 or acceptance. No logs or artifacts are collected.']};
}

export function attemptsArgument(args) {
  if (args.length !== 2 || args[0] !== '--inventory' || !args[1]) {
    throw new Error('Usage: ci_time_attempts.mjs --inventory FILE');
  }
  return args[1];
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const file = attemptsArgument(process.argv.slice(2));
    if (statSync(file).size > 16 * 1024 * 1024) throw new Error('Inventory file exceeds 16 MiB');
    const inventory = JSON.parse(readFileSync(file, 'utf8'));
    const result = await collectInventoryAttempts(ghJSON, inventory, {onProgress: row =>
      process.stderr.write(`run ${row.runId}: ${row.status}${row.reason ? ' (' + row.reason + ')' : ''}\n`)});
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
    if (!result.attemptJobCoverageComplete) process.exitCode = 2;
  } catch (error) {
    process.stderr.write(`ci_time_attempts: ${error.message}\n`); process.exitCode = 1;
  }
}
