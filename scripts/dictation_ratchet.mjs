#!/usr/bin/env node
// Keeps dictation from returning to Portavoz: every tracked file that mentions it is pinned
// with an exact count that may only go down, and the hotkey/delivery APIs stay out of Sources.
import {closeSync, existsSync, lstatSync, openSync, readFileSync, readSync, writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const baselinePath = 'scripts/dictation_ratchet_baseline.json';
const rewrite = `run: fnm exec -- node scripts/dictation_ratchet.mjs --write, then commit ${baselinePath}`;
// English and Spanish (dictado, dicta); "dictab" only occurs in (un)predictable.
const mention = () => /dicta(?!b)/gi;
// Append-only history would churn on every release; the ratchet's own files name the pattern.
const excluded = new Set(['CHANGELOG.md', 'docs/DECISIONS.md', 'docs/release-announcements.md',
  baselinePath, 'scripts/dictation_ratchet.mjs', 'scripts/dictation_ratchet.test.mjs']);
const attributes = String.raw`(?:@\w+(?:\([^)]*\))?\s+)*`;
const importOf = module => new RegExp(String.raw`(?:^|\n)\s*${attributes}import\s+(?:\w+\s+)?${module}\b`, 'g');
const forbidden = [
  ['import Carbon', importOf('Carbon')],
  ['tapCreate', /\btapCreate\w*/g],
  ['CGEventTapCreate', /\bCGEventTapCreate\w*/g],
  ['post(tap:)', /\.post\(tap:/g],
  ['CGEventPost', /\bCGEventPost\w*/g],
  ['CG event access', /\bCG(?:Preflight|Request)(?:Post|Listen)EventAccess\b/g],
  ['AXUIElement', /\bAXUIElement\w*/g],
  ['AXIsProcessTrusted', /\bAXIsProcessTrusted\w*/g],
  ['IOHID access', /\bIOHID(?:Request|Check)Access\b/g],
  ['RegisterEventHotKey', /\bRegisterEventHotKey\b/g],
  ['addGlobalMonitorForEvents', /\baddGlobalMonitorForEvents\b/g],
];
// Kept on purpose so Secreteo can take dictation ownership from a 1.x install.
const ownershipImporters = ['Sources/portavoz-app/LegacyDictationOwnershipRelease.swift'];
const pinnedText = [
  ['Package.swift', /\.product\(name: "DictationOwnership", package: "secreteo"\)/],
  ['project.yml', /^\s*DictationOwnershipProtocol: 1$/m],
  ['scripts/make-app.sh', /<key>DictationOwnershipProtocol<\/key>\s*<integer>1<\/integer>/],
];

function git(args) {
  const result = spawnSync('git', args, {cwd: root, encoding: 'utf8', maxBuffer: 64 << 20});
  if (result.error) throw new Error(`git ${args[0]} could not run: ${result.error.message}`);
  if (result.status !== 0) throw new Error(`git ${args[0]} failed: ${result.stderr.trim()}`);
  return result.stdout.split('\0').filter(Boolean);
}

// Regular files only: a symlink's target and a nested repository are scanned on their own paths.
function readText(path) {
  let stat;
  try { stat = lstatSync(join(root, path)); } catch (error) {
    if (error.code === 'ENOENT') return undefined;
    throw error;
  }
  if (!stat.isFile()) return null;
  const fd = openSync(join(root, path), 'r');
  try {
    const head = Buffer.alloc(8000);
    if (head.subarray(0, readSync(fd, head, 0, head.length, 0)).includes(0)) return '';
  } finally { closeSync(fd); }
  return readFileSync(join(root, path), 'utf8');
}

const count = text => (text.match(mention()) ?? []).length;
const lineOf = (text, index) => text.slice(0, index).split('\n').length;

function scan() {
  const entries = git(['ls-files', '-z', '-t', '--cached']);
  if (entries.length === 0) throw new Error('no tracked files to scan; run inside the repository');
  const counts = {};
  const skipped = new Set();
  const problems = [];
  const importers = new Set();
  for (const entry of entries) {
    const path = entry.slice(2);
    if (entry[0] === 'S') { skipped.add(path); continue; }
    const text = readText(path);
    if (text === null) continue;
    if (text !== undefined && !excluded.has(path)) {
      const hits = count(text) + count(path);
      if (hits > 0) counts[path] = hits;
    }
    if (!text || !path.startsWith('Sources/')) continue;
    for (const [name, regex] of forbidden) {
      for (const match of text.matchAll(regex)) {
        const start = match.index + match[0].search(/\S/);
        problems.push(`forbidden API ${name}: ${path}:${lineOf(text, start)}`);
      }
    }
    if (importOf('DictationOwnership').test(text)) importers.add(path);
  }
  const actualImporters = [...importers].sort().join(', ');
  if (actualImporters !== ownershipImporters.join(', ')) {
    problems.push(`DictationOwnership importers in Sources must be exactly ${ownershipImporters.join(', ')}; found: ${actualImporters || 'none'}`);
  }
  for (const [path, regex] of pinnedText) {
    const text = existsSync(join(root, path)) ? readFileSync(join(root, path), 'utf8') : '';
    if (!regex.test(text)) problems.push(`pinned leftover missing from ${path}: ${regex.source}`);
  }
  return {counts, skipped, problems};
}

function untrackedWarnings() {
  return git(['ls-files', '-z', '--others', '--exclude-standard'])
    .filter(path => !excluded.has(path))
    .flatMap(path => {
      const text = readText(path);
      const hits = text === null || text === undefined ? 0 : count(text) + count(path);
      return hits > 0 ? [`untracked, not checked until added: ${path} (${hits})`] : [];
    });
}

function loadBaseline() {
  if (!existsSync(join(root, baselinePath))) throw new Error(`missing ${baselinePath}`);
  const files = JSON.parse(readFileSync(join(root, baselinePath), 'utf8')).files ?? {};
  if (Object.keys(files).length === 0) throw new Error(`${baselinePath} pins no files`);
  return files;
}

function compare(counts, skipped, baseline) {
  const raised = [];
  const lowered = [];
  for (const [path, hits] of Object.entries(counts)) {
    const pinned = baseline[path];
    if (pinned === undefined) raised.push(`new mention: ${path} (${hits}); remove it`);
    else if (hits > pinned) raised.push(`raised: ${path} ${pinned} -> ${hits}; remove the new mention`);
    else if (hits < pinned) lowered.push(`lowered: ${path} ${pinned} -> ${hits}`);
  }
  for (const path of Object.keys(baseline)) {
    if (counts[path] === undefined && !skipped.has(path)) lowered.push(`gone: ${path}`);
  }
  return {raised, lowered};
}

function fail(lines) {
  console.error(`Dictation ratchet failed:\n  ${lines.join('\n  ')}`);
  process.exit(1);
}

function main() {
  const write = process.argv.includes('--write');
  const {counts, skipped, problems} = scan();
  if (problems.length > 0) fail(problems);
  if (Object.keys(counts).length === 0) throw new Error('no dictation mentions found; the scan is broken');
  const baseline = loadBaseline();
  const {raised, lowered} = compare(counts, skipped, baseline);
  for (const warning of untrackedWarnings()) console.error(`Dictation ratchet warning: ${warning}`);
  if (raised.length > 0) {
    fail(write ? [...raised, 'the baseline only tightens; raise it by editing the JSON in review'] : [...raised, ...lowered]);
  }
  for (const path of skipped) if (baseline[path] !== undefined) counts[path] = baseline[path];
  const total = Object.values(counts).reduce((sum, hits) => sum + hits, 0);
  if (write) {
    const sorted = Object.fromEntries(Object.entries(counts).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
    writeFileSync(join(root, baselinePath), JSON.stringify({files: sorted}, null, 2) + '\n');
    console.log(`Lowered ${baselinePath}: ${Object.keys(counts).length} files, ${total} hits.`);
    return;
  }
  if (lowered.length > 0) fail([...lowered, rewrite]);
  console.log(`Dictation ratchet passed: ${Object.keys(counts).length} files, ${total} hits.`);
}

try { main(); } catch (error) { console.error(`Dictation ratchet failed: ${error.message}`); process.exit(1); }
