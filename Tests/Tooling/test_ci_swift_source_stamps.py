import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('stamps', ROOT / 'scripts/ci_swift_source_stamps.py')
stamps = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stamps)


class SourceStampTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.source = self.root / 'Sources/Example.swift'
        self.source.parent.mkdir()
        self.source.write_text('let value = 1\n')
        self.source.chmod(0o644)
        os.utime(self.source, ns=(1700000000000000000, 1700000000000000000))
        self.original = stamps.fingerprint(self.source)
        self.git_add('Sources')
        stamps.snapshot(self.root)
        self.receipt = self.root / stamps.RECEIPT

    def git_add(self, path):
        subprocess.run(['git', 'add', '--', path], cwd=self.root, check=True)

    def test_identical_bytes_and_mode_recover_exact_successful_build_timestamp(self):
        os.utime(self.source, None)
        self.assertNotEqual(self.source.stat().st_mtime_ns, self.original['mtime_ns'])
        self.assertEqual(stamps.restore(self.root), (1, 0))
        self.assertEqual(stamps.fingerprint(self.source), self.original)

    def test_same_size_same_timestamp_modified_source_is_forced_fresh(self):
        self.source.write_text('let value = 2\n')
        os.utime(self.source, ns=(self.original['mtime_ns'], self.original['mtime_ns']))
        with patch.object(stamps.time, 'time_ns', return_value=1800000000000000000):
            self.assertEqual(stamps.restore(self.root), (0, 1))
        self.assertEqual(self.source.stat().st_mtime_ns, 1800000000000000000)
        self.assertEqual(self.source.read_text(), 'let value = 2\n')

    def test_mode_change_also_remains_a_fresh_input(self):
        self.source.chmod(0o755)
        self.assertEqual(stamps.restore(self.root), (0, 1))
        self.assertNotEqual(self.source.stat().st_mtime_ns, self.original['mtime_ns'])
        self.assertEqual(self.source.stat().st_mode & 0o777, 0o755)

    def test_vendored_c_and_header_inputs_recover_only_verified_timestamps(self):
        vendor = self.root / 'Vendor/sqlite-vec'
        vendor.mkdir(parents=True)
        source = vendor / 'sqlite-vec.c'
        header = vendor / 'sqlite-vec.h'
        for path in (source, header):
            path.write_text('int value = 1;\n')
            os.utime(path, ns=(self.original['mtime_ns'], self.original['mtime_ns']))
        self.git_add('Vendor')
        self.assertEqual(stamps.snapshot(self.root), 3)
        os.utime(source, None)
        header.write_text('int value = 2;\n')
        os.utime(header, ns=(self.original['mtime_ns'], self.original['mtime_ns']))
        with patch.object(stamps.time, 'time_ns', return_value=1800000000000000000):
            self.assertEqual(stamps.restore(self.root), (2, 1))
        self.assertEqual(source.stat().st_mtime_ns, self.original['mtime_ns'])
        self.assertEqual(header.stat().st_mtime_ns, 1800000000000000000)
        self.assertEqual(header.read_text(), 'int value = 2;\n')

    def test_repository_vendored_includes_belong_to_source_inventory(self):
        # This is a real dependency outside Sources, not a SwiftPM package URL.
        wrapper = ROOT / 'Sources/CSQLiteVecResearch/SQLiteVecResearch.c'
        self.assertIn('../../Vendor/sqlite-vec/sqlite-vec.c', wrapper.read_text())
        inventory = stamps.inputs(ROOT)
        for name in ('Vendor/sqlite-vec/sqlite-vec.c', 'Vendor/sqlite-vec/sqlite-vec.h'):
            self.assertTrue(name in inventory, f'Missing compiled vendor input: {name}')

    def test_every_quoted_include_reachable_from_sources_is_inventoried(self):
        # Any C-family target may include a repository file outside Sources.
        # Walk quoted includes transitively so a new out-of-tree input cannot
        # silently keep fresh-checkout timestamps behind a restored wrapper.
        inventory = stamps.inputs(ROOT)
        root = ROOT.resolve()
        suffixes = {'.c', '.h', '.m', '.mm', '.cc', '.cpp', '.hpp'}
        pending = [path.resolve() for name, path in inventory.items()
                   if name.startswith('Sources/') and path.suffix in suffixes]
        seen = set(pending)
        directive = re.compile(r'^\s*#\s*(?:include|import)\s*"([^"]+)"', re.MULTILINE)
        while pending:
            current = pending.pop()
            for target in directive.findall(current.read_text(errors='replace')):
                included = (current.parent / target).resolve()
                if not included.is_file() or included in seen:
                    continue
                seen.add(included)
                pending.append(included)
                if included.is_relative_to(root):
                    name = included.relative_to(root).as_posix()
                    self.assertTrue(name in inventory, f'Missing compiled input: {name}')

    def test_added_deleted_and_renamed_inputs_are_not_resurrected(self):
        self.source.unlink()
        new = self.root / 'Sources/Renamed.swift'
        new.write_text('let value = 1\n')
        self.git_add('Sources')
        self.assertEqual(stamps.restore(self.root), (0, 1))
        self.assertFalse(self.source.exists())
        self.assertNotEqual(new.stat().st_mtime_ns, self.original['mtime_ns'])

    def test_untracked_docs_and_outside_symlinks_are_never_touched(self):
        outside = self.root / 'external.swift'
        outside.write_text('outside')
        link = self.root / 'Sources/Linked.swift'
        link.symlink_to(outside)
        note = self.root / 'README.md'
        note.write_text('docs')
        self.git_add('Sources')
        self.git_add('README.md')
        before = {p: p.lstat().st_mtime_ns for p in (outside, link, note)}
        stamps.snapshot(self.root)
        stamps.restore(self.root)
        self.assertEqual(before, {p: p.lstat().st_mtime_ns for p in before})
        self.assertEqual(set(json.loads(self.receipt.read_text())['files']), {'Sources/Example.swift'})

    def test_receipt_cannot_choose_files_outside_current_git_inventory(self):
        other = self.root / 'untracked.txt'
        other.write_text('untouched')
        record = stamps.fingerprint(other)
        payload = json.loads(self.receipt.read_text())
        payload['files']['untracked.txt'] = dict(record, mtime_ns=1)
        self.receipt.write_text(json.dumps(payload))
        stamps.restore(self.root)
        self.assertEqual(stamps.fingerprint(other), record)

    def test_invalid_receipts_fail_before_any_timestamp_is_changed(self):
        valid = json.loads(self.receipt.read_text())
        broken = [None, {}, {'schema': True, 'files': valid['files']},
                  {'schema': 1, 'files': {}}, {'schema': 2, 'files': valid['files']}]
        for field, value in [('mtime_ns', True), ('mtime_ns', -1), ('mtime_ns', 2**63),
                             ('sha256', 'x'), ('size', -1), ('mode', '644')]:
            copy = json.loads(json.dumps(valid))
            copy['files']['Sources/Example.swift'][field] = value
            broken.append(copy)
        for name in ('../outside', '/outside'):
            broken.append({'schema': 1, 'files': {name: self.original}})
        for payload in broken:
            with self.subTest(payload=payload):
                os.utime(self.source, None)
                before = self.source.stat().st_mtime_ns
                self.receipt.write_text(json.dumps(payload))
                with self.assertRaises(ValueError):
                    stamps.restore(self.root)
                self.assertEqual(self.source.stat().st_mtime_ns, before)

    def test_missing_duplicate_malformed_and_oversize_receipts_are_rejected(self):
        for value in ('{', '{"schema":1,"schema":1,"files":{}}', ' ' * (4 * 1024 * 1024 + 1)):
            self.receipt.write_text(value)
            with self.assertRaises(ValueError):
                stamps.restore(self.root)
        self.receipt.unlink()
        with self.assertRaises(FileNotFoundError):
            stamps.restore(self.root)

    def test_snapshot_records_metadata_not_source_content_and_does_not_touch_source(self):
        self.assertEqual(stamps.snapshot(self.root), 1)
        self.assertNotIn('let value', self.receipt.read_text())
        self.assertEqual(stamps.fingerprint(self.source), self.original)

    def test_snapshot_of_many_inputs_round_trips_through_restore(self):
        for index in range(500):
            (self.root / f'Sources/Generated{index}.swift').write_text(f'let value{index} = {index}\n')
        self.git_add('Sources')
        self.assertEqual(stamps.snapshot(self.root), 501)
        self.assertEqual(stamps.restore(self.root), (501, 0))

    def test_snapshot_refuses_a_receipt_that_restore_would_reject(self):
        self.receipt.unlink()
        with patch.object(stamps, 'MAX_RECEIPT_BYTES', 64):
            with self.assertRaises(ValueError):
                stamps.snapshot(self.root)
        self.assertFalse(self.receipt.exists())

    def test_changed_during_fingerprint_is_rejected(self):
        real = os.stat(self.source)
        from types import SimpleNamespace
        with patch.object(stamps.os, 'fstat', side_effect=[real, SimpleNamespace(
            st_size=real.st_size + 1, st_mtime_ns=real.st_mtime_ns)]):
            with self.assertRaises(ValueError):
                stamps.fingerprint(self.source)


if __name__ == '__main__':
    unittest.main()
