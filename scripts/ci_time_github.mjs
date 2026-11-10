// Read-only GitHub Actions evidence for one exact completed CI run.
// This module does not infer scope, aggregate a cohort, or claim acceptance.
import {createHash} from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const SHA = /^[0-9a-f]{40}$/;
const positive = value => Number.isSafeInteger(value) && value > 0;
const validTimestamp = value => typeof value === 'string' &&
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(value) &&
  Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 19) === value.slice(0, 19);
const STABLE_JOB_FIELDS = ['id', 'run_id', 'head_sha', 'run_attempt', 'name',
  'created_at', 'started_at', 'completed_at', 'conclusion', 'runner_id', 'status'];

export async function ghText(path) {
  if (typeof path !== 'string' || !path.startsWith('repos/') || path.includes('..')) {
    throw new TypeError('Invalid GitHub API path');
  }
  // Logs contain ANSI from echoed steps. Capture them for parsing/hashing only;
  // neither CLI emits raw logs, and JSON reads keep gh's default protection.
  const log = /^repos\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/actions\/jobs\/[1-9]\d*\/logs$/.test(path);
  const {stdout} = await execFileAsync('gh', ['api', ...(log ? ['--allow-escape-sequences'] : []), path], {encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
    timeout: 180_000});
  return stdout;
}

export async function ghJSON(path) { return JSON.parse(await ghText(path)); }

export async function allPages(get, path, key, pageSize = 100) {
  if (!positive(pageSize) || pageSize > 100) throw new RangeError('Invalid page size');
  const entries = [];
  const ids = new Set();
  let expected = null;
  for (let page = 1; page <= 100; page++) {
    const separator = path.includes('?') ? '&' : '?';
    const body = await get(`${path}${separator}per_page=${pageSize}&page=${page}`);
    if (!Number.isSafeInteger(body?.total_count) || body.total_count < 0 || !Array.isArray(body[key]) ||
      body[key].length > pageSize) throw new Error('Invalid paginated response');
    if (expected === null) expected = body.total_count;
    if (expected !== body.total_count) throw new Error('Page total changed during collection');
    for (const item of body[key]) {
      if (!positive(item.id) || ids.has(item.id)) throw new Error('Missing or duplicated item ID');
      ids.add(item.id); entries.push(item);
    }
    if (entries.length > expected) throw new Error('More items than reported');
    if (entries.length === expected) return entries;
    if (body[key].length < pageSize) throw new Error('Incomplete paginated response');
  }
  throw new Error('Pagination exceeded safety limit');
}

export async function readExactRun(get, {repository, runId, headSha, prNumber = null}) {
  if (!REPOSITORY.test(repository) || repository.includes('..') || !positive(runId) || !SHA.test(headSha) || (prNumber !== null && !positive(prNumber))) {
    throw new TypeError('Invalid repository, run ID, or head SHA');
  }
  const associationIdentity = value => JSON.stringify(value.pull_requests.map(pr =>
    [pr.number, pr.head.sha]).sort((a, b) => a[0] - b[0]));
  const root = `repos/${repository}/actions/runs/${runId}`;
  const run = await get(root);
  const valid = value => value?.id === runId && value.head_sha === headSha &&
    value.path === '.github/workflows/ci.yml' && value.event === 'pull_request' &&
    value.status === 'completed' && value.repository?.full_name === repository &&
    positive(value.workflow_id) && Array.isArray(value.pull_requests) &&
    value.pull_requests.every(pr => positive(pr.number) && pr.head?.sha === headSha) &&
    new Set(value.pull_requests.map(pr => pr.number)).size === value.pull_requests.length &&
    (prNumber === null || value.pull_requests.length === 0 || value.pull_requests.some(pr => pr.number === prNumber)) &&
    positive(value.run_attempt) && validTimestamp(value.created_at) && validTimestamp(value.updated_at);
  if (!valid(run)) throw new Error('Run identity or state mismatch');
  const association = value => prNumber !== null && value.pull_requests.length ? 'verified' : 'unknown';
  const prAssociation = {status: association(run), prNumber: association(run) === 'verified' ? prNumber : null, source: run.pull_requests.length ? (prNumber === null ? 'run-api-unattributed-pull-requests' : 'run-api-pull-requests') : 'run-api-empty-pull-requests'};
  const attempts = [];
  const earlierJobs = new Map();
  for (let number = 1; number <= run.run_attempt; number++) {
    const metadata = await get(`${root}/attempts/${number}`);
    // Attempt creation is independent of workflow creation, especially on reruns.
    // Keep both timestamps; only the run root defines the total-time origin.
    if (!valid(metadata) || associationIdentity(metadata) !== associationIdentity(run) || metadata.run_attempt !== number || metadata.workflow_id !== run.workflow_id ||
      Date.parse(metadata.created_at) < Date.parse(run.created_at) ||
      Date.parse(metadata.created_at) > Date.parse(metadata.updated_at) ||
      Date.parse(metadata.created_at) > Date.parse(run.updated_at) ||
      typeof metadata.run_started_at !== 'string') throw new Error('Attempt identity mismatch');
    if (number === run.run_attempt && metadata.conclusion !== run.conclusion) {
      throw new Error('Latest attempt conclusion contradicts run');
    }
    const jobs = await allPages(get, `${root}/attempts/${number}/jobs`, 'jobs');
    for (const job of jobs) {
      const optionalText = value => value === null || value === undefined || (typeof value === 'string' && value.length <= 128);
      if (job.run_id !== runId || job.head_sha !== headSha || !positive(job.run_attempt) ||
        job.run_attempt > number || job.status !== 'completed' || typeof job.name !== 'string' ||
        job.name.length === 0 || job.name.length > 1024 || !optionalText(job.conclusion) ||
        ![job.created_at, job.started_at, job.completed_at].every(optionalText) ||
        !(job.runner_id === null || job.runner_id === undefined || job.runner_id === 0 || positive(job.runner_id))) {
        throw new Error('Job identity or shape mismatch');
      }
      if (job.run_attempt < number) {
        const earlier = earlierJobs.get(job.id);
        if (!earlier || STABLE_JOB_FIELDS.some(field => earlier[field] !== job[field]) ||
            JSON.stringify(earlier.steps) !== JSON.stringify(job.steps)) {
          throw new Error('Unproven carried job');
        }
      } else {
        if (earlierJobs.has(job.id)) throw new Error('Job ID reused by another attempt');
        earlierJobs.set(job.id, job);
      }
    }
    attempts.push({metadata, jobs, ownershipVerified: true, jobsComplete: true});
  }
  const after = await get(root);
  if (!valid(after) || associationIdentity(after) !== associationIdentity(run) || after.run_attempt !== run.run_attempt || after.workflow_id !== run.workflow_id || after.created_at !== run.created_at ||
    after.updated_at !== run.updated_at) throw new Error('Run changed during collection');
  return {repository, run, attempts, prAssociation};
}

// Read only the gate's own emitted environment block; absent, duplicate or
// contradictory fields are unknown rather than guessed from job conclusions.
export function scopeFromGateLog(log) {
  if (typeof log !== 'string') return null;
  const lines = log.split('\n').map(line => line.replace(/^\S+Z /, '').replace(/\x1b\[[0-9;]*m/g, ''));
  const candidates = [];
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim() !== 'env:') continue;
    const values = new Map();
    let duplicate = false;
    let ended = false;
    for (i++; i < lines.length; i++) {
      if (lines[i].includes('##[endgroup]')) { ended = true; break; }
      const match = /^  ([A-Z_]+): (.*)$/.exec(lines[i]);
      if (!match) continue;
      if (values.has(match[1])) duplicate = true;
      values.set(match[1], match[2].trim());
    }
    const keys = ['EVENT_NAME', 'SCOPE_RESULT', 'IOS_REQUIRED', 'UI_REQUIRED', 'CONTROLS_REQUIRED',
      'IOS_RESULT', 'UI_RESULT', 'CONTROLS_RESULT'];
    if (!keys.every(key => values.has(key))) continue;
    if (duplicate || !ended) return null;
    candidates.push(values);
  }
  if (candidates.length !== 1) return null;
  const v = candidates[0];
  if (v.get('EVENT_NAME') !== 'pull_request' || v.get('SCOPE_RESULT') !== 'success') return null;
  const flag = key => v.get(key) === 'true' ? true : v.get(key) === 'false' ? false : null;
  const iosRequired = flag('IOS_REQUIRED'), uiRequired = flag('UI_REQUIRED');
  const interruptionRequired = flag('CONTROLS_REQUIRED');
  if ([iosRequired, uiRequired, interruptionRequired].includes(null) || (!uiRequired && interruptionRequired)) return null;
  if ((!iosRequired && v.get('IOS_RESULT') !== 'skipped') || (!uiRequired && v.get('UI_RESULT') !== 'skipped') ||
      (!interruptionRequired && v.get('CONTROLS_RESULT') !== 'skipped')) return null;
  return {verified: false, source: 'unattested-gate-log', iosRequired, uiRequired, interruptionRequired};
}

export function utcTimestamp(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)) return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) && new Date(parsed).toISOString() === value.replace('Z', '.000Z') ? parsed : null;
}

// Discover the newest distinct head SHAs without silently dropping in-flight
// runs. Selection is separate from collecting all runs/attempts for each head.
export async function discoverHeads(get, {repository, limit = 50, cutoff, pageSize = 100}) {
  if (!REPOSITORY.test(repository) || repository.includes('..') || !positive(limit) ||
      !positive(pageSize) || pageSize > 100 || utcTimestamp(cutoff) === null) throw new TypeError('Invalid discovery input');
  const root = `repos/${repository}/actions/workflows/ci.yml/runs?event=pull_request&created=${encodeURIComponent("<=" + cutoff)}`;
  const seenIds = new Set(), heads = new Map(), pages = [];
  let expected = null, previous = Infinity, boundary = null, olderSeen = false, boundaryTie = false;
  for (let page = 1; page <= 100; page++) {
    const path = `${root}&per_page=${pageSize}&page=${page}`;
    const body = await get(path);
    if (!Number.isSafeInteger(body?.total_count) || body.total_count < 0 || !Array.isArray(body.workflow_runs) ||
      body.workflow_runs.length > pageSize) throw new Error('Invalid run page');
    if (expected === null) expected = body.total_count;
    if (body.total_count !== expected) throw new Error('Run total changed during discovery');
    pages.push({path, snapshot: JSON.stringify(body)});
    for (const run of body.workflow_runs) {
      const time = utcTimestamp(run.created_at);
      if (!positive(run.id) || seenIds.has(run.id) || !SHA.test(run.head_sha) || time === null ||
        time > previous || run.event !== 'pull_request') throw new Error('Invalid or unstable run order');
      seenIds.add(run.id); previous = time;
      if (time > Date.parse(cutoff)) continue;
      if (boundary !== null && time < boundary) olderSeen = true;
      if (heads.has(run.head_sha)) { heads.get(run.head_sha).runs.push(run); continue; }
      if (heads.size < limit) {
        heads.set(run.head_sha, {headSha: run.head_sha, firstSeenAt: run.created_at, runs: [run]});
        if (heads.size === limit) boundary = time;
      } else if (time === boundary) boundaryTie = true;
    }
    if (seenIds.size > expected) throw new Error('More runs than reported');
    const exhausted = seenIds.size === expected;
    if (exhausted && expected >= 1000 && !olderSeen) {
      throw new Error("Run discovery reached the 1000-result ceiling without a proven head boundary");
    }
    if (body.workflow_runs.length < pageSize && !exhausted) throw new Error('Incomplete run page');
    if (exhausted || (boundary !== null && olderSeen)) {
      for (const saved of pages) {
        if (JSON.stringify(await get(saved.path)) !== saved.snapshot) throw new Error('Run page changed during discovery');
      }
      return {heads: [...heads.values()], cutoff, selectionComplete: !boundaryTie,
        boundaryTie, fetchedRuns: seenIds.size, exhausted,
        oldestFetchedAt: seenIds.size ? new Date(previous).toISOString().replace(".000Z", "Z") : null};
    }
  }
  throw new Error('Run pagination exceeded safety limit');
}

// An exact job endpoint binds these observations to a run/attempt, not to a
// trusted workflow definition or complete executed-test receipt. Never promote
// the log parser's flags to verified scope merely because the gate is green.
export async function collectGateScopeObservations(getText, evidence) {
  const {repository, run} = evidence;
  if (!REPOSITORY.test(repository) || repository.includes('..') || !positive(run?.id) ||
      !SHA.test(run.head_sha) || run.event !== 'pull_request' || run.path !== '.github/workflows/ci.yml') {
    throw new Error('Invalid scope observation identity');
  }
  const attempts = [];
  for (const attempt of evidence.attempts) {
    const unknown = status => ({...attempt, scopeObservation: {status, verified: false}});
    if (attempt.ownershipVerified !== true || attempt.jobsComplete !== true) {
      attempts.push(unknown('unverified-inventory')); continue;
    }
    const gates = attempt.jobs.filter(job => job.name === 'gate');
    const gate = gates.length === 1 ? gates[0] : null;
    if (!gate || !positive(gate.id) || !positive(attempt.metadata.run_attempt) || gate.run_id !== run.id ||
        gate.head_sha !== run.head_sha || gate.run_attempt !== attempt.metadata.run_attempt ||
        gate.status !== 'completed' || !positive(gate.runner_id)) {
      attempts.push(unknown('missing-exact-gate')); continue;
    }
    const path = `repos/${repository}/actions/jobs/${gate.id}/logs`;
    let log;
    try { log = await getText(path); } catch { attempts.push(unknown('unavailable')); continue; }
    if (typeof log !== 'string' || Buffer.byteLength(log, 'utf8') > 16 * 1024 * 1024) {
      attempts.push(unknown('invalid-log')); continue;
    }
    const selection = scopeFromGateLog(log);
    attempts.push({...attempt, scopeObservation: {status: selection ? 'observed' : 'unparseable',
      verified: false, source: `https://api.github.com/${path}`, runId: run.id, head: run.head_sha,
      jobId: gate.id, attempt: gate.run_attempt, sha256: createHash('sha256').update(log).digest('hex'),
      selection, missing: ['Historical workflow and selection contract attestation',
        'Exact selected, executed and deferred receipt reconciliation', 'continue-on-error policy attestation']}});
  }
  return {...evidence, attempts};
}
