#!/usr/bin/env node
// Keeps dictation from returning to Portavoz: every file that mentions it is pinned
// with an exact count that may only go down, and the hotkey/delivery APIs stay out of Sources.
import {readFileSync, writeFileSync, existsSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const baselinePath = 'scripts/dictation_ratchet_baseline.json';
const pattern = /dictat/i;
// Append-only history would churn on every release; the ratchet's own files name the pattern.
const excluded = new Set(['CHANGELOG.md', 'docs/DECISIONS.md', 'docs/release-announcements.md',
  baselinePath, 'scripts/dictation_ratchet.mjs', 'scripts/dictation_ratchet.test.mjs']);
const forbidden = [
  ['import Carbon', /^\s*(?:@\w+\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?Carbon\b/],
  ['AXIsProcessTrusted', /\bAXIsProcessTrusted/],
  ['CGEvent.tapCreate', /\bCGEvent\.tapCreate\b|\bCGEventTapCreate\b/],
  ['RegisterEventHotKey', /\bRegisterEventHotKey\b/],
  ['addGlobalMonitorForEvents', /\baddGlobalMonitorForEvents\b/],
  ['IOHIDRequestAccess', /\bIOHIDRequestAccess\b/],
];
// Kept on purpose so Secreteo can take dictation ownership from a 1.x install.
const ownershipImporters = ['Sources/portavoz-app/LegacyDictationOwnershipRelease.swift'];
const pinnedText = [
  ['Package.swift', /\.product\(name: "DictationOwnership", package: "secreteo"\)/],
  ['project.yml', /^\s*DictationOwnershipProtocol: 1$/m],
  ['scripts/make-app.sh', /<key>DictationOwnershipProtocol<\/key>\s*<integer>1<\/integer>/],
];

function listFiles() {
  const git = spawnSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'],
    {cwd: root, encoding: 'utf8'});
  if (git.status !== 0) throw new Error(`git ls-files failed: ${git.stderr.trim()}`);
  return [...new Set(git.stdout.split('\0').filter(Boolean))].filter(path => existsSync(join(root, path))).sort();
}

function readText(path) {
  const bytes = readFileSync(join(root, path));
  return bytes.subarray(0, 8000).includes(0) ? null : bytes.toString('utf8');
}

function scan() {
  const files = listFiles();
  if (files.length === 0) throw new Error('no files to scan; run inside the repository');
  const counts = {};
  const problems = [];
  const importers = [];
  for (const path of files) {
    const text = readText(path);
    const lines = text === null ? [] : text.split('\n');
    if (!excluded.has(path)) {
      const hits = lines.filter(line => pattern.test(line)).length + (pattern.test(path) ? 1 : 0);
      if (hits > 0) counts[path] = hits;
    }
    if (!path.startsWith('Sources/')) continue;
    lines.forEach((line, index) => {
      for (const [name, regex] of forbidden) {
        if (regex.test(line)) problems.push(`forbidden API ${name}: ${path}:${index + 1}`);
      }
      if (/^\s*(?:@\w+\s+)*import\s+(?:\w+\s+)?DictationOwnership\b/.test(line)) importers.push(path);
    });
  }
  const actualImporters = [...new Set(importers)].sort().join(', ');
  if (actualImporters !== ownershipImporters.join(', ')) {
    problems.push(`DictationOwnership importers in Sources must be exactly ${ownershipImporters.join(', ')}; found: ${actualImporters || 'none'}`);
  }
  for (const [path, regex] of pinnedText) {
    const text = existsSync(join(root, path)) ? readFileSync(join(root, path), 'utf8') : '';
    if (!regex.test(text)) problems.push(`pinned leftover missing from ${path}: ${regex.source}`);
  }
  return {counts, problems};
}

function compare(counts, baseline) {
  const problems = [];
  for (const [path, hits] of Object.entries(counts)) {
    const pinned = baseline[path];
    if (pinned === undefined) problems.push(`new mention: ${path} (${hits}); remove it`);
    else if (hits > pinned) problems.push(`raised: ${path} ${pinned} -> ${hits}; remove the new mention`);
    else if (hits < pinned) problems.push(`lowered: ${path} ${pinned} -> ${hits}; lower the baseline with --write`);
  }
  for (const path of Object.keys(baseline)) {
    if (counts[path] === undefined) problems.push(`gone: ${path}; lower the baseline with --write`);
  }
  return problems;
}

function main() {
  const {counts, problems} = scan();
  const total = Object.values(counts).reduce((sum, hits) => sum + hits, 0);
  if (Object.keys(counts).length === 0) throw new Error('no dictation mentions found; the scan is broken');
  if (process.argv.includes('--write')) {
    const sorted = Object.fromEntries(Object.entries(counts).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
    writeFileSync(join(root, baselinePath), JSON.stringify({files: sorted}, null, 2) + '\n');
    console.log(`Wrote ${baselinePath}: ${Object.keys(counts).length} files, ${total} hits.`);
  } else {
    if (!existsSync(join(root, baselinePath))) throw new Error(`missing ${baselinePath}`);
    const baseline = JSON.parse(readFileSync(join(root, baselinePath), 'utf8')).files ?? {};
    if (Object.keys(baseline).length === 0) throw new Error(`${baselinePath} pins no files`);
    problems.push(...compare(counts, baseline));
  }
  if (problems.length > 0) {
    console.error(`Dictation ratchet failed:\n  ${problems.join('\n  ')}`);
    process.exit(1);
  }
  if (!process.argv.includes('--write')) console.log(`Dictation ratchet passed: ${Object.keys(counts).length} files, ${total} hits.`);
}

try { main(); } catch (error) { console.error(`Dictation ratchet failed: ${error.message}`); process.exit(1); }
