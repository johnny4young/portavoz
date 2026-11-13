import test from 'node:test';
import assert from 'node:assert/strict';
import {copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {dirname, join} from 'node:path';
import {tmpdir} from 'node:os';

const script = new URL('dictation_ratchet.mjs', import.meta.url);
const baseline = 'scripts/dictation_ratchet_baseline.json';
const tree = {
  'Package.swift': '.product(name: "DictationOwnership", package: "secreteo"),\n',
  'project.yml': 'info:\n  properties:\n        DictationOwnershipProtocol: 1\n',
  'scripts/make-app.sh': '    <key>DictationOwnershipProtocol</key>\n    <integer>1</integer>\n',
  'Sources/portavoz-app/LegacyDictationOwnershipRelease.swift': 'import DictationOwnership\n',
  'Sources/StorageKit/Legacy.swift': '// 1.x dictation rows\nlet dictationTable = "dictationRecord"\n',
  'AGENTS.md': 'No dictation here; behavior stays predictable.\n',
  'CHANGELOG.md': '- Dictation\n',
};
const pinned = {
  'AGENTS.md': 1,
  'Package.swift': 1,
  'Sources/StorageKit/Legacy.swift': 3,
  'Sources/portavoz-app/LegacyDictationOwnershipRelease.swift': 2,
  'project.yml': 1,
  'scripts/make-app.sh': 1,
};

function write(dir, path, text) {
  mkdirSync(dirname(join(dir, path)), {recursive: true});
  writeFileSync(join(dir, path), text);
}
const git = (dir, ...args) => spawnSync('git', args, {cwd: dir, encoding: 'utf8'});

// The change runs on a committed fixture; by default its result is staged so the ratchet sees it.
function ratchet(change, {stage = true, args = [], files = pinned, env = process.env, inspect} = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'dictation-ratchet-'));
  try {
    assert.equal(git(dir, 'init', '-q').status, 0);
    for (const [path, text] of Object.entries(tree)) write(dir, path, text);
    symlinkSync('AGENTS.md', join(dir, 'CLAUDE.md'));
    copyFileSync(script, join(dir, 'scripts/dictation_ratchet.mjs'));
    if (files) write(dir, baseline, JSON.stringify({files}, null, 2) + '\n');
    assert.equal(git(dir, 'add', '-A').status, 0);
    assert.equal(git(dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com', 'commit', '-qm', 'fixture').status, 0);
    change?.(dir);
    if (stage) assert.equal(git(dir, 'add', '-A').status, 0);
    const result = spawnSync(process.execPath, ['scripts/dictation_ratchet.mjs', ...args], {cwd: dir, env, encoding: 'utf8'});
    inspect?.(dir);
    return result;
  } finally { rmSync(dir, {recursive: true, force: true}); }
}
const readBaseline = dir => existsSync(join(dir, baseline)) ? JSON.parse(readFileSync(join(dir, baseline), 'utf8')).files : undefined;

test('passes on the pinned tree, skipping history files and symlinks', () => {
  const result = ratchet(dir => write(dir, 'CHANGELOG.md', '- Dictation\n- More dictation\n'));
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /passed: 6 files, 9 hits/);
});
test('rejects a new tracked file, in English or Spanish', () => {
  for (const text of ['let mode = "dictation"\n', '// dictado\n']) {
    const result = ratchet(dir => write(dir, 'Sources/portavoz-app/Hotkey.swift', text));
    assert.equal(result.status, 1);
    assert.match(result.stderr, /new mention: Sources\/portavoz-app\/Hotkey.swift \(1\); remove it/);
  }
});
test('does not count predictable', () => {
  const result = ratchet(dir => write(dir, 'Sources/Stable.swift', '// predictable, unpredictable\n'));
  assert.equal(result.status, 0, result.stderr);
});
test('counts every occurrence, not lines', () => {
  const result = ratchet(dir => write(dir, 'AGENTS.md', 'No dictation, no dictado.\n'));
  assert.equal(result.status, 1);
  assert.match(result.stderr, /raised: AGENTS.md 1 -> 2/);
});
test('counts a matching path even without matching content', () => {
  const result = ratchet(dir => write(dir, 'Tests/DictationTests.swift', 'import XCTest\n'));
  assert.equal(result.status, 1);
  assert.match(result.stderr, /new mention: Tests\/DictationTests.swift \(1\)/);
});
test('counts a binary file by its path only', () => {
  const result = ratchet(dir => {
    write(dir, 'Resources/dictation-icon.png', Buffer.from('\0\x89PNG dictation dictation dictation'));
    write(dir, 'Resources/plain.bin', Buffer.from('\0 dictation'));
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /new mention: Resources\/dictation-icon.png \(1\)/);
  assert.doesNotMatch(result.stderr, /plain.bin/);
});
test('rejects a raised count', () => {
  const result = ratchet(dir => write(dir, 'Sources/StorageKit/Legacy.swift', tree['Sources/StorageKit/Legacy.swift'] + '// DICTATION\n'));
  assert.equal(result.status, 1);
  assert.match(result.stderr, /raised: Sources\/StorageKit\/Legacy.swift 3 -> 4/);
});
test('asks to lower the baseline when a count drops or a tracked file is deleted', () => {
  const result = ratchet(dir => {
    write(dir, 'Sources/StorageKit/Legacy.swift', '// 1.x rows\nlet table = "dictationRecord"\n');
    rmSync(join(dir, 'AGENTS.md'));
  }, {stage: false});
  assert.equal(result.status, 1);
  assert.match(result.stderr, /lowered: Sources\/StorageKit\/Legacy.swift 3 -> 1/);
  assert.match(result.stderr, /gone: AGENTS.md/);
  assert.match(result.stderr, /run: fnm exec -- node scripts\/dictation_ratchet.mjs --write, then commit scripts\/dictation_ratchet_baseline.json/);
});
test('treats a skip-worktree file as present', () => {
  const result = ratchet(dir => {
    assert.equal(git(dir, 'update-index', '--skip-worktree', 'AGENTS.md').status, 0);
    rmSync(join(dir, 'AGENTS.md'));
  }, {stage: false});
  assert.equal(result.status, 0, result.stderr);
});
test('warns about untracked files without failing or crashing', () => {
  const result = ratchet(dir => {
    write(dir, 'Sources/Stray.swift', '// dictation\n');
    mkdirSync(join(dir, 'Vendor/nested'), {recursive: true});
    assert.equal(git(join(dir, 'Vendor/nested'), 'init', '-q').status, 0);
    write(dir, 'Vendor/nested/dictation.txt', 'dictation\n');
    mkdirSync(join(dir, 'empty-dir'));
  }, {stage: false});
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stderr, /warning: untracked, not checked until added: Sources\/Stray.swift \(1\)/);
});
test('reports a missing git clearly', () => {
  const result = ratchet(undefined, {env: {...process.env, PATH: '/nonexistent'}});
  assert.equal(result.status, 1);
  assert.match(result.stderr, /git ls-files could not run/);
});
for (const [name, text] of [
  ['import Carbon', '@preconcurrency import Carbon.HIToolbox\n'],
  ['import Carbon', '@_spi(Private) import Carbon.HIToolbox\n'],
  ['import Carbon', 'import\n    Carbon\n'],
  ['import Carbon', 'let a = 1\nimport struct Carbon.EventHotKeyID\n'],
  ['AXIsProcessTrusted', 'let ok = AXIsProcessTrustedWithOptions(nil)\n'],
  ['AXUIElement', 'let app = AXUIElementCreateApplication(pid)\n'],
  ['tapCreate', 'let tap = CGEvent.tapCreate(tap: .cgSessionEventTap)\n'],
  ['tapCreate', 'let tap = CGEvent.tapCreateForPid(pid: pid)\n'],
  ['tapCreate', 'typealias E = CGEvent; let t = E.tapCreate(tap: .cghidEventTap)\n'],
  ['tapCreate', 'let tap = CGEvent\n    .tapCreate(tap: .cgSessionEventTap)\n'],
  ['CGEventTapCreate', 'let tap = CGEventTapCreateForPSN(psn)\n'],
  ['post\\(tap:\\)', 'event.post(tap: .cghidEventTap)\n'],
  ['CGEventPost', 'CGEventPostToPid(pid, event)\n'],
  ['CG event access', 'CGRequestPostEventAccess()\n'],
  ['CG event access', 'CGPreflightListenEventAccess()\n'],
  ['RegisterEventHotKey', 'RegisterEventHotKey(code, mods, id, target, 0, &ref)\n'],
  ['addGlobalMonitorForEvents', 'NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in }\n'],
  ['IOHID access', 'IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)\n'],
  ['IOHID access', 'IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)\n'],
]) test(`rejects ${name} in Sources: ${JSON.stringify(text)}`, () => {
  const result = ratchet(dir => write(dir, 'Sources/AudioCaptureKit/Input.swift', text));
  assert.equal(result.status, 1);
  assert.match(result.stderr, new RegExp(`forbidden API ${name}: Sources/AudioCaptureKit/Input.swift:\\d`));
});
test('allows forbidden APIs outside Sources', () => {
  const result = ratchet(dir => write(dir, 'scripts/sandbox-spike/Probe.swift', 'import Carbon.HIToolbox\nAXIsProcessTrusted()\n'));
  assert.equal(result.status, 0, result.stderr);
});
for (const line of ['import DictationOwnership', '@_spi(Private) import DictationOwnership'])
  test(`rejects a second DictationOwnership importer: ${line}`, () => {
    const result = ratchet(dir => write(dir, 'Sources/portavoz-app/Other.swift', `${line}\n`));
    assert.equal(result.status, 1);
    assert.match(result.stderr, /DictationOwnership importers in Sources must be exactly .*; found: .*Other.swift/);
  });
for (const path of ['project.yml', 'scripts/make-app.sh', 'Package.swift']) test(`rejects a missing pin in ${path}`, () => {
  const result = ratchet(dir => write(dir, path, '# nothing\n'));
  assert.equal(result.status, 1);
  assert.match(result.stderr, new RegExp(`pinned leftover missing from ${path.replace('.', '\\.')}`));
});
test('--write lowers counts and drops gone files', () => {
  let files;
  const result = ratchet(dir => rmSync(join(dir, 'AGENTS.md')), {args: ['--write'], inspect: dir => { files = readBaseline(dir); }});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(files['AGENTS.md'], undefined);
  assert.equal(files['Sources/StorageKit/Legacy.swift'], 3);
});
for (const [name, change, message] of [
  ['a new path', dir => write(dir, 'Sources/New.swift', '// dictation\n'), /new mention: Sources\/New.swift/],
  ['a raised count', dir => write(dir, 'AGENTS.md', 'dictation dictation\n'), /raised: AGENTS.md 1 -> 2/],
  ['a forbidden API', dir => write(dir, 'Sources/New.swift', 'import Carbon\n'), /forbidden API import Carbon/],
  ['a missing pin', dir => write(dir, 'project.yml', '# nothing\n'), /pinned leftover missing from project.yml/],
]) test(`--write refuses ${name} and leaves the baseline alone`, () => {
  let files;
  const result = ratchet(change, {args: ['--write'], inspect: dir => { files = readBaseline(dir); }});
  assert.equal(result.status, 1);
  assert.match(result.stderr, message);
  assert.deepEqual(files, pinned);
});
test('--write refuses zero mentions and writes nothing', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dictation-ratchet-zero-'));
  try {
    assert.equal(git(dir, 'init', '-q').status, 0);
    copyFileSync(script, (mkdirSync(join(dir, 'scripts')), join(dir, 'scripts/dictation_ratchet.mjs')));
    write(dir, 'README.md', 'nothing here\n');
    assert.equal(git(dir, 'add', '-A').status, 0);
    const result = spawnSync(process.execPath, ['scripts/dictation_ratchet.mjs', '--write'], {cwd: dir, encoding: 'utf8'});
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Dictation ratchet failed/);
    assert.equal(existsSync(join(dir, baseline)), false);
  } finally { rmSync(dir, {recursive: true, force: true}); }
});
test('fails loudly without a baseline', () => {
  const result = ratchet(undefined, {files: null});
  assert.equal(result.status, 1);
  assert.match(result.stderr, /missing scripts\/dictation_ratchet_baseline.json/);
});
test('fails loudly on an empty baseline', () => {
  const result = ratchet(undefined, {files: {}});
  assert.equal(result.status, 1);
  assert.match(result.stderr, /pins no files/);
});
test('fails loudly when nothing is tracked', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dictation-ratchet-empty-'));
  try {
    assert.equal(git(dir, 'init', '-q').status, 0);
    mkdirSync(join(dir, 'scripts'));
    copyFileSync(script, join(dir, 'scripts/dictation_ratchet.mjs'));
    const result = spawnSync(process.execPath, ['scripts/dictation_ratchet.mjs'], {cwd: dir, encoding: 'utf8'});
    assert.equal(result.status, 1);
    assert.match(result.stderr, /no tracked files to scan/);
  } finally { rmSync(dir, {recursive: true, force: true}); }
});
test('the real baseline is sorted and holds only positive counts', () => {
  const files = JSON.parse(readFileSync(new URL('dictation_ratchet_baseline.json', import.meta.url), 'utf8')).files;
  const paths = Object.keys(files);
  assert.ok(paths.length > 0);
  assert.deepEqual(paths, [...paths].sort());
  assert.ok(Object.values(files).every(hits => Number.isInteger(hits) && hits > 0));
});
