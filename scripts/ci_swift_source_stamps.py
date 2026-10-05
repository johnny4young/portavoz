#!/usr/bin/env python3
"""Preserve source freshness only when bytes and mode match a successful build."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
RECEIPT = Path('.build/ci-source-stamps.json')
FIELDS = {'sha256', 'size', 'mode', 'mtime_ns'}
MAX_RECEIPT_BYTES = 4 * 1024 * 1024


def inputs(root: Path) -> dict[str, Path]:
    # CSQLiteVecResearch includes vendored C and headers directly. Their
    # freshness belongs to the same verified build-input inventory as Sources.
    names = subprocess.check_output(
        ['git', 'ls-files', '-z', '--', 'Sources', 'Tests', 'Vendor', 'Package.swift', 'Package.resolved'],
        cwd=root, timeout=30,
    )
    result = {}
    for raw in names.split(b'\0'):
        if not raw:
            continue
        name = os.fsdecode(raw)
        path = root / name
        # Never change a symlink or anything outside the current checkout.
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
            continue
        result[name] = path
    return result


def fingerprint(path: Path) -> dict:
    with path.open('rb') as handle:
        before = os.fstat(handle.fileno())
        hasher = hashlib.sha256()
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            hasher.update(block)
        digest = hasher.hexdigest()
        after = os.fstat(handle.fileno())
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise ValueError('Source changed while collecting its fingerprint')
    return {'sha256': digest, 'size': after.st_size,
            'mode': stat.S_IMODE(after.st_mode), 'mtime_ns': after.st_mtime_ns}


def snapshot(root: Path) -> int:
    files = {name: fingerprint(path) for name, path in inputs(root).items()}
    if not files:
        raise ValueError('No tracked build inputs')
    receipt = root / RECEIPT
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps({'schema': 1, 'files': files}, sort_keys=True) + '\n')
    # Seeds are immutable: never leave a receipt that restore would reject.
    try:
        read_receipt(receipt)
    except ValueError:
        receipt.unlink()
        raise
    return len(files)


def read_receipt(path: Path) -> dict:
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate source receipt key')
            result[key] = value
        return result

    if path.stat().st_size > MAX_RECEIPT_BYTES:
        raise ValueError('Oversized source receipt')
    payload = json.loads(path.read_text(), object_pairs_hook=unique_object)
    if (not isinstance(payload, dict) or set(payload) != {'schema', 'files'}
            or type(payload['schema']) is not int or payload['schema'] != 1
            or not isinstance(payload['files'], dict) or not payload['files']):
        raise ValueError('Invalid source receipt')
    for name, record in payload['files'].items():
        if (not isinstance(name, str) or Path(name).is_absolute() or '..' in Path(name).parts
                or not isinstance(record, dict) or set(record) != FIELDS
                or not isinstance(record['sha256'], str)
                or not re.fullmatch('[a-f0-9]{64}', record['sha256'])
                or any(type(record[field]) is not int for field in ('size', 'mode', 'mtime_ns'))
                or not 0 <= record['size'] <= 2**63 - 1
                or not 0 <= record['mode'] <= 0o7777
                or not 0 <= record['mtime_ns'] <= 2**63 - 1):
            raise ValueError('Invalid source fingerprint')
    return payload['files']


def restore(root: Path) -> tuple[int, int]:
    records = read_receipt(root / RECEIPT)
    unchanged = changed = 0
    for name, path in inputs(root).items():
        current = fingerprint(path)
        previous = records.get(name)
        identical = previous is not None and all(
            current[field] == previous[field] for field in ('sha256', 'size', 'mode'))
        # A changed same-size file must invalidate even if its timestamp was
        # accidentally preserved. New files likewise retain fresh build input.
        stamp = previous['mtime_ns'] if identical else time.time_ns()
        os.utime(path, ns=(path.stat().st_atime_ns, stamp), follow_symlinks=False)
        unchanged += int(identical)
        changed += int(not identical)
    return unchanged, changed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('snapshot', 'restore'))
    args = parser.parse_args()
    try:
        if args.operation == 'snapshot':
            print(f'Recorded {snapshot(ROOT)} tracked source fingerprints')
        else:
            unchanged, changed = restore(ROOT)
            print(f'Source freshness: {unchanged} byte-identical; {changed} new or changed')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Cannot verify cached source freshness: {error}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
