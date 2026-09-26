"""Executable contract for the hosted interruption-control evidence archive."""

import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ARCHIVER = ROOT / "scripts/archive-ui-interruption-evidence.sh"


class UIInterruptionEvidenceArchiveTests(unittest.TestCase):
    def test_retains_receipts_and_raw_case_results_but_not_disposable_build(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            evidence = root / "evidence"
            evidence.mkdir()
            (evidence / "qualification.json").write_text('{"passed":true}')
            (evidence / "control.log").write_text("synthetic only")
            (evidence / "control.exit").write_text("0\n")
            result = evidence / "control.xcresult"
            result.mkdir()
            (result / "Info.plist").write_text("result")
            build = evidence / "build" / "Build" / "Products"
            build.mkdir(parents=True)
            (build / "Disposable.app").write_text("not evidence")
            (evidence / "InterruptionProof.xcodeproj").mkdir()
            (evidence / "control.ips").write_text("unexpected but retained")
            archive = root / "receipt.tar.gz"

            subprocess.run([str(ARCHIVER), str(evidence), str(archive)], check=True)
            with tarfile.open(archive, "r:gz") as bundle:
                names = set(bundle.getnames())
                self.assertEqual(
                    names,
                    {"qualification.json", "control.log", "control.exit", "control.ips",
                     "control.xcresult", "control.xcresult/Info.plist"},
                )
                self.assertEqual(
                    bundle.extractfile("qualification.json").read(), b'{"passed":true}'
                )

    def test_empty_or_overwriting_archive_fails_closed(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            evidence = root / "evidence"
            evidence.mkdir()
            archive = root / "receipt.tar.gz"
            empty = subprocess.run([str(ARCHIVER), str(evidence), str(archive)],
                                   capture_output=True, text=True, check=False)
            self.assertEqual(empty.returncode, 2)
            self.assertFalse(archive.exists())

            (evidence / "control.log").write_text("synthetic only")
            archive.write_text("existing")
            overwrite = subprocess.run([str(ARCHIVER), str(evidence), str(archive)],
                                       capture_output=True, text=True, check=False)
            self.assertEqual(overwrite.returncode, 2)
            self.assertEqual(archive.read_text(), "existing")

            relative = subprocess.run([str(ARCHIVER), str(evidence), "relative.tar.gz"],
                                      cwd=root, capture_output=True, text=True, check=False)
            self.assertEqual(relative.returncode, 2)
            self.assertFalse((root / "relative.tar.gz").exists())

    def test_failed_control_still_preserves_partial_log_without_qualification(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            evidence = root / "evidence"
            evidence.mkdir()
            (evidence / "build.log").write_text("synthetic build refused")
            archive = root / "receipt.tar.gz"

            subprocess.run([str(ARCHIVER), str(evidence), str(archive)], check=True)
            with tarfile.open(archive, "r:gz") as bundle:
                self.assertEqual(bundle.getnames(), ["build.log"])


if __name__ == "__main__":
    unittest.main()
