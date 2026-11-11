import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

export const testPath = 'Tests/PortavozUITests/MeetingDetailUITests.swift';
export const selector = 'PortavozUITests/MeetingDetailUITests/testMeetingReviewSurfacesRemainCompleteAndActionable';
export const order = ['before', 'after', 'after', 'before', 'before', 'after'];
const identifier = selector.replace('PortavozUITests/', '') + '()';
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const allowedPaths = new Set([testPath, '.github/workflows/ci.yml',
  'scripts/ci_time_review_comparison.mjs', 'scripts/ci_time_review_comparison.test.mjs',
  'scripts/ci_time_workflow.mjs', 'scripts/ci_time_workflow.test.mjs', 'scripts/ci_time_report.py',
  'Tests/Tooling/test_ci_workflow.py',
  'docs/ARCHITECTURE.md', 'docs/specs/08-quality.md']);

function splitCase(source) {
  assert.equal(typeof source, 'string');
  assert(source.length < 1024 * 1024, 'Oversized test source');
  const marker = '    func testMeetingReviewSurfacesRemainCompleteAndActionable() throws {';
  const start = source.indexOf(marker), closing = source.indexOf('\n    }\n', start);
  const end = closing + '\n    }\n'.length;
  assert(start >= 0 && closing > start && source.lastIndexOf(marker) === start, 'Ambiguous test boundary');
  // This known method uses four-space method boundaries, not a general Swift
  // parser. Keep everything after its closing line (including helpers) fixed.
  assert(!/^    \S/m.test(source.slice(start + marker.length, closing)), 'Unsupported method indentation');
  return {prefix: source.slice(0, start), body: source.slice(start, end), suffix: source.slice(end)};
}

// A source overlay may change only this method. The app, dependencies, runner
// helpers, build scripts and budgets must have identical Git sources.
export function validateSources({base, head, changedPaths, before, after}) {
  assert(/^[a-f0-9]{40}$/.test(base) && /^[a-f0-9]{40}$/.test(head) && base !== head, 'Invalid commit pair');
  assert(Array.isArray(changedPaths) && changedPaths.includes(testPath) &&
    changedPaths.every(p => allowedPaths.has(p)), 'Comparison changes another execution input');
  const a = splitCase(before), b = splitCase(after);
  assert.equal(a.prefix, b.prefix, 'Code before the method changed');
  assert.equal(a.suffix, b.suffix, 'Code after the method changed');
  assert.notEqual(a.body, b.body, 'Comparison has no method change');
  return {base, head, beforeSourceSHA256: sha256(before), afterSourceSHA256: sha256(after)};
}

export function measureSample({runtime, execution, outcome}) {
  assert.equal(outcome, 'success');
  assert.equal(runtime?.schemaVersion, 3); assert.equal(runtime.locale, 'en');
  assert.equal(runtime.measurementPolicy, 'xcresult-duration-with-activity-boundary-exclusions-v2');
  assert.equal(runtime.selectorCount, 1); assert.equal(runtime.caseCount, 1);
  assert.equal(runtime.tests?.length, 1);
  const test = runtime.tests[0];
  assert.equal(test.identifier, identifier); assert.equal(test.result, 'Passed');
  assert(Number.isFinite(test.durationSeconds) && test.durationSeconds >= 0, 'Invalid duration');
  assert.equal(runtime.testDurationSeconds, test.durationSeconds);
  assert.equal(execution?.schemaVersion, 1); assert.equal(execution.locale, 'en');
  assert.equal(execution.classification, 'completed'); assert.equal(execution.selectorCount, 1);
  assert.equal(execution.xcodebuildExitStatus, 0); assert.equal(execution.failureSignature, null);
  assert.equal(execution.runtimeReceiptPresent, true); assert.equal(execution.resultBundlePresent, true);
  assert(/^[a-f0-9]{64}$/.test(execution.logSHA256), 'Missing execution log digest');
  assert(['passed', 'failed'].includes(runtime.budgetStatus), 'Missing advisory budget result');
  assert(Array.isArray(runtime.budgetViolations) && runtime.budgetViolations.every(v => typeof v === 'string' && v.length > 0));
  assert.equal(runtime.budgetStatus === 'passed', runtime.budgetViolations.length === 0, 'Contradictory advisory budget result');
  return {seconds: test.durationSeconds, reportedBudgetStatus: runtime.budgetStatus};
}

export function summarizeComparison(samples) {
  assert.equal(samples.length, order.length, 'Incomplete comparison');
  assert.deepEqual(samples.map(s => s.variant), order, 'Unexpected sample order');
  const stats = variant => {
    const values = samples.filter(s => s.variant === variant).map(s => measureSample(s).seconds).sort((a, b) => a - b);
    return {n: values.length, values, median: values[1], min: values[0], max: values[2],
      above20Seconds: values.filter(v => v > 20).length};
  };
  return {before: stats('before'), after: stats('after'), acceptance: null,
    limitations: ['Six fresh-app executions share one runner; small samples do not qualify a CI p95 or establish cross-host repeatability.',
      'Build times are excluded from the comparison: the first build is cold and the second can be incremental.',
      'All case outcomes, advisory budget failures and runtime adjustments remain in the original receipts.']};
}

// Preserve framework symlinks and signatures while refusing links that would
// refer back to mutable build products after the archive moves elsewhere.
export function validateBundleLinks(root) {
  const resolvedRoot = fs.realpathSync(root);
  const visit = directory => {
    for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
      const file = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) {
        assert(!path.isAbsolute(fs.readlinkSync(file)), 'Absolute product symlink');
        const relative = path.relative(resolvedRoot, fs.realpathSync(file));
        assert(relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative), 'External product symlink');
      } else if (entry.isDirectory()) visit(file);
    }
  };
  visit(root);
}

function main() {
  assert.equal(process.env.GITHUB_ACTIONS, 'true', 'Native comparison runs only in hosted Actions');
  assert.equal(process.env.GITHUB_EVENT_NAME, 'workflow_dispatch', 'Manual comparison only');
  const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const readGit = (...args) => execFileSync('git', args, {cwd: repo, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024});
  const base = process.env.COMPARISON_BASE, head = readGit('rev-parse', 'HEAD').trim();
  assert(/^[a-f0-9]{40}$/.test(base ?? ''), 'Base must be an immutable full SHA');
  assert.equal(head, process.env.GITHUB_SHA, 'Checkout differs from workflow head');
  readGit('merge-base', '--is-ancestor', base, head);
  const sourcePath = path.join(repo, testPath), original = fs.readFileSync(sourcePath, 'utf8');
  const before = readGit('show', `${base}:${testPath}`);
  assert.equal(original, readGit('show', `${head}:${testPath}`), 'Dirty test checkout');
  const identity = validateSources({base, head, before, after: original,
    changedPaths: readGit('diff', '--name-only', base, head).trim().split('\n')});
  const output = path.join(repo, 'dist/review-comparison');
  assert(!fs.existsSync(output), 'Refusing to overwrite previous comparison evidence');
  const receipts = path.join(output, 'receipts'); fs.mkdirSync(receipts, {recursive: true});
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'portavoz-review-comparison-'));
  const manifest = {...identity, runId: process.env.GITHUB_RUN_ID, attempt: process.env.GITHUB_RUN_ATTEMPT,
    selector, order, xcode: execFileSync('xcodebuild', ['-version'], {encoding: 'utf8'}).trim(),
    os: execFileSync('sw_vers', [], {encoding: 'utf8'}).trim(), bundles: {}, samples: [], status: 'running'};
  const write = () => fs.writeFileSync(path.join(receipts, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  const run = (command, args, env = {}) => execFileSync(command, args,
    {cwd: repo, stdio: 'inherit', env: {...process.env, ...env}, timeout: 20 * 60 * 1000});
  write();
  try {
    for (const variant of ['before', 'after']) {
      fs.writeFileSync(sourcePath, variant === 'before' ? before : original);
      const build = path.join(temporary, 'build'); fs.mkdirSync(build, {recursive: true});
      run('make', ['test-ui-host-products'], {UI_TEST_PRODUCTS_PATH: path.join(build, 'products.xctestproducts'),
        UI_TEST_BUILD_RECEIPT: path.join(build, 'build-seconds.txt')});
      // Freeze both self-contained bundles without changing signed framework links.
      validateBundleLinks(build);
      const archive = path.join(temporary, `${variant}.tar`);
      run('tar', ['-cf', archive, '-C', build, '.']);
      manifest.bundles[variant] = {
        archiveSHA256: execFileSync('shasum', ['-a', '256', archive], {encoding: 'utf8'}).split(' ')[0],
        buildSeconds: fs.readFileSync(path.join(build, 'build-seconds.txt'), 'utf8').trim(),
      };
      write();
    }
    fs.writeFileSync(sourcePath, original);
    for (const variant of ['before', 'after']) {
      fs.mkdirSync(path.join(temporary, variant));
      run('tar', ['-xf', path.join(temporary, `${variant}.tar`), '-C', path.join(temporary, variant)]);
      validateBundleLinks(path.join(temporary, variant));
    }
    for (const [index, variant] of order.entries()) {
      const name = `${index + 1}-${variant}`, results = path.join(output, 'results', name);
      const compact = path.join(receipts, name); fs.mkdirSync(compact);
      const sample = {variant, outcome: 'failure'}; manifest.samples.push(sample); write();
      try {
        run('make', ['test-ui-run'], {UI_TESTS: selector, UI_TEST_LOCALES: 'en', UI_TEST_RESULTS_DIR: results,
          UI_TEST_PRODUCTS_PATH: path.join(temporary, variant, 'products.xctestproducts'),
          UI_TEST_BUILD_RECEIPT: path.join(temporary, variant, 'build-seconds.txt'),
          UI_TEST_ENFORCE_RUNTIME_BUDGET: 'false'});
        sample.outcome = 'success';
      } finally {
        fs.writeFileSync(path.join(compact, 'en-outcome.txt'), sample.outcome + '\n');
        fs.writeFileSync(path.join(compact, 'en-selected-tests.txt'), selector + '\n');
        for (const kind of ['runtime', 'execution']) {
          const file = path.join(results, `en-${kind}.json`);
          if (fs.existsSync(file)) {
            fs.copyFileSync(file, path.join(compact, `en-${kind}.json`));
            sample[kind] = JSON.parse(fs.readFileSync(file, 'utf8'));
          }
        }
        write();
      }
      measureSample(sample); // A failed or partial case stops; it is never retried away.
    }
    manifest.summary = summarizeComparison(manifest.samples); manifest.status = 'completed';
  } catch (error) {
    manifest.status = 'failed'; manifest.error = error.message; throw error;
  } finally {
    fs.writeFileSync(sourcePath, original); write(); fs.rmSync(temporary, {recursive: true, force: true});
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
