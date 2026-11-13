import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync, mkdirSync, copyFileSync, rmSync, existsSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
const root = new URL('../', import.meta.url);
const hygiene = readFileSync(new URL('scripts/check-repository-hygiene.sh', root), 'utf8');

function fixture(change) {
  const dir = mkdtempSync(join(tmpdir(), 'repository-hygiene-'));
  const run = (cmd, args, env = process.env) => spawnSync(cmd, args, {cwd: dir, env, encoding: 'utf8'});
  try {
    for (const folder of ['scripts', 'bin', '.github/workflows', 'Tests/PortavozUITests']) mkdirSync(join(dir, folder), {recursive: true});
    writeFileSync(join(dir, 'scripts/check-repository-hygiene.sh'), hygiene);
    copyFileSync(new URL('.gitignore', root), join(dir, '.gitignore'));
    for (const match of hygiene.matchAll(/^bash -n (scripts\/\S+)$/gm)) writeFileSync(join(dir, match[1]), '#!/bin/bash\ntrue\n');
    writeFileSync(join(dir, '.github/workflows/fixture.yml'), `steps:\n  - uses: actions/checkout@${'a'.repeat(40)}\n`);
    writeFileSync(join(dir, 'Tests/PortavozUITests/Fixture.swift'), '// synthetic\n');
    writeFileSync(join(dir, 'bin/node'), '#!/bin/sh\nexit 0\n', {mode: 0o700});
    for (const name of ['python', 'python3']) writeFileSync(join(dir, 'bin', name), '#!/bin/sh\ntouch "$PYTHON_MARKER"\nexit 91\n', {mode: 0o700});
    assert.equal(run('git', ['init', '-q']).status, 0);
    assert.equal(run('git', ['add', '.']).status, 0);
    change?.(dir, run);
    const result = run('/bin/bash', ['scripts/check-repository-hygiene.sh'], {...process.env,
      PATH: join(dir, 'bin') + ':' + process.env.PATH, PYTHON_MARKER: join(dir, 'python-ran')});
    assert.equal(existsSync(join(dir, 'python-ran')), false, 'hygiene must never invoke Python');
    return result;
  } finally { rmSync(dir, {recursive: true, force: true}); }
}
test('repository hygiene succeeds with Python unavailable', () => {
  const result = fixture();
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /Repository hygiene passed/);
});
test('repository hygiene rejects tracked private artifacts without Python', () => {
  const result = fixture((dir, run) => {
    mkdirSync(join(dir, 'plans')); writeFileSync(join(dir, 'plans/private.md'), 'synthetic\n');
    assert.equal(run('git', ['add', '-f', 'plans/private.md']).status, 0);
  });
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, /Ephemeral\/generated files must not be tracked/);
});
test('repository hygiene rejects mutable actions without Python', () => {
  const result = fixture(dir => writeFileSync(join(dir, '.github/workflows/fixture.yml'), 'steps:\n  - uses: actions/checkout@main\n'));
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, /immutable full-length commit SHAs/);
});

test('legacy tooling remains a required CI and release step', () => {
  const workflow = readFileSync(new URL('.github/workflows/ci.yml', root), 'utf8');
  const lane = workflow.split('  repository-hygiene:\n')[1].split('\n  lint:')[0];
  assert.match(lane, /- name: Legacy tooling contracts\n        run: scripts\/check-legacy-tooling.sh/);
  assert.doesNotMatch(lane, /continue-on-error:|\n\s+if:/);
  const release = readFileSync(new URL('scripts/run-release-reliability-gates.sh', root), 'utf8');
  assert.match(release, /^set -euo pipefail$/m);
  assert.match(release, /scripts\/check-repository-hygiene.sh\nscripts\/check-legacy-tooling.sh\nswift build/);
});
for (const failure of [false, true]) test(`legacy runner ${failure ? 'propagates failure immediately' : 'retains all 77 invocations'}`, () => {
  const dir = mkdtempSync(join(tmpdir(), 'legacy-contracts-'));
  try {
    const log = join(dir, 'calls');
    writeFileSync(join(dir, 'python3'), '#!/bin/sh\nprintf "%s\\n" "$*" >> "$LEGACY_CALLS"\nexit "$LEGACY_STATUS"\n', {mode: 0o700});
    const result = spawnSync('/bin/bash', [fileURLToPath(new URL('scripts/check-legacy-tooling.sh', root))],
      {encoding: 'utf8', env: {...process.env, PATH: dir + ':' + process.env.PATH,
        LEGACY_CALLS: log, LEGACY_STATUS: failure ? '42' : '0'}});
    assert.equal(result.status, failure ? 42 : 0, result.stderr);
    const calls = readFileSync(log, 'utf8').trim().split('\n');
    assert.equal(calls.length, failure ? 1 : 77);
    assert.equal(calls[0], 'scripts/ui_test_scope.py --validate-catalog');
    if (!failure) assert.equal(calls.at(-1), '-m unittest Tests.Tooling.test_meeting_detail_performance');
  } finally { rmSync(dir, {recursive: true, force: true}); }
});
