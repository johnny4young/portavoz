#!/usr/bin/env node
// Keeps one issue open while the newest pull request heads miss the CI time SLO.
// Reads Actions metadata, compare file lists and build-and-test logs; never a head's checkout or artifacts.
import {execFile} from 'node:child_process';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {promisify} from 'node:util';
import {ghJSON, ghText, readExactRun} from './ci_time_github.mjs';
import {collectRunInventory} from './ci_time_inventory.mjs';
import {blockingJobs} from './ci_time_workflow.mjs';
import {nearestRank} from './ci_time_metrics.mjs';

export const ISSUE_TITLE = 'CI time is over its SLO';
const ISSUE_AUTHOR = 'github-actions[bot]';
export const DEFAULT_LIMITS = Object.freeze({execution: 600, total: 1200});
const EXEMPT_JOBS = new Set(['interruption', 'interruption-controls']);
const UI_JOBS = new Set(['ui-tests', 'build-ui-products', 'scoped-ui-tests']);
const MACOS_JOBS = new Set(['build-and-test', 'ui-tests', 'interruption', 'ios-portability',
  'build-ui-products', 'scoped-ui-tests', 'interruption-controls']);
const XCODE_PIN_FILE = 'scripts/verify-ci-toolchain.sh';
const XCODE_PIN = /^[-+].*Xcode_\d/m;
const LOG_LINE = String.raw`^\S+Z `;
const CACHE_PATTERNS = [
  ['rejected', new RegExp(LOG_LINE + String.raw`##\[warning\]Cached Swift build state failed freshness`, 'm')],
  ['fallback', new RegExp(LOG_LINE + 'Cache hit for restore-key: ', 'm')],
  ['exact', new RegExp(LOG_LINE + 'Cache hit for: ', 'm')],
  ['miss', new RegExp(LOG_LINE + 'Cache not found for input keys', 'm')],
];
const SWIFT_SCOPE = new RegExp(LOG_LINE + String.raw`\s*PORTAVOZ_SWIFT_TEST_SCOPE: ?(.*)$`, 'm');

const base = name => name.split(' (', 1)[0];
const time = value => (typeof value === 'string' ? Date.parse(value) : NaN);
const seconds = (start, end) => {
  const first = time(start), last = time(end);
  return Number.isFinite(first) && Number.isFinite(last) && last >= first ? Math.round((last - first) / 1000) : null;
};

export function parseLimit(value, fallback) {
  if (value === undefined || value === '') return fallback;
  if (!/^[1-9]\d{0,5}$/.test(String(value))) throw new TypeError(`Invalid limit: ${value}`);
  return Number(value);
}

export function buildLogDigest(log) {
  if (typeof log !== 'string') return {cache: 'unknown', coverage: 'unknown'};
  const clean = log.replace(/\x1b\[[0-9;]*m/g, '');
  const cache = CACHE_PATTERNS.find(([, pattern]) => pattern.test(clean))?.[0] ?? 'unknown';
  const scope = SWIFT_SCOPE.exec(clean);
  return {cache, coverage: scope === null ? 'unknown' : scope[1].trim() ? 'contract-only' : 'full'};
}

export function exemptFromChanges(changes) {
  if (changes === null) return false;
  return changes.files.includes(XCODE_PIN_FILE) || XCODE_PIN.test(changes.workflowPatches);
}

// Mirrors scripts/ci_time_report.py: the longest fresh blocking job, and attempt start to its last end.
export function attemptRow({run, attempt, changes, buildLog, prRunStarts}) {
  const fresh = attempt.jobs.filter(job => job.run_attempt === attempt.metadata.run_attempt);
  const timed = fresh.filter(job => blockingJobs.pull_request.has(base(job.name)) && job.runner_id > 0)
    .map(job => ({job, duration: seconds(job.started_at, job.completed_at)}))
    .filter(entry => entry.duration !== null);
  const longest = timed.reduce((best, entry) => (!best || entry.duration > best.duration ? entry : best), null);
  const start = attempt.metadata.run_started_at;
  const end = timed.map(entry => entry.job.completed_at).sort().at(-1);
  const ends = fresh.map(job => job.completed_at).filter(Boolean).sort();
  const superseded = attempt.metadata.conclusion === 'cancelled' && ends.length > 0 &&
    prRunStarts.some(created => time(created) > time(start) && time(created) <= time(ends.at(-1)));
  const exempt = exemptFromChanges(changes) ||
    timed.some(entry => EXEMPT_JOBS.has(base(entry.job.name)));
  const queues = fresh.filter(job => MACOS_JOBS.has(base(job.name)) && job.runner_id > 0)
    .map(job => seconds(job.created_at, job.started_at)).filter(value => value !== null);
  const digest = buildLogDigest(buildLog);
  return {runId: run.id, attempt: attempt.metadata.run_attempt, head: run.head_sha,
    url: `https://github.com/${run.repository.full_name}/actions/runs/${run.id}/attempts/${attempt.metadata.run_attempt}`,
    execution: longest?.duration ?? null, total: end ? seconds(start, end) : null,
    longestJob: longest ? base(longest.job.name) : null, superseded, ordinary: !exempt,
    filesKnown: changes !== null, macosQueue: queues.length ? Math.max(...queues) : null,
    cache: digest.cache, coverage: fresh.some(job => UI_JOBS.has(base(job.name)) && job.runner_id > 0)
      ? `${digest.coverage}+ui` : digest.coverage};
}

const distribution = values => {
  const present = values.filter(value => value !== null);
  return present.length ? {n: present.length, p50: nearestRank(present, 0.5), p95: nearestRank(present, 0.95),
    max: Math.max(...present)} : null;
};
const counts = values => Object.fromEntries([...values.reduce((map, value) =>
  map.set(value, (map.get(value) ?? 0) + 1), new Map())].sort(([a], [b]) => a.localeCompare(b)));

export function summarize(rows, limits = DEFAULT_LIMITS) {
  const included = rows.filter(row => row.ordinary && !row.superseded);
  const execution = distribution(included.map(row => row.execution));
  const total = distribution(included.map(row => row.total));
  if (!execution || !total) throw new Error('No ordinary attempt has a measured execution and total');
  return {limits, attempts: included.length, heads: new Set(included.map(row => row.head)).size,
    missing: included.filter(row => row.execution === null || row.total === null).length,
    filesUnknown: included.filter(row => !row.filesKnown).length,
    execution, total, queue: distribution(included.map(row => row.macosQueue)),
    cache: counts(included.map(row => row.cache)), coverage: counts(included.map(row => row.coverage)),
    executionBreached: execution.p95 > limits.execution, totalBreached: total.p95 > limits.total,
    slowest: [...included].sort((a, b) => (b.total ?? -1) - (a.total ?? -1)).slice(0, 5)};
}

const clock = value => (value === null || value === undefined ? 'n/a'
  : `${Math.floor(value / 60)}:${String(value % 60).padStart(2, '0')}`);
const line = (name, block) => (block ? `| ${name} | ${block.n} | ${clock(block.p50)} | ${clock(block.p95)} | ${clock(block.max)} |`
  : `| ${name} | 0 | n/a | n/a | n/a |`);

export function issueBody(summary, {headsRequested, runUrl}) {
  const breaches = [summary.executionBreached && `execution p95 ${clock(summary.execution.p95)} > ${clock(summary.limits.execution)}`,
    summary.totalBreached && `total p95 ${clock(summary.total.p95)} > ${clock(summary.limits.total)}`].filter(Boolean);
  const entries = object => Object.entries(object).map(([key, value]) => `${key} ${value}`).join(', ');
  const verdict = breaches.length ? `Over the SLO on the newest ${headsRequested} pull request heads: ${breaches.join('; ')}.`
    : `Within the SLO on the newest ${headsRequested} pull request heads.`;
  return [verdict, '',
    `${summary.attempts} ordinary attempts on ${summary.heads} heads; ${summary.missing} without a measurement, ` +
      `${summary.filesUnknown} with unknown files.`, '',
    '| Metric | N | p50 | p95 | Max |', '|---|--:|--:|--:|--:|',
    line('Execution', summary.execution), line('Total', summary.total), line('Longest macOS queue', summary.queue), '',
    `Cache: ${entries(summary.cache)}.`, `Coverage: ${entries(summary.coverage)}.`, '',
    'Slowest attempts by total:', '',
    ...summary.slowest.map(row => `- ${row.url}: total ${clock(row.total)}, execution ${clock(row.execution)} ` +
      `(${row.longestJob ?? 'unknown'}), macOS queue ${clock(row.macosQueue)}, cache ${row.cache}, ${row.coverage}`), '',
    `Report: \`python3 scripts/ci_time_report.py --heads ${headsRequested}\`. Alarm run: ${runUrl}`].join('\n');
}

export function issueAction(summary, openNumber) {
  const breached = summary.executionBreached || summary.totalBreached;
  if (breached) return openNumber === null ? {kind: 'create'} : {kind: 'edit', number: openNumber};
  return openNumber === null ? {kind: 'none'} : {kind: 'close', number: openNumber};
}

// ghText refuses any path with "..", so the three-dot compare gets its own validated read.
export async function ghCompare(repository, ref, sha) {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) || !/^[A-Za-z0-9._/-]{1,200}$/.test(ref) ||
      ref.includes('..') || !/^[0-9a-f]{40}$/.test(sha)) throw new TypeError('Invalid compare identity');
  return JSON.parse(await gh(['api', `repos/${repository}/compare/${ref}...${sha}`]));
}

async function changesFor(compare, repository, run) {
  const bases = [...new Set([...run.pull_requests.map(pr => pr.base?.ref).filter(Boolean), 'main'])];
  for (const ref of bases) {
    try {
      const result = await compare(repository, ref, run.head_sha);
      const files = result.files ?? [];
      return {files: files.map(entry => entry.filename), workflowPatches: files
        .filter(entry => entry.filename.startsWith('.github/workflows/')).map(entry => entry.patch ?? '').join('')};
    } catch { /* try the next base */ }
  }
  return null;
}

export async function collectRows({get, getText, compare}, {repository, heads, cutoff}) {
  // Over-select so in-flight heads can be left out and still fill the window.
  const inventory = await collectRunInventory(get, {repository, cutoff, limit: Math.min(100, heads + 10)});
  const finished = inventory.heads.filter(head => head.runs.every(run => run.status === 'completed')).slice(0, heads);
  if (finished.length < heads) throw new Error(`Only ${finished.length} finished heads of ${heads}`);
  const prRunStarts = new Map();
  for (const run of inventory.heads.flatMap(head => head.runs)) {
    for (const number of run.prNumbers) prRunStarts.set(number, [...(prRunStarts.get(number) ?? []), run.createdAt]);
  }
  const rows = [];
  for (const head of finished) {
    for (const entry of head.runs) {
      const prNumber = entry.prNumbers.length === 1 ? entry.prNumbers[0] : null;
      const evidence = await readExactRun(get, {repository, runId: entry.runId, headSha: head.headSha, prNumber});
      const changes = await changesFor(compare, repository, evidence.run);
      const starts = entry.prNumbers.flatMap(number => prRunStarts.get(number) ?? []);
      for (const attempt of evidence.attempts) {
        const build = attempt.jobs.find(job => job.name === 'build-and-test' &&
          job.run_attempt === attempt.metadata.run_attempt && job.runner_id > 0);
        let buildLog = null;
        if (build) {
          try { buildLog = await getText(`repos/${repository}/actions/jobs/${build.id}/logs`); } catch { buildLog = null; }
        }
        rows.push(attemptRow({run: evidence.run, attempt, changes, buildLog, prRunStarts: starts}));
      }
    }
  }
  return rows;
}

const execFileAsync = promisify(execFile);
async function gh(args) {
  const {stdout} = await execFileAsync('gh', args, {encoding: 'utf8', timeout: 60_000, maxBuffer: 4 * 1024 * 1024});
  return stdout;
}

async function openIssueNumber() {
  // A plain listing, because the search index can lag behind an issue opened moments ago.
  const found = JSON.parse(await gh(['issue', 'list', '--state', 'open', '--author', ISSUE_AUTHOR,
    '--limit', '100', '--json', 'number,title']));
  return found.find(issue => issue.title === ISSUE_TITLE)?.number ?? null;
}

export function sloArguments(args, env = {}) {
  const fields = {};
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index], value = args[index + 1];
    if (!['--repository', '--heads', '--run-url'].includes(key) || !value || key in fields) {
      throw new TypeError('Usage: ci_time_slo.mjs --repository OWNER/REPO --run-url URL [--heads 20]');
    }
    fields[key] = value;
  }
  const repository = fields['--repository'] ?? '';
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) || repository.includes('..') || !fields['--run-url']) {
    throw new TypeError('Missing or invalid --repository or --run-url');
  }
  const heads = parseLimit(fields['--heads'], 20);
  if (heads > 90) throw new TypeError('At most 90 heads');
  return {repository: fields['--repository'], runUrl: fields['--run-url'], heads,
    limits: {execution: parseLimit(env.SLO_EXECUTION_SECONDS, DEFAULT_LIMITS.execution),
      total: parseLimit(env.SLO_TOTAL_SECONDS, DEFAULT_LIMITS.total)},
    dryRun: env.SLO_DRY_RUN === 'true'};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = sloArguments(process.argv.slice(2), process.env);
    const cutoff = new Date(Date.now() - 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
    const rows = await collectRows({get: ghJSON, getText: ghText, compare: ghCompare}, {repository: options.repository, heads: options.heads, cutoff});
    const summary = summarize(rows, options.limits);
    const body = issueBody(summary, {headsRequested: options.heads, runUrl: options.runUrl});
    process.stdout.write(`${body}\n`);
    if (!options.dryRun) {
      const action = issueAction(summary, await openIssueNumber());
      if (action.kind === 'create') await gh(['issue', 'create', '--title', ISSUE_TITLE, '--body', body]);
      // Editing keeps the current numbers without a notification every day.
      if (action.kind === 'edit') await gh(['issue', 'edit', String(action.number), '--body', body]);
      if (action.kind === 'close') {
        await gh(['issue', 'close', String(action.number), '--comment',
          `Back within the SLO: execution p95 ${clock(summary.execution.p95)}, total p95 ${clock(summary.total.p95)}. ${options.runUrl}`]);
      }
      process.stdout.write(`Issue action: ${action.kind}\n`);
    }
    if (summary.executionBreached || summary.totalBreached) process.stdout.write('::warning::CI time is over its SLO\n');
  } catch (error) {
    // An unreadable history is an unknown state, never a healthy one.
    process.stderr.write(`::error::CI time SLO is unknown: ${error.message}\n`);
    process.exitCode = 1;
  }
}
