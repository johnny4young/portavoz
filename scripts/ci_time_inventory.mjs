#!/usr/bin/env node
// Read-only run inventory. Metadata completeness is not test/scope acceptance.
import {createHash} from 'node:crypto';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {allPages, discoverHeads, ghJSON, utcTimestamp} from './ci_time_github.mjs';

const positive = value => Number.isSafeInteger(value) && value > 0;
const states = new Set(['completed', 'queued', 'in_progress', 'requested', 'waiting', 'pending']);
const conclusions = new Set(['success', 'failure', 'neutral', 'cancelled', 'skipped', 'timed_out',
  'action_required', 'stale', 'startup_failure']);

export function normalizeInventoryRun(run, repository, headSha, cutoff) {
  const created = utcTimestamp(run?.created_at), updated = utcTimestamp(run?.updated_at);
  if (!positive(run?.id) || run.head_sha !== headSha || run.event !== 'pull_request' ||
      run.repository?.full_name !== repository || run.path !== '.github/workflows/ci.yml' ||
      !positive(run.workflow_id) || !positive(run.run_attempt) || !states.has(run.status) ||
      created === null || created > utcTimestamp(cutoff) || updated === null || updated < created ||
      (run.status === 'completed' ? !conclusions.has(run.conclusion) : run.conclusion !== null) ||
      !Array.isArray(run.pull_requests)) throw new Error('Run inventory identity or state mismatch');
  const numbers = new Set();
  for (const pr of run.pull_requests) {
    if (!positive(pr.number) || pr.head?.sha !== headSha || numbers.has(pr.number)) {
      throw new Error('Invalid run PR association');
    }
    numbers.add(pr.number);
  }
  return {runId: run.id, headSha, workflowId: run.workflow_id, createdAt: run.created_at,
    updatedAt: run.updated_at, latestAttempt: run.run_attempt, status: run.status,
    conclusion: run.conclusion, prNumbers: [...numbers].sort((a, b) => a - b)};
}

async function headRuns(get, {repository, cutoff}, headSha) {
  const root = `repos/${repository}/actions/workflows/ci.yml/runs?event=pull_request` +
    `&head_sha=${headSha}&created=${encodeURIComponent('<=' + cutoff)}`;
  const boundedGet = async path => {
    const result = await get(path);
    // GitHub caps filtered searches at 1,000. Even a count at that ceiling
    // cannot establish that there is no omitted history, so fail closed.
    if (result?.total_count >= 1000) throw new Error('Run search reached the 1000-result ceiling');
    return result;
  };
  const rows = await allPages(boundedGet, root, 'workflow_runs');
  if (!rows.length) throw new Error('Selected head has no runs');
  return rows.map(run => normalizeInventoryRun(run, repository, headSha, cutoff))
    .sort((a, b) => a.createdAt.localeCompare(b.createdAt) || a.runId - b.runId);
}

export async function collectRunInventory(get, {repository, cutoff, limit = 50}) {
  if (!positive(limit) || limit > 100) throw new TypeError('Head limit must be between 1 and 100');
  const input = {repository, cutoff, limit};
  const selection = await discoverHeads(get, input);
  if (!selection.selectionComplete) throw new Error('Ambiguous head selection boundary');
  const heads = [], ids = new Set();
  let workflowId = null;
  for (const head of selection.heads) {
    const runs = await headRuns(get, input, head.headSha);
    for (const run of runs) {
      if (ids.has(run.runId)) throw new Error('Run belongs to more than one selected head');
      ids.add(run.runId);
      workflowId ??= run.workflowId;
      if (run.workflowId !== workflowId) throw new Error('Workflow identity changed within inventory');
    }
    // The prefix used to select heads must also exist in the full head history.
    for (const observed of head.runs) {
      const selected = runs.find(run => run.runId === observed.id);
      if (!selected || JSON.stringify(selected) !== JSON.stringify(normalizeInventoryRun(observed, repository, head.headSha, cutoff))) {
        throw new Error('Discovery and head inventory disagree');
      }
    }
    const discoveredIds = new Set(head.runs.map(run => run.id));
    if (runs.some(run => (selection.exhausted || utcTimestamp(run.createdAt) >= utcTimestamp(selection.oldestFetchedAt)) &&
        !discoveredIds.has(run.runId))) throw new Error('Discovery and full-history prefix disagree');
    heads.push({headSha: head.headSha, latestCreatedAt: head.firstSeenAt, runs});
  }
  // Re-read after every selected head has been collected, not immediately after
  // each page. This catches reruns/deletions/insertions during the first pass.
  for (const head of heads) {
    if (JSON.stringify(await headRuns(get, input, head.headSha)) !== JSON.stringify(head.runs)) {
      throw new Error('Head run inventory changed during collection');
    }
  }
  const after = await discoverHeads(get, input);
  if (JSON.stringify(after) !== JSON.stringify(selection)) throw new Error('Head selection changed during collection');
  const rows = heads.flatMap(head => head.runs);
  const expectedAttemptCount = rows.reduce((sum, run) => sum + run.latestAttempt, 0);
  if (!Number.isSafeInteger(expectedAttemptCount)) throw new Error('Unsafe aggregate attempt count');
  const pending = rows.filter(run => run.status !== 'completed').length;
  const digest = createHash('sha256').update(JSON.stringify({repository, cutoff, heads})).digest('hex');
  return {schemaVersion: 1, repository, workflow: '.github/workflows/ci.yml', workflowId, cutoff,
    requestedHeads: limit, selectedHeads: heads.length, selectionComplete: true,
    runInventoryVerified: true, digest, runCount: rows.length,
    expectedAttemptCount, pendingRuns: pending,
    attemptDetailsCollected: false, acceptance: null, heads,
    limitations: ['Only API-visible PR runs for ci.yml created at or before cutoff; deleted runs cannot be recovered.',
      'Cutoff bounds run creation, not rerun time; status and attempt counts are current observations.',
      'Two matching reads detect observed drift; GitHub does not provide an atomic historical snapshot.',
      'Head order uses latest run creation time, not commit author time; all selected-head run histories are collected.',
      'No job, scope, cohort, cache, test receipt, timing percentile or acceptance is established.']};
}

export function inventoryArguments(args) {
  const fields = {};
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index], value = args[index + 1];
    if (!['--repository', '--cutoff', '--limit'].includes(key) || !value || key in fields) {
      throw new TypeError('Usage: ci_time_inventory.mjs --repository OWNER/REPO --cutoff UTC [--limit 50]');
    }
    fields[key] = value;
  }
  if (!fields['--repository'] || !fields['--cutoff'] ||
      fields['--limit'] !== undefined && !/^[1-9]\d*$/.test(fields['--limit'])) throw new TypeError('Invalid inventory arguments');
  return {repository: fields['--repository'], cutoff: fields['--cutoff'],
    limit: fields['--limit'] === undefined ? 50 : Number(fields['--limit'])};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const report = await collectRunInventory(ghJSON, inventoryArguments(process.argv.slice(2)));
    process.stdout.write(JSON.stringify(report, null, 2) + '\n');
  } catch (error) {
    process.stderr.write(`ci_time_inventory: ${error.message}\n`);
    process.exitCode = 1;
  }
}
