import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync, spawnSync} from 'node:child_process';
import {validateSources, validateBundleLinks, measureSample, summarizeComparison, selector, testPath, order} from './ci_time_review_comparison.mjs';

const source = body => `import XCTest\n    func testMeetingReviewSurfacesRemainCompleteAndActionable() throws {\n${body}\n    }\n    @MainActor\n    func next() {}\n`;
const pair = () => ({base: 'a'.repeat(40), head: 'b'.repeat(40), changedPaths: [testPath],
  before: source('        before()'), after: source('        after()')});
const sample = (variant, seconds) => ({variant, outcome: 'success',
  runtime: {schemaVersion: 3, locale: 'en', selectorCount: 1, caseCount: 1, budgetStatus: 'failed',
    measurementPolicy: 'xcresult-duration-with-activity-boundary-exclusions-v2', testDurationSeconds: seconds,
    budgetViolations: ['synthetic advisory violation'],
    tests: [{identifier: selector.replace('PortavozUITests/', '') + '()', result: 'Passed', durationSeconds: seconds}]},
  execution: {schemaVersion: 1, locale: 'en', classification: 'completed', selectorCount: 1,
    xcodebuildExitStatus: 0, failureSignature: null, runtimeReceiptPresent: true,
    resultBundlePresent: true, logSHA256: 'c'.repeat(64)}});

test('binds two immutable method-only source variants', () => {
  const result = validateSources(pair());
  assert.notEqual(result.beforeSourceSHA256, result.afterSourceSHA256);
  assert.equal(result.base, 'a'.repeat(40));
});

test('manual measurement cannot join the PR gate or overlap its prerequisites', () => {
  const workflow = fs.readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
  const job = workflow.split('\n  meeting-review-comparison:\n')[1];
  assert.match(job, /^    needs: gate$/m);
  assert.match(job, /^    if: github.event_name == 'workflow_dispatch' && inputs.review_comparison_base != ''$/m);
  const gate = workflow.split('\n  gate:\n')[1].split('\n  alert:\n')[0];
  assert.doesNotMatch(gate, /meeting-review-comparison/);
  assert.match(job, /if: always\(\)\n        uses: actions\/upload-artifact@/);
  assert.doesNotMatch(job, /continue-on-error|permissions:/);
});

// Exercise the orchestration without native tools: a synthetic builder exposes
// linked products, so using the rebuilt candidate as the baseline is observable.
for (const fail of [false, true]) test(`CLI freezes variant products and preserves ${fail ? 'failed' : 'complete'} evidence`, () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'review-comparison-test-'));
  try {
    const script = 'scripts/ci_time_review_comparison.mjs';
    fs.mkdirSync(path.join(root, 'scripts')); fs.mkdirSync(path.dirname(path.join(root, testPath)), {recursive: true});
    fs.copyFileSync(new URL('./ci_time_review_comparison.mjs', import.meta.url), path.join(root, script));
    fs.writeFileSync(path.join(root, testPath), source('        before'));
    const git = (...args) => execFileSync('git', args, {cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']}).trim();
    git('init'); git('add', '.');
    const commit = () => git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-m', 'fixture');
    commit(); const base = git('rev-parse', 'HEAD');
    fs.writeFileSync(path.join(root, testPath), source('        after')); git('add', '.'); commit();
    const head = git('rev-parse', 'HEAD'), bin = path.join(root, 'bin'); fs.mkdirSync(bin);
    for (const name of ['xcodebuild', 'sw_vers']) fs.writeFileSync(path.join(bin, name), '#!/bin/sh\necho synthetic\n', {mode: 0o755});
    const fixture = sample('before', 25);
    fs.writeFileSync(path.join(bin, 'make'), `#!/usr/bin/env node
const fs = require('node:fs'), path = require('node:path');
const env = process.env, target = process.argv[2];
const products = env.UI_TEST_PRODUCTS_PATH;
if (target === 'test-ui-host-products') {
  const body = fs.readFileSync(${JSON.stringify(testPath)}, 'utf8');
  fs.rmSync(products, {recursive: true, force: true}); fs.mkdirSync(products);
  fs.writeFileSync(path.join(products, 'mutable-product'), body.includes('\\n        before\\n') ? 'before' : 'after');
  fs.symlinkSync('mutable-product', path.join(products, 'variant'));
  fs.writeFileSync(env.UI_TEST_BUILD_RECEIPT, '1\\n');
} else {
  if (!fs.lstatSync(path.join(products, 'variant')).isSymbolicLink()) process.exit(4);
  const variant = fs.readFileSync(path.join(products, 'variant'), 'utf8');
  const results = env.UI_TEST_RESULTS_DIR, name = path.basename(results);
  fs.appendFileSync('observed', variant + '\\n');
  if (!name.endsWith('-' + variant)) process.exit(3);
  fs.mkdirSync(results, {recursive: true});
  const row = ${JSON.stringify(fixture)};
  fs.writeFileSync(path.join(results, 'en-runtime.json'), JSON.stringify(row.runtime));
  fs.writeFileSync(path.join(results, 'en-execution.json'), JSON.stringify(row.execution));
  if (env.SYNTHETIC_FAILURE === 'true' && name === '2-after') process.exit(65);
}
`, {mode: 0o755});
    const run = spawnSync(process.execPath, [script], {cwd: root, encoding: 'utf8', timeout: 20000,
      env: {...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`, GITHUB_ACTIONS: 'true',
        GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_SHA: head, COMPARISON_BASE: base,
        SYNTHETIC_FAILURE: String(fail)}});
    assert.equal(run.status, fail ? 1 : 0, run.stderr);
    assert.equal(fs.readFileSync(path.join(root, testPath), 'utf8'), source('        after'));
    assert.deepEqual(fs.readFileSync(path.join(root, 'observed'), 'utf8').trim().split('\n'), order.slice(0, fail ? 2 : 6));
    const receipts = path.join(root, 'dist/review-comparison/receipts');
    const manifest = JSON.parse(fs.readFileSync(path.join(receipts, 'manifest.json')));
    assert.equal(manifest.status, fail ? 'failed' : 'completed');
    assert.equal(manifest.samples.length, fail ? 2 : 6);
    assert.notEqual(manifest.bundles.before.archiveSHA256, manifest.bundles.after.archiveSHA256);
    if (fail) {
      assert.equal(manifest.summary, undefined);
      assert.equal(fs.readFileSync(path.join(receipts, '2-after/en-outcome.txt'), 'utf8'), 'failure\n');
    } else assert.equal(manifest.summary.acceptance, null);
  } finally { fs.rmSync(root, {recursive: true, force: true}); }
});

test('portable bundle links reject mutable external, absolute and broken targets', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'review-links-test-'));
  try {
    const bundle = path.join(root, 'bundle'); fs.mkdirSync(bundle);
    fs.writeFileSync(path.join(root, 'outside'), 'outside'); fs.writeFileSync(path.join(bundle, 'inside'), 'inside');
    const link = path.join(bundle, 'link'); fs.symlinkSync('inside', link);
    validateBundleLinks(bundle); fs.unlinkSync(link);
    for (const target of ['../outside', path.join(bundle, 'inside'), 'missing']) {
      fs.symlinkSync(target, link); assert.throws(() => validateBundleLinks(bundle)); fs.unlinkSync(link);
    }
  } finally { fs.rmSync(root, {recursive: true, force: true}); }
});
test('rejects mutable refs, identical commits and unchanged bodies', () => {
  for (const base of ['main', '../main', 'a'.repeat(39), 'b'.repeat(40)])
    assert.throws(() => validateSources({...pair(), base}));
  assert.throws(() => validateSources({...pair(), after: pair().before}));
});
test('rejects changes to product, helper, dependency, budget or another method', () => {
  for (const file of ['Sources/App.swift', 'Tests/PortavozUITests/UITestSupport.swift',
    'Package.resolved', 'docs/evidence/ui-test-runtime-budget.json', 'scripts/run-ui-tests.sh'])
    assert.throws(() => validateSources({...pair(), changedPaths: [testPath, file]}));
  assert.throws(() => validateSources({...pair(), after: pair().after.replace('next()', 'different()')}));
  assert.throws(() => validateSources({...pair(), after: 'changed\n' + pair().after}));
  assert.throws(() => validateSources({...pair(), after: pair().after.replace('    @MainActor', '    func additionalHelper() {}\n    @MainActor')}));
});
test('rejects missing and ambiguous method boundaries', () => {
  assert.throws(() => validateSources({...pair(), before: 'no method'}));
  assert.throws(() => validateSources({...pair(), before: pair().before + pair().before}));
});
test('retains advisory budget failures without declaring performance acceptance', () => {
  const rows = order.map((variant, i) => sample(variant, [30, 28, 26, 32, 34, 24][i]));
  const result = summarizeComparison(rows);
  assert.equal(result.before.median, 32); assert.equal(result.after.median, 26);
  assert.equal(result.after.above20Seconds, 3); assert.equal(result.acceptance, null);
  assert.equal(measureSample(rows[0]).reportedBudgetStatus, 'failed');
});
test('refuses omitted, reordered, failed or partial observations', () => {
  const rows = order.map(variant => sample(variant, 25));
  assert.throws(() => summarizeComparison(rows.slice(1)));
  assert.throws(() => summarizeComparison(rows.toReversed()));
  for (const patch of [{outcome: 'failure'}, {runtime: {}}, {execution: {}}])
    assert.throws(() => measureSample({...sample('before', 25), ...patch}));
});
test('refuses wrong-case, skipped, negative and contradictory successful receipts', () => {
  for (const patch of [{identifier: 'Other/test()'}, {result: 'Skipped'}, {durationSeconds: -1}, {durationSeconds: NaN}]) {
    const row = sample('before', 25); Object.assign(row.runtime.tests[0], patch);
    assert.throws(() => measureSample(row));
  }
  for (const patch of [{selectorCount: 2}, {xcodebuildExitStatus: 65}, {resultBundlePresent: false}, {logSHA256: ''}]) {
    const row = sample('before', 25); Object.assign(row.execution, patch);
    assert.throws(() => measureSample(row));
  }
  for (const patch of [{measurementPolicy: 'unknown'}, {testDurationSeconds: 24}, {budgetViolations: []}, {budgetStatus: 'passed'}]) {
    const row = sample('before', 25); Object.assign(row.runtime, patch);
    assert.throws(() => measureSample(row));
  }
});
