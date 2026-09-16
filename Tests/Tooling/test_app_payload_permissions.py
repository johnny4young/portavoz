"""The installed payload must be readable and complete for the installing user.

A staged resource bundle that keeps its build-time owner-only modes, or that
lands outside `Contents/Resources`, passes signing, notarization and Gatekeeper
and then ends the app at first use on every Mac except the one that built it.
"""

from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MAKE_APP = (ROOT / "scripts/make-app.sh").read_text(encoding="utf-8")
VERIFY = (ROOT / "scripts/verify-distribution.sh").read_text(encoding="utf-8")
PAYLOAD = ROOT / "scripts/verify-app-payload.sh"


def make_app(root: Path, *, resolved: str | None, loadable: bool = True, mode: int = 0o755) -> Path:
    """A synthetic app whose binary reports what a real one would report."""
    app = root / "Portavoz.app"
    staged = app / "Contents/Resources/Portavoz_IntelligenceKit.bundle"
    (staged / "PortavozLiveQuestionClassifier.mlmodelc").mkdir(parents=True)
    (staged / "Info.plist").write_text("", encoding="utf-8")
    binary = app / "Contents/MacOS/portavoz-app"
    binary.parent.mkdir(parents=True)
    reported = staged if resolved is None else Path(resolved)
    binary.write_text(
        "#!/bin/bash\n"
        f'printf "classifierBundle={reported}\\nclassifierLoadable={str(loadable).lower()}\\n"\n'
        f"exit {0 if loadable else 1}\n",
        encoding="utf-8",
    )
    os.chmod(binary, 0o755)
    os.chmod(staged, mode)
    return app


class AppPayloadPermissionTests(unittest.TestCase):
    def test_packaging_normalises_modes_before_it_signs(self):
        normalise = MAKE_APP.index('chmod -R u+rwX,go+rX,go-w "$APP"')
        self.assertLess(
            normalise,
            MAKE_APP.index("codesign "),
            "the signature must cover the corrected modes",
        )
        self.assertLess(
            MAKE_APP.index('cp -R "$QUESTION_BUNDLE" "$APP/Contents/Resources/"'),
            normalise,
            "resources are staged before they are normalised",
        )

    def test_distribution_verification_runs_the_payload_gate_on_a_trusted_copy(self):
        self.assertIn('scripts/verify-app-payload.sh "$APP_COPY"', VERIFY)
        gate = VERIFY.index("verify-app-payload.sh")
        for trust in ("codesign --verify --deep --strict", "xcrun stapler validate", "spctl -a -vvv -t exec"):
            self.assertLess(
                VERIFY.index(trust),
                gate,
                "the extracted app runs only after its signature, ticket and Gatekeeper verdict passed",
            )
        self.assertLess(
            gate,
            VERIFY.index("record-distribution"),
            "no receipt is written for a payload the installing user cannot use",
        )

    def run_payload_gate(self, app: Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(PAYLOAD), str(app)], capture_output=True, text=True, check=False
        )

    def test_payload_gate_accepts_an_app_that_resolves_inside_itself(self):
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(Path(directory), resolved=None)
            completed = self.run_payload_gate(app)
            self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_payload_gate_rejects_an_unreadable_staged_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(Path(directory), resolved=None, mode=0o700)
            completed = self.run_payload_gate(app)
            self.assertEqual(completed.returncode, 65)
            self.assertIn("cannot read", completed.stderr)

    def test_payload_gate_rejects_a_missing_classifier(self):
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(Path(directory), resolved=None)
            (app / "Contents/Resources/Portavoz_IntelligenceKit.bundle"
             / "PortavozLiveQuestionClassifier.mlmodelc").rmdir()
            completed = self.run_payload_gate(app)
            self.assertEqual(completed.returncode, 65)
            self.assertIn("staged Apuntador question classifier", completed.stderr)

    def test_payload_gate_rejects_resolution_from_the_build_machine(self):
        with tempfile.TemporaryDirectory() as directory:
            build_path = Path(directory) / ".build/release/Portavoz_IntelligenceKit.bundle"
            build_path.mkdir(parents=True)
            app = make_app(Path(directory), resolved=str(build_path))
            completed = self.run_payload_gate(app)
            self.assertEqual(completed.returncode, 65)
            self.assertIn("outside its own payload", completed.stderr)

    def test_payload_gate_rejects_a_bundle_whose_model_cannot_load(self):
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(Path(directory), resolved=None, loadable=False)
            completed = self.run_payload_gate(app)
            self.assertEqual(completed.returncode, 65)
            self.assertIn("could not resolve its bundled assets", completed.stderr)

    def test_module_resources_resolve_without_the_trapping_accessor(self):
        sources = list((ROOT / "Sources").rglob("*.swift"))
        offenders = [
            path.relative_to(ROOT)
            for path in sources
            if re.search(r"\bBundle\.module\b", path.read_text(encoding="utf-8"))
            and path.name != "IntelligenceResourceBundle.swift"
        ]
        self.assertEqual(offenders, [], "the generated accessor traps instead of degrading")
        resolver = (ROOT / "Sources/IntelligenceKit/IntelligenceResourceBundle.swift").read_text(
            encoding="utf-8"
        )
        self.assertLess(
            resolver.index("mainResources"),
            resolver.index("moduleContainer"),
            "the packaged staging location is searched before the build directory",
        )


if __name__ == "__main__":
    unittest.main()
