import test from 'node:test';
import assert from 'node:assert/strict';
import {copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
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
  'CHANGELOG.md': '- Dictation\n',
};

function write(dir, path, text) {
  mkdirSync(dirname(join(dir, path)), {recursive: true});
  writeFileSync(join(dir, path), text);
}

function ratchet(change, {pin = true} = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'dictation-ratchet-'));
  const run = (...args) => spawnSync(process.execPath, ['scripts/dictation_ratchet.mjs', ...args], {cwd: dir, encoding: 'utf8'});
  try {
    assert.equal(spawnSync('git', ['init', '-q'], {cwd: dir}).status, 0);
    for (const [path, text] of Object.entries(tree)) write(dir, path, text);
    mkdirSync(join(dir, 'scripts'), {recursive: true});
    copyFileSync(script, join(dir, 'scripts/dictation_ratchet.mjs'));
    if (pin) assert.equal(run('--write').status, 0);
    change?.(dir);
    const result = run();
    return {...result, output: result.stdout + result.stderr};
  } finally { rmSync(dir, {recursive: true, force: true}); }
}

test('passes on the pinned tree and ignores history files', () => {
  const result = ratchet(dir => write(dir, 'CHANGELOG.md', '- Dictation\n- More dictation\n'));
  assert.equal(result.status, 0, result.output);
  assert.match(result.stdout, /passed: 5 files, 7 hits/);
});
test('rejects a new file that mentions dictation', () => {
  const result = ratchet(dir => write(dir, 'Sources/portavoz-app/Hotkey.swift', 'let mode = "dictation"\n'));
  assert.equal(result.status, 1);
  assert.match(result.stderr, /new mention: Sources\/portavoz-app\/Hotkey.swift \(1\)/);
});
test('counts a matching path even without matching content', () => {
  const result = ratchet(dir => write(dir, 'Tests/DictationTests.swift', 'import XCTest\n'));
  assert.equal(result.status, 1);
  assert.match(result.stderr, /new mention: Tests\/DictationTests.swift \(1\)/);
});
test('rejects a raised count', () => {
  const result = ratchet(dir => write(dir, 'Sources/StorageKit/Legacy.swift', tree['Sources/StorageKit/Legacy.swift'] + '// DICTATION\n'));
  assert.equal(result.status, 1);
  assert.match(result.stderr, /raised: Sources\/StorageKit\/Legacy.swift 2 -> 3/);
});
test('asks to lower the baseline when a count drops or a file goes', () => {
  const result = ratchet(dir => {
    write(dir, 'Sources/StorageKit/Legacy.swift', '// 1.x rows\nlet table = "dictationRecord"\n');
    rmSync(join(dir, 'Sources/portavoz-app/LegacyDictationOwnershipRelease.swift'));
    write(dir, 'Sources/portavoz-app/Release.swift', 'import DictationOwnership\n');
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /lowered: Sources\/StorageKit\/Legacy.swift 2 -> 1; lower the baseline with --write/);
  assert.match(result.stderr, /gone: Sources\/portavoz-app\/LegacyDictationOwnershipRelease.swift/);
});
for (const [name, line] of [
  ['import Carbon', '@preconcurrency import Carbon.HIToolbox'],
  ['AXIsProcessTrusted', 'let ok = AXIsProcessTrustedWithOptions(nil)'],
  ['CGEvent.tapCreate', 'let tap = CGEvent.tapCreate(tap: .cgSessionEventTap)'],
  ['RegisterEventHotKey', 'RegisterEventHotKey(code, mods, id, target, 0, &ref)'],
  ['addGlobalMonitorForEvents', 'NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in }'],
  ['IOHIDRequestAccess', 'IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)'],
]) test(`rejects ${name} in Sources`, () => {
  const result = ratchet(dir => write(dir, 'Sources/AudioCaptureKit/Input.swift', `${line}\n`));
  assert.equal(result.status, 1);
  assert.match(result.stderr, new RegExp(`forbidden API ${name.replace('.', '\\.')}: Sources/AudioCaptureKit/Input.swift:1`));
});
test('allows forbidden APIs outside Sources', () => {
  const result = ratchet(dir => write(dir, 'scripts/sandbox-spike/Probe.swift', 'import Carbon.HIToolbox\nAXIsProcessTrusted()\n'));
  assert.equal(result.status, 0, result.output);
});
test('rejects a second DictationOwnership importer', () => {
  const result = ratchet(dir => write(dir, 'Sources/portavoz-app/Other.swift', '@preconcurrency import DictationOwnership\n'));
  assert.equal(result.status, 1);
  assert.match(result.stderr, /DictationOwnership importers in Sources must be exactly .*; found: .*Other.swift/);
});
for (const path of ['project.yml', 'scripts/make-app.sh', 'Package.swift']) test(`rejects a missing pin in ${path}`, () => {
  const result = ratchet(dir => write(dir, path, '# nothing\n'));
  assert.equal(result.status, 1);
  assert.match(result.stderr, new RegExp(`pinned leftover missing from ${path.replace('.', '\\.')}`));
});
test('fails loudly without a baseline', () => {
  const result = ratchet(undefined, {pin: false});
  assert.equal(result.status, 1);
  assert.match(result.stderr, /missing scripts\/dictation_ratchet_baseline.json/);
});
test('fails loudly on an empty baseline', () => {
  const result = ratchet(dir => write(dir, baseline, '{"files": {}}\n'));
  assert.equal(result.status, 1);
  assert.match(result.stderr, /pins no files/);
});
test('fails loudly when there is nothing to scan', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dictation-ratchet-empty-'));
  try {
    assert.equal(spawnSync('git', ['init', '-q'], {cwd: dir}).status, 0);
    mkdirSync(join(dir, 'scripts'));
    copyFileSync(script, join(dir, 'scripts/dictation_ratchet.mjs'));
    write(dir, '.gitignore', 'scripts/\n.gitignore\n');
    const result = spawnSync(process.execPath, ['scripts/dictation_ratchet.mjs', '--write'], {cwd: dir, encoding: 'utf8'});
    assert.equal(result.status, 1);
    assert.match(result.stderr, /no files to scan/);
  } finally { rmSync(dir, {recursive: true, force: true}); }
});
test('the real baseline is sorted and holds only positive counts', () => {
  const files = JSON.parse(readFileSync(new URL('dictation_ratchet_baseline.json', import.meta.url), 'utf8')).files;
  const paths = Object.keys(files);
  assert.ok(paths.length > 0);
  assert.deepEqual(paths, [...paths].sort());
  assert.ok(Object.values(files).every(hits => Number.isInteger(hits) && hits > 0));
});
