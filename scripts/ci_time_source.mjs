#!/usr/bin/env node
// Recover immutable checkout source observations, not workflow execution attestation.
import {createHash} from 'node:crypto';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {ghJSON, ghText, readExactRun} from './ci_time_github.mjs';

const sha = value => typeof value === 'string' && /^[a-f0-9]{40}$/.test(value);
const positive = value => Number.isSafeInteger(value) && value > 0;
const digest = value => createHash('sha256').update(value).digest('hex');
const repositoryOK = value => typeof value === 'string' &&
  /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(value) && !value.includes('..');
const workflowPath = '.github/workflows/ci.yml';

export function checkoutObservation(log, repository) {
  if (!repositoryOK(repository) || typeof log !== 'string' || Buffer.byteLength(log) > 16 * 1024 * 1024) return null;
  const lines = log.split(/\r?\n/).map(line => line.replace(/^\d{4}-\d{2}-\d{2}T\S+Z /, ''));
  const starts = lines.flatMap((line, index) => line.startsWith('##[group]Run actions/checkout@') ? [index] : []);
  if (starts.length !== 1) return null;
  const start = starts[0], action = /^##\[group\]Run actions\/checkout@([a-f0-9]{40})$/.exec(lines[start]);
  if (!action) return null;
  const following = lines.findIndex((line, index) => index > start && /^##\[group\](?:Run |Post )/.test(line));
  const segment = lines.slice(start + 1, following === -1 ? lines.length : following);
  const repositories = segment.flatMap((line, index) => line.startsWith('Syncing repository: ') ? [index] : []);
  if (repositories.length !== 1 || segment[repositories[0]] !== `Syncing repository: ${repository}`) return null;
  const commits = [];
  for (let i = 0; i < segment.length; i++) {
    if (/^\[command\](?:\/[^\s]+\/)?git log -1 --format=%H$/.test(segment[i])) {
      if (i <= repositories[0] || !sha(segment[i + 1])) return null;
      commits.push(segment[i + 1]);
    }
  }
  if (commits.length !== 1) return null;
  return {checkoutCommit: commits[0], checkoutAction: action[1], logSha256: digest(log)};
}

export async function historicalWorkflow(get, {repository, checkoutCommit, headSha}) {
  if (!repositoryOK(repository) || !sha(checkoutCommit) || !sha(headSha)) throw new Error('Invalid source identity');
  const root = `repos/${repository}/git`;
  const commit = await get(`${root}/commits/${checkoutCommit}`);
  if (commit?.sha !== checkoutCommit || !sha(commit.tree?.sha) || !Array.isArray(commit.parents) ||
    commit.parents.length !== 2 || !commit.parents.every(p => sha(p.sha)) ||
    commit.parents[1].sha !== headSha || commit.parents[0].sha === headSha) throw new Error('Unproven merge parents');
  let treeSha = commit.tree.sha, blobSha;
  const parts = workflowPath.split('/');
  for (let index = 0; index < parts.length; index++) {
    const tree = await get(`${root}/trees/${treeSha}`);
    if (tree?.sha !== treeSha || tree.truncated !== false || !Array.isArray(tree.tree) ||
      new Set(tree.tree.map(entry => entry.path)).size !== tree.tree.length) throw new Error('Invalid source tree');
    const entry = tree.tree.find(entry => entry.path === parts[index]);
    const leaf = index === parts.length - 1;
    if (!entry || !sha(entry.sha) || (leaf ? entry.type !== 'blob' || !['100644', '100755'].includes(entry.mode)
      : entry.type !== 'tree' || entry.mode !== '040000')) throw new Error('Unsupported source path');
    if (leaf) blobSha = entry.sha; else treeSha = entry.sha;
  }
  const blob = await get(`${root}/blobs/${blobSha}`);
  if (blob?.sha !== blobSha || blob.encoding !== 'base64' || !positive(blob.size) || blob.size > 1024 * 1024 ||
    typeof blob.content !== 'string' || blob.content.length > 2 * 1024 * 1024) throw new Error('Invalid source blob');
  const encoded = blob.content.replace(/\n/g, '');
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) throw new Error('Invalid base64');
  const bytes = Buffer.from(encoded, 'base64');
  const computed = createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
  const text = new TextDecoder('utf-8', {fatal: true, ignoreBOM: true}).decode(bytes);
  if (bytes.length !== blob.size || computed !== blobSha || text.includes('\0')) throw new Error('Source bytes mismatch');
  return {checkoutCommit, baseParent: commit.parents[0].sha, headParent: headSha,
    workflow: {path: workflowPath, blobSha, sha256: digest(bytes), bytes: bytes.length, text}};
}

function runSnapshot(run) {
  return JSON.stringify([run?.id, run?.head_sha, run?.workflow_id, run?.path, run?.event,
    run?.repository?.full_name, run?.status, run?.conclusion, run?.run_attempt,
    run?.created_at, run?.updated_at, run?.pull_requests?.map(p => [p.number, p.head?.sha])]);
}

export async function collectHistoricalSources(get, getText, evidence) {
  evidence = structuredClone(evidence);
  const {repository, run, attempts} = evidence;
  if (!repositoryOK(repository) || !positive(run?.id) || !positive(run.workflow_id) || !sha(run.head_sha) ||
    run.path !== workflowPath || run.event !== 'pull_request' || run.status !== 'completed' ||
    run.repository?.full_name !== repository || !positive(run.run_attempt) || run.run_attempt > 1000 ||
    !Array.isArray(attempts) || attempts.length !== run.run_attempt || attempts.some((a, i) =>
      a.metadata?.run_attempt !== i + 1 || a.ownershipVerified !== true || a.jobsComplete !== true || !Array.isArray(a.jobs))) {
    throw new Error('Invalid exact-run evidence');
  }
  const root = `repos/${repository}/actions/runs/${run.id}`, snapshot = runSnapshot(run);
  const results = [], immutable = new Map();
  const cached = async path => {
    if (!immutable.has(path)) immutable.set(path, structuredClone(await get(path)));
    return immutable.get(path);
  };
  const unknown = (attempt, status) => ({attempt, status, verified: false});
  let stable = false;
  try { stable = runSnapshot(await get(root)) === snapshot; } catch { /* Explicit unavailable source. */ }
  for (const attempt of attempts) {
    const number = attempt.metadata.run_attempt;
    if (!stable) { results.push(unknown(number, 'stale-or-unavailable-run')); continue; }
    // Keep the historical name as evidence; never choose between two scope jobs.
    const jobs = [attempt.jobs.filter(job => ['scope', 'swift-scope'].includes(job.name)),
      attempt.jobs.filter(job => job.name === 'build-and-test')];
    if (jobs.some(rows => rows.length !== 1 || !positive(rows[0].id) || !positive(rows[0].runner_id) ||
      rows[0].run_id !== run.id || rows[0].head_sha !== run.head_sha || rows[0].run_attempt !== number ||
      rows[0].status !== 'completed') || jobs[0][0].id === jobs[1][0].id) {
      results.push(unknown(number, 'missing-current-scope-or-build')); continue;
    }
    try {
      const logs = [];
      for (const [job] of jobs) {
        const path = `repos/${repository}/actions/jobs/${job.id}/logs`;
        const observation = checkoutObservation(await getText(path), repository);
        if (!observation) throw new Error('Ambiguous checkout');
        logs.push({jobId: job.id, jobName: job.name, source: `https://api.github.com/${path}`, ...observation});
      }
      if (logs[0].checkoutCommit !== logs[1].checkoutCommit) throw new Error('Checkout disagreement');
      const source = await historicalWorkflow(cached, {repository, checkoutCommit: logs[0].checkoutCommit, headSha: run.head_sha});
      results.push({attempt: number, status: 'observed', verified: false, logs, source});
    } catch { results.push(unknown(number, 'unavailable-or-inconsistent-source')); }
  }
  try { stable = stable && runSnapshot(await get(root)) === snapshot; } catch { stable = false; }
  const final = stable ? results : results.map(row => unknown(row.attempt, 'stale-or-unavailable-run'));
  return {schemaVersion: 1, repository, runId: run.id, headSha: run.head_sha,
    attempts: final, observedAttempts: final.filter(row => row.status === 'observed').length,
    expectedAttempts: attempts.length, acceptance: null,
    limitations: ['Checkout logs are observations, not independent attestation of the workflow GitHub executed.',
      'Two current-attempt jobs must agree; missing, carried or ambiguous observations remain unknown.',
      'Git trees bind the retained workflow bytes to the observed merge with the requested head as second parent.',
      'No current branch, guessed PR base, download URL, actor metadata or raw logs are retained.',
      'Historical scope/selection, continue-on-error semantics, receipts, cache and ordinary cohort remain unverified.']};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [repository, id, headSha, ...rest] = process.argv.slice(2);
    if (rest.length || !/^\d+$/.test(id ?? '') || !repositoryOK(repository) || !sha(headSha)) {
      throw new Error('Usage: ci_time_source.mjs OWNER/REPO RUN_ID HEAD_SHA');
    }
    const boundedGet = async path => {
      const value = await ghJSON(path);
      if (path === `repos/${repository}/actions/runs/${Number(id)}` && value.run_attempt > 1000) throw new Error('Too many attempts');
      return value;
    };
    const evidence = await readExactRun(boundedGet, {repository, runId: Number(id), headSha});
    const result = await collectHistoricalSources(boundedGet, ghText, evidence);
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
    if (result.observedAttempts !== result.expectedAttempts) process.exitCode = 2;
  } catch { process.stderr.write('ci_time_source: invalid input or unavailable exact-run evidence\n'); process.exitCode = 1; }
}
