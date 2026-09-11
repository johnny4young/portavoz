import argparse
import copy
import io
import json
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import assistive_technology_qualification as assistive  # noqa: E402
import release_reliability as reliability  # noqa: E402


class FakeCandidateProcess:
    pid = 4312
    captured_command = None
    captured_environment = None

    def __init__(self, command, *, env, stdout, stderr, start_new_session):
        del stdout, stderr
        self.__class__.captured_command = command
        self.__class__.captured_environment = env
        self._returncode = None
        self.start_new_session = start_new_session
        Path(env["PORTAVOZ_UI_TEST_SEED_READY_PATH"]).touch()

    def poll(self):
        return self._returncode

    def wait(self, timeout=None):
        del timeout
        self._returncode = 0
        return 0


class AssistiveTechnologyQualificationTests(unittest.TestCase):
    version = "1.0.0"
    build = "202608260001"
    commit = "a" * 40
    timestamp = "2026-08-26T12:00:00Z"

    def setUp(self):
        self.contract_document = json.loads(assistive.DEFAULT_CONTRACT.read_text())
        self.contract, self.contract_digest = assistive.load_contract()
        self.release = {
            "version": self.version,
            "build": self.build,
            "commit": self.commit,
        }
        self.app = {
            "bundleIdentifier": "app.portavoz.mac.dev",
            "executableSHA256": "1" * 64,
            "infoPlistSHA256": "2" * 64,
            "codeResourcesSHA256": "3" * 64,
            "signingKind": "developer-id",
            "signingTeamScopeSHA256": "4" * 64,
        }
        self.manifest = {
            "schemaVersion": 1,
            "kind": "assistive-technology-qualification-run",
            "runID": "11111111-1111-4111-8111-111111111111",
            "createdAt": self.timestamp,
            "release": self.release,
            "contractSHA256": self.contract_digest,
            "candidateReceiptSHA256": "5" * 64,
            "app": self.app,
            "runNonce": "6" * 64,
        }

    def test_contract_freezes_four_cells_bilingual_journey_and_real_selectors(self):
        self.assertEqual(
            tuple(
                (row["id"], row["minimumMajor"], row["maximumMajor"])
                for row in self.contract["platforms"]
            ),
            assistive.EXPECTED_PLATFORMS,
        )
        self.assertEqual(
            [row["id"] for row in self.contract["technologies"]],
            ["voiceover", "voice-control"],
        )
        self.assertEqual(
            [row["id"] for row in self.contract["locales"]], ["en", "es"]
        )
        self.assertEqual(
            tuple(
                (row["id"], tuple(row["automationSelectors"]))
                for row in self.contract["checkpoints"]
            ),
            assistive.EXPECTED_CHECKPOINTS,
        )
        proofs = {
            assistive.proof_for(self.contract, technology, platform)
            for technology in ("voiceover", "voice-control")
            for platform in ("sequoia", "tahoe")
        }
        self.assertEqual(
            proofs,
            set(
                reliability.QUALIFICATION_RECEIPTS["assistive-technology"][
                    "proofs"
                ]
            ),
        )
        for _, selectors in assistive.EXPECTED_CHECKPOINTS:
            for selector in selectors:
                _, class_name, method = selector.split("/")
                matching_files = [
                    path
                    for path in (ROOT / "Tests" / "PortavozUITests").glob("*.swift")
                    if f"final class {class_name}" in path.read_text()
                    and f"func {method}(" in path.read_text()
                ]
                self.assertEqual(len(matching_files), 1, selector)

    def test_contract_rejects_duplicate_or_weakened_matrix_rows(self):
        duplicate_platform = copy.deepcopy(self.contract_document)
        duplicate_platform["platforms"][1] = copy.deepcopy(
            duplicate_platform["platforms"][0]
        )
        with self.assertRaisesRegex(
            assistive.AssistiveQualificationError, "platform matrix"
        ):
            assistive.validate_contract(duplicate_platform)

        duplicate_technology = copy.deepcopy(self.contract_document)
        duplicate_technology["technologies"][1]["id"] = "voiceover"
        duplicate_technology["technologies"][1][
            "activationAuthority"
        ] = "nsworkspace-and-human"
        with self.assertRaisesRegex(
            assistive.AssistiveQualificationError, "technology matrix"
        ):
            assistive.validate_contract(duplicate_technology)

        reduced_journey = copy.deepcopy(self.contract_document)
        reduced_journey["checkpoints"] = reduced_journey["checkpoints"][:1]
        with self.assertRaisesRegex(
            assistive.AssistiveQualificationError, "fixed assistive journey"
        ):
            assistive.validate_contract(reduced_journey)

    def test_contract_rejects_duplicate_selector_and_noncontiguous_sequence(self):
        duplicate = copy.deepcopy(self.contract_document)
        duplicate["checkpoints"][1]["automationSelectors"][0] = duplicate[
            "checkpoints"
        ][0]["automationSelectors"][0]
        with self.assertRaisesRegex(
            assistive.AssistiveQualificationError, "repeats automation selector"
        ):
            assistive.validate_contract(duplicate)

        noncontiguous = copy.deepcopy(self.contract_document)
        noncontiguous["checkpoints"][1]["sequence"] = 9
        with self.assertRaisesRegex(
            assistive.AssistiveQualificationError, "contiguous and ordered"
        ):
            assistive.validate_contract(noncontiguous)

    def test_candidate_receipt_requires_owner_only_complete_candidate_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_candidate_receipt(root / "candidate.json")
            document, release = assistive.validate_candidate_receipt(receipt)
            self.assertEqual(release, self.release)
            self.assertEqual(document["scope"], "candidate-automation")

            os.chmod(receipt, 0o644)
            with self.assertRaisesRegex(
                assistive.AssistiveQualificationError, "mode 0600"
            ):
                assistive.validate_candidate_receipt(receipt)

    def test_atomic_write_is_owner_only_and_never_clobbers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "receipt.json"
            assistive.atomic_write_json(output, {"state": "pass"})
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            with self.assertRaisesRegex(
                assistive.AssistiveQualificationError, "already exists"
            ):
                assistive.atomic_write_json(output, {"state": "fail"})
            self.assertEqual(json.loads(output.read_text()), {"state": "pass"})

    def test_initialize_binds_exact_candidate_bytes_and_rejects_root_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = self.write_candidate_receipt(root / "candidate.json")
            evidence = root / "evidence"
            arguments = argparse.Namespace(
                evidence_root=evidence,
                candidate_receipt=candidate,
                app=root / "Portavoz Dev.app",
                version=self.version,
                build=self.build,
                commit=self.commit,
            )
            app_info = {
                "path": arguments.app,
                "executable": arguments.app / "Contents/MacOS/Portavoz",
                "release": self.release,
                "identity": self.app,
            }
            with mock.patch.object(
                assistive, "require_exact_checkout"
            ) as checkout, mock.patch.object(
                assistive, "inspect_candidate_app", return_value=app_info
            ):
                assistive.initialize(arguments)
            manifest = json.loads((evidence / "run.json").read_text())
            self.assertEqual(manifest["release"], self.release)
            self.assertEqual(
                manifest["candidateReceiptSHA256"], assistive.sha256_file(candidate)
            )
            self.assertEqual(manifest["app"], self.app)
            self.assertFalse((evidence / "cells").exists())
            checkout.assert_called_once_with(self.commit)

            linked = root / "linked-evidence"
            target = root / "empty-target"
            target.mkdir(mode=0o700)
            linked.symlink_to(target)
            arguments.evidence_root = linked
            with self.assertRaisesRegex(
                assistive.AssistiveQualificationError, "must be a directory"
            ):
                assistive.initialize(arguments)

    def test_authority_pair_publication_is_atomic_and_non_overwriting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "authority"
            authority = {"kind": "assistive-technology-authority"}
            receipt = {"kind": "qualification"}
            original_write = assistive.atomic_write_json

            def fail_qualification(path, document):
                if path.name == "qualification.json":
                    raise OSError("simulated publication failure")
                original_write(path, document)

            with mock.patch.object(
                assistive, "atomic_write_json", side_effect=fail_qualification
            ), self.assertRaisesRegex(OSError, "simulated publication failure"):
                assistive.publish_authority(output, authority, receipt)
            self.assertFalse(output.exists())
            self.assertEqual(list(root.glob(".authority.*")), [])

            assistive.publish_authority(output, authority, receipt)
            with self.assertRaisesRegex(
                assistive.AssistiveQualificationError, "must be absent"
            ):
                assistive.publish_authority(output, authority, receipt)
            self.assertEqual(
                json.loads((output / "authority.json").read_text()), authority
            )
            self.assertEqual(
                json.loads((output / "qualification.json").read_text()), receipt
            )

    def test_candidate_app_requires_dev_identity_developer_id_and_exact_seals(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_candidate_app(Path(directory))

            def runner(arguments, **kwargs):
                self.assertIn("timeout", kwargs)
                if "-dvvv" in arguments:
                    return subprocess.CompletedProcess(
                        arguments,
                        0,
                        stdout="",
                        stderr=(
                            "Authority=Developer ID Application: Example (TEAM123456)\n"
                            "TeamIdentifier=TEAM123456\n"
                        ),
                    )
                return subprocess.CompletedProcess(arguments, 0, "", "")

            first = assistive.inspect_candidate_app(app, "a" * 64, runner=runner)
            second = assistive.inspect_candidate_app(app, "b" * 64, runner=runner)
            self.assertEqual(first["release"], self.release)
            self.assertNotEqual(
                first["identity"]["signingTeamScopeSHA256"],
                second["identity"]["signingTeamScopeSHA256"],
            )
            for key in (
                "executableSHA256",
                "infoPlistSHA256",
                "codeResourcesSHA256",
            ):
                self.assertRegex(first["identity"][key], r"^[0-9a-f]{64}$")

            def adhoc_runner(arguments, **kwargs):
                del kwargs
                details = "TeamIdentifier=TEAM123456\n" if "-dvvv" in arguments else ""
                return subprocess.CompletedProcess(arguments, 0, "", details)

            with self.assertRaisesRegex(
                assistive.AssistiveQualificationError, "real Developer ID"
            ):
                assistive.inspect_candidate_app(app, "a" * 64, runner=adhoc_runner)

    def test_candidate_app_refuses_stable_app_and_caller_symlink(self):
        with self.assertRaisesRegex(
            assistive.AssistiveQualificationError, "never inspect"
        ):
            assistive.inspect_candidate_app(
                Path("/Applications/Portavoz.app"), "a" * 64
            )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.make_candidate_app(root)
            link = root / "Linked.app"
            link.symlink_to(app)
            with self.assertRaisesRegex(
                assistive.AssistiveQualificationError, "absolute real path"
            ):
                assistive.inspect_candidate_app(link, "a" * 64)

    def test_voiceover_requires_system_and_human_while_voice_control_is_human_only(self):
        self.assertEqual(
            assistive.require_technology_active(
                "voiceover", "voiceover", voiceover_probe=lambda: True
            ),
            {"authority": "nsworkspace-and-human", "systemObserved": True},
        )
        with self.assertRaisesRegex(
            assistive.AssistiveQualificationError, "not running"
        ):
            assistive.require_technology_active(
                "voiceover", "voiceover", voiceover_probe=lambda: False
            )
        self.assertEqual(
            assistive.require_technology_active(
                "voice-control", "voice-control", voiceover_probe=lambda: False
            ),
            {"authority": "human-observed", "systemObserved": None},
        )
        with self.assertRaisesRegex(
            assistive.AssistiveQualificationError, "confirm-technology-active"
        ):
            assistive.require_technology_active("voice-control", "voiceover")

    def test_system_observation_is_arm64_exact_build_and_run_scoped(self):
        def result(arguments, **kwargs):
            self.assertEqual(kwargs["timeout"], 15)
            if arguments[-1] == "-productVersion":
                stdout = "15.6.1\n"
            elif arguments[-1] == "-buildVersion":
                stdout = "24G90\n"
            elif arguments[-1] == "-m":
                stdout = "arm64\n"
            else:
                stdout = '    "IOPlatformUUID" = "11111111-1111-4111-8111-111111111111"\n'
            return subprocess.CompletedProcess(arguments, 0, stdout, "")

        with mock.patch.object(assistive.subprocess, "run", side_effect=result):
            first = assistive.current_system_observation("a" * 64)
            second = assistive.current_system_observation("b" * 64)
        self.assertEqual(first["os"]["major"], 15)
        self.assertEqual(first["os"]["build"], "24G90")
        self.assertNotEqual(first["hostScopeSHA256"], second["hostScopeSHA256"])

    def test_launch_environment_removes_inherited_test_and_portavoz_state(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(
            os.environ,
            {
                "PORTAVOZ_PRIVATE": "forbidden",
                "TEST_RUNNER_PRIVATE": "forbidden",
                "XCTestConfigurationFilePath": "forbidden",
                "SAFE_PARENT": "preserved",
            },
            clear=True,
        ):
            environment = assistive.launch_environment(Path(directory))
        self.assertEqual(environment["SAFE_PARENT"], "preserved")
        self.assertNotIn("PORTAVOZ_PRIVATE", environment)
        self.assertNotIn("TEST_RUNNER_PRIVATE", environment)
        self.assertNotIn("XCTestConfigurationFilePath", environment)
        self.assertEqual(
            set(self.contract["launch"]["environmentKeys"]),
            {
                key
                for key in environment
                if key.startswith("PORTAVOZ_") or key == "TMPDIR"
            },
        )

    def test_start_locale_launches_one_exact_disposable_public_seed(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(
            os.environ,
            {"PORTAVOZ_PRIVATE": "forbidden", "SAFE_PARENT": "preserved"},
            clear=True,
        ):
            root = Path(directory) / "evidence"
            root.mkdir(mode=0o700)
            executable = Path(directory) / "Portavoz Dev"
            app_info = {
                "path": Path(directory) / "Portavoz Dev.app",
                "executable": executable,
                "release": self.release,
                "identity": self.app,
            }
            arguments = argparse.Namespace(
                evidence_root=root,
                app=Path(directory) / "Portavoz Dev.app",
                technology="voice-control",
                locale="en",
                confirm_technology_active="voice-control",
            )
            with self.start_boundaries(root, app_info), mock.patch.object(
                assistive.subprocess, "Popen", FakeCandidateProcess
            ):
                assistive.start_locale(arguments)

            cell = assistive.cell_root(root, "voice-control-sequoia")
            session = json.loads(assistive.session_path(cell, "en").read_text())
            self.assertEqual(session["locale"], "en")
            self.assertEqual(session["activation"]["authority"], "human-observed")
            self.assertEqual(FakeCandidateProcess.captured_command[0], str(executable))
            self.assertEqual(
                FakeCandidateProcess.captured_command[1:],
                assistive.launch_arguments(self.contract, "en"),
            )
            environment = FakeCandidateProcess.captured_environment
            self.assertNotIn("PORTAVOZ_PRIVATE", environment)
            self.assertEqual(environment["SAFE_PARENT"], "preserved")
            self.assertTrue(assistive.runtime_path(cell, "en").is_dir())
            self.assertFalse((root / ".start-locale.lock").exists())

    def test_start_locale_serializes_globally_before_launching(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "evidence"
            root.mkdir(mode=0o700)
            app_info = {
                "path": Path(directory) / "Portavoz Dev.app",
                "executable": Path(directory) / "Portavoz Dev",
                "release": self.release,
                "identity": self.app,
            }
            (root / ".start-locale.lock").write_text("")
            os.chmod(root / ".start-locale.lock", 0o600)
            arguments = argparse.Namespace(
                evidence_root=root,
                app=app_info["path"],
                technology="voice-control",
                locale="en",
                confirm_technology_active="voice-control",
            )
            with self.start_boundaries(root, app_info), self.assertRaisesRegex(
                assistive.AssistiveQualificationError,
                "start-locale is already in progress",
            ):
                assistive.start_locale(arguments)

    def test_start_locale_requires_completed_english_before_spanish(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "evidence"
            root.mkdir(mode=0o700)
            app_info = {
                "path": Path(directory) / "Portavoz Dev.app",
                "executable": Path(directory) / "Portavoz Dev",
                "release": self.release,
                "identity": self.app,
            }
            arguments = argparse.Namespace(
                evidence_root=root,
                app=app_info["path"],
                technology="voice-control",
                locale="es",
                confirm_technology_active="voice-control",
            )
            with self.start_boundaries(root, app_info), mock.patch.object(
                assistive.subprocess, "Popen"
            ) as launch, self.assertRaisesRegex(
                assistive.AssistiveQualificationError,
                "locale es requires completed locale en",
            ):
                assistive.start_locale(arguments)

            launch.assert_not_called()

    def test_failed_launch_preserves_runtime_when_graceful_cleanup_times_out(self):
        class UnstoppableCandidate(FakeCandidateProcess):
            def wait(self, timeout=None):
                raise subprocess.TimeoutExpired("Portavoz Dev", timeout)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "evidence"
            root.mkdir(mode=0o700)
            app_info = {
                "path": Path(directory) / "Portavoz Dev.app",
                "executable": Path(directory) / "Portavoz Dev",
                "release": self.release,
                "identity": self.app,
            }
            arguments = argparse.Namespace(
                evidence_root=root,
                app=app_info["path"],
                technology="voice-control",
                locale="en",
                confirm_technology_active="voice-control",
            )
            with self.start_boundaries(root, app_info), mock.patch.object(
                assistive.subprocess, "Popen", UnstoppableCandidate
            ), mock.patch.object(
                assistive,
                "process_identity",
                side_effect=assistive.AssistiveQualificationError(
                    "simulated identity failure"
                ),
            ), mock.patch.object(assistive.os, "kill"), self.assertRaisesRegex(
                assistive.AssistiveQualificationError, "graceful cleanup"
            ):
                assistive.start_locale(arguments)

            cell = assistive.cell_root(root, "voice-control-sequoia")
            self.assertTrue(
                assistive.runtime_path(cell, "en").is_dir(),
                "scratch state must remain for diagnosis while the process may be alive",
            )
            self.assertFalse(assistive.session_path(cell, "en").exists())

    def test_observations_are_ordered_content_free_and_digest_chained(self):
        with tempfile.TemporaryDirectory() as directory:
            context = self.materialize_active_locale(
                Path(directory), "voice-control", "en"
            )
            first = self.contract["checkpoints"][0]["id"]
            second = self.contract["checkpoints"][1]["id"]
            with self.active_boundaries(context):
                assistive.observe_checkpoint(
                    self.observe_args(context, first, "pass")
                )
                with self.assertRaisesRegex(
                    assistive.AssistiveQualificationError, "next checkpoint"
                ):
                    assistive.observe_checkpoint(
                        self.observe_args(
                            context, self.contract["checkpoints"][2]["id"], "pass"
                        )
                    )
                assistive.observe_checkpoint(
                    self.observe_args(context, second, "pass")
                )

            first_path = assistive.receipt_path(context["cell_path"], "en", 1, first)
            second_document = json.loads(
                assistive.receipt_path(
                    context["cell_path"], "en", 2, second
                ).read_text()
            )
            self.assertEqual(
                second_document["predecessorSHA256"], assistive.sha256_file(first_path)
            )
            assistive.validate_no_content_keys(second_document, "observation")

    def test_failed_observation_is_immutable_and_closes_only_owned_process(self):
        with tempfile.TemporaryDirectory() as directory:
            context = self.materialize_active_locale(
                Path(directory), "voice-control", "es"
            )
            checkpoint = self.contract["checkpoints"][0]["id"]
            with self.active_boundaries(context), mock.patch.object(
                assistive, "terminate_owned_process"
            ) as terminate:
                assistive.observe_checkpoint(
                    self.observe_args(context, checkpoint, "fail")
                )
            terminate.assert_called_once_with(
                context["session"]["processID"],
                context["app_info"]["executable"],
                context["session"]["processStarted"],
                self.contract["limits"]["processExitTimeoutSeconds"],
            )
            self.assertFalse(assistive.runtime_path(context["cell_path"], "es").exists())
            with self.active_boundaries(context), self.assertRaisesRegex(
                assistive.AssistiveQualificationError, "immutable"
            ):
                assistive.observe_checkpoint(
                    self.observe_args(
                        context, self.contract["checkpoints"][1]["id"], "pass"
                    )
                )

    def test_finish_requires_every_pass_and_writes_digest_bound_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            context = self.materialize_active_locale(
                Path(directory), "voiceover", "en"
            )
            self.write_all_observations(context)
            arguments = argparse.Namespace(
                evidence_root=context["root"],
                app=context["app_info"]["path"],
                technology="voiceover",
                locale="en",
                confirm_technology_active="voiceover",
            )
            with self.active_boundaries(context), mock.patch.object(
                assistive, "terminate_owned_process"
            ) as terminate:
                assistive.finish_locale(arguments)

            completion_file = assistive.completion_path(context["cell_path"], "en")
            completion = json.loads(completion_file.read_text())
            self.assertTrue(completion["appExited"])
            self.assertEqual(
                completion["sessionSHA256"],
                assistive.sha256_file(
                    assistive.session_path(context["cell_path"], "en")
                ),
            )
            terminate.assert_called_once()
            self.assertFalse(assistive.runtime_path(context["cell_path"], "en").exists())

    def test_publication_rejects_symlink_or_non_owner_parent_without_chmod(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            weak_parent = root / "weak"
            weak_parent.mkdir(mode=0o755)
            os.chmod(weak_parent, 0o755)
            with self.assertRaisesRegex(
                assistive.AssistiveQualificationError, "mode 0700"
            ):
                assistive.publish_authority(
                    weak_parent / "authority", {"a": 1}, {"b": 2}
                )
            self.assertEqual(stat.S_IMODE(weak_parent.stat().st_mode), 0o755)

            target = root / "target"
            link = root / "linked-output"
            link.symlink_to(target)
            with self.assertRaisesRegex(
                assistive.AssistiveQualificationError, "must not be a symlink"
            ):
                assistive.publish_authority(link, {"a": 1}, {"b": 2})

    def test_finalize_requires_complete_cross_platform_matrix_and_publishes_pair(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, candidate = self.materialize_complete_run(root)
            output = root / "assistive-authority"
            arguments = argparse.Namespace(
                evidence_root=evidence,
                candidate_receipt=candidate,
                output=output,
            )
            with mock.patch.object(assistive, "require_exact_checkout"):
                assistive.finalize(arguments)

            authority = json.loads((output / "authority.json").read_text())
            receipt = json.loads((output / "qualification.json").read_text())
            self.assertEqual(authority["kind"], "assistive-technology-authority")
            self.assertEqual(
                [cell["proof"] for cell in authority["cells"]],
                list(
                    reliability.QUALIFICATION_RECEIPTS["assistive-technology"][
                        "proofs"
                    ]
                ),
            )
            self.assertEqual(
                receipt["authoritySHA256"],
                reliability.canonical_document_sha256(authority),
            )
            validated, release, scope, proofs = reliability.validate_qualification_receipt(
                receipt, "assistive qualification"
            )
            self.assertEqual(validated, receipt)
            self.assertEqual(release, self.release)
            self.assertEqual(scope, "assistive-technology")
            self.assertTrue(all(state == "pass" for state in proofs.values()))
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
            self.assertEqual(
                stat.S_IMODE((output / "authority.json").stat().st_mode), 0o600
            )

    def test_finalize_rejects_same_host_across_sequoia_and_tahoe(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, candidate = self.materialize_complete_run(
                root, tahoe_host="7" * 64
            )
            for proof in ("voiceover-sequoia", "voice-control-sequoia"):
                cell_path = assistive.cell_root(evidence, proof) / "cell.json"
                cell = json.loads(cell_path.read_text())
                cell["hostScopeSHA256"] = "7" * 64
                self.rewrite_owner_json(cell_path, cell)
            with mock.patch.object(assistive, "require_exact_checkout"), self.assertRaisesRegex(
                assistive.AssistiveQualificationError, "distinct Mac host scopes"
            ):
                assistive.finalize(
                    argparse.Namespace(
                        evidence_root=evidence,
                        candidate_receipt=candidate,
                        output=root / "authority",
                    )
                )

    def test_finalize_rejects_extra_evidence_and_duplicate_process_nonce(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, candidate = self.materialize_complete_run(root)
            extra = assistive.cell_root(evidence, "voiceover-sequoia") / "extra"
            extra.write_text("unexpected")
            os.chmod(extra, 0o600)
            with mock.patch.object(assistive, "require_exact_checkout"), self.assertRaisesRegex(
                assistive.AssistiveQualificationError, "unexpected evidence"
            ):
                assistive.finalize(
                    argparse.Namespace(
                        evidence_root=evidence,
                        candidate_receipt=candidate,
                        output=root / "authority-extra",
                    )
                )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, candidate = self.materialize_complete_run(root)
            first = assistive.session_path(
                assistive.cell_root(evidence, "voiceover-sequoia"), "en"
            )
            second = assistive.session_path(
                assistive.cell_root(evidence, "voice-control-sequoia"), "en"
            )
            first_document = json.loads(first.read_text())
            second_document = json.loads(second.read_text())
            second_document["processNonce"] = first_document["processNonce"]
            self.rewrite_owner_json(second, second_document)
            predecessor = None
            for checkpoint in self.contract["checkpoints"]:
                observation_path = assistive.receipt_path(
                    second.parent.parent,
                    "en",
                    checkpoint["sequence"],
                    checkpoint["id"],
                )
                observation = json.loads(observation_path.read_text())
                observation["processNonce"] = first_document["processNonce"]
                observation["predecessorSHA256"] = predecessor
                self.rewrite_owner_json(observation_path, observation)
                predecessor = assistive.sha256_file(observation_path)
            completion = assistive.completion_path(second.parent.parent, "en")
            completion_document = json.loads(completion.read_text())
            completion_document["processNonce"] = first_document["processNonce"]
            completion_document["sessionSHA256"] = assistive.sha256_file(second)
            completion_document["lastObservationSHA256"] = predecessor
            self.rewrite_owner_json(completion, completion_document)
            with mock.patch.object(assistive, "require_exact_checkout"), self.assertRaisesRegex(
                assistive.AssistiveQualificationError, "unique app process"
            ):
                assistive.finalize(
                    argparse.Namespace(
                        evidence_root=evidence,
                        candidate_receipt=candidate,
                        output=root / "authority-duplicate",
                    )
                )

    def test_status_never_reports_pass_for_a_tampered_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, _ = self.materialize_complete_run(root)
            completion = assistive.completion_path(
                assistive.cell_root(evidence, "voiceover-sequoia"), "en"
            )
            completion_document = json.loads(completion.read_text())
            completion_document["sessionSHA256"] = "9" * 64
            self.rewrite_owner_json(completion, completion_document)

            output = io.StringIO()
            with mock.patch("sys.stdout", output):
                assistive.status(argparse.Namespace(evidence_root=evidence))

            self.assertIn("INVALID voiceover-sequoia", output.getvalue())
            self.assertNotIn("PASS    voiceover-sequoia/en", output.getvalue())

    def write_candidate_receipt(self, path):
        document = {
            "schemaVersion": 1,
            "kind": "qualification",
            "scope": "candidate-automation",
            "collectedAt": self.timestamp,
            "release": self.release,
            "proofs": [
                {"id": proof, "state": "pass"}
                for proof in reliability.QUALIFICATION_RECEIPTS[
                    "candidate-automation"
                ]["proofs"]
            ],
        }
        path.write_text(json.dumps(document))
        os.chmod(path, 0o600)
        return path

    def make_candidate_app(self, root):
        app = root / "Portavoz Dev.app"
        macos = app / "Contents" / "MacOS"
        signature = app / "Contents" / "_CodeSignature"
        macos.mkdir(parents=True)
        signature.mkdir()
        info = {
            "CFBundleIdentifier": "app.portavoz.mac.dev",
            "CFBundleDisplayName": "Portavoz Dev",
            "CFBundleName": "Portavoz Dev",
            "CFBundleExecutable": "Portavoz",
            "CFBundleShortVersionString": self.version,
            "CFBundleVersion": self.build,
            "PortavozSourceCommit": self.commit,
        }
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
        executable = macos / "Portavoz"
        executable.write_bytes(b"candidate executable")
        executable.chmod(0o755)
        (signature / "CodeResources").write_bytes(b"candidate seal")
        return app

    def system(self, major=15, host="7" * 64):
        return {
            "hostScopeSHA256": host,
            "os": {
                "major": major,
                "minor": 6 if major == 15 else 0,
                "patch": 0,
                "build": "24G90" if major == 15 else "25A123",
                "architecture": "arm64",
            },
        }

    def start_boundaries(self, root, app_info):
        del root
        return mock.patch.multiple(
            assistive,
            load_run=mock.Mock(
                return_value=(self.manifest, self.contract, self.contract_digest)
            ),
            require_exact_checkout=mock.Mock(),
            ensure_app_matches_manifest=mock.Mock(return_value=app_info),
            current_system_observation=mock.Mock(return_value=self.system()),
            require_technology_active=mock.Mock(
                return_value={
                    "authority": "human-observed",
                    "systemObserved": None,
                }
            ),
            running_candidate_pids=mock.Mock(return_value=[]),
            process_identity=mock.Mock(
                return_value="Wed Aug 26 12:00:00 2026"
            ),
        )

    def materialize_active_locale(self, root, technology, locale):
        if not root.exists():
            root.mkdir(mode=0o700)
        os.chmod(root, 0o700)
        platform = "sequoia"
        proof = assistive.proof_for(self.contract, technology, platform)
        cell_path = assistive.prepare_cell_directories(root, proof)
        activation = (
            {"authority": "nsworkspace-and-human", "systemObserved": True}
            if technology == "voiceover"
            else {"authority": "human-observed", "systemObserved": None}
        )
        cell = {
            "schemaVersion": 1,
            "kind": "assistive-technology-cell",
            "createdAt": self.timestamp,
            "runID": self.manifest["runID"],
            "proof": proof,
            "technology": technology,
            "platform": platform,
            "release": self.release,
            "contractSHA256": self.contract_digest,
            "candidateReceiptSHA256": self.manifest["candidateReceiptSHA256"],
            "app": self.app,
            "cellNonce": str(uuid.uuid5(uuid.NAMESPACE_DNS, proof)),
            "hostScopeSHA256": "7" * 64,
            "os": self.system()["os"],
        }
        assistive.atomic_write_json(cell_path / "cell.json", cell)
        session = {
            "schemaVersion": 1,
            "kind": "assistive-technology-locale-session",
            "startedAt": self.timestamp,
            "runID": self.manifest["runID"],
            "proof": proof,
            "technology": technology,
            "platform": platform,
            "locale": locale,
            "release": self.release,
            "contractSHA256": self.contract_digest,
            "candidateReceiptSHA256": self.manifest["candidateReceiptSHA256"],
            "app": self.app,
            "cellNonce": cell["cellNonce"],
            "processNonce": str(uuid.uuid5(uuid.NAMESPACE_URL, f"{proof}-{locale}")),
            "processID": 4312,
            "processStarted": "Wed Aug 26 12:00:00 2026",
            "seedReadySHA256": assistive.sha256_bytes(b""),
            "activation": activation,
        }
        assistive.atomic_write_json(assistive.session_path(cell_path, locale), session)
        runtime = assistive.runtime_path(cell_path, locale)
        runtime.mkdir(mode=0o700)
        app_info = {
            "path": root.parent / "Portavoz Dev.app",
            "executable": root.parent / "Portavoz Dev.app/Contents/MacOS/Portavoz",
            "release": self.release,
            "identity": self.app,
        }
        return {
            "root": root,
            "cell_path": cell_path,
            "cell": cell,
            "session": session,
            "app_info": app_info,
            "technology": technology,
            "locale": locale,
            "system": self.system(),
        }

    def active_boundaries(self, context):
        return mock.patch.multiple(
            assistive,
            load_active_context=mock.Mock(
                return_value=(
                    self.manifest,
                    self.contract,
                    context["app_info"],
                    context["system"],
                    context["cell"],
                    context["cell_path"],
                )
            ),
            require_exact_checkout=mock.DEFAULT,
            require_technology_active=mock.Mock(
                return_value=context["session"]["activation"]
            ),
        )

    def observe_args(self, context, checkpoint, outcome):
        return argparse.Namespace(
            evidence_root=context["root"],
            app=context["app_info"]["path"],
            technology=context["technology"],
            locale=context["locale"],
            checkpoint=checkpoint,
            outcome=outcome,
            confirm_technology_active=context["technology"],
            confirm_observation=f"{checkpoint}:{outcome}",
        )

    def write_all_observations(self, context):
        predecessor = None
        for checkpoint in self.contract["checkpoints"]:
            document = {
                "schemaVersion": 1,
                "kind": "assistive-technology-observation",
                "collectedAt": self.timestamp,
                "runID": self.manifest["runID"],
                "proof": context["cell"]["proof"],
                "technology": context["technology"],
                "platform": context["cell"]["platform"],
                "locale": context["locale"],
                "checkpoint": checkpoint["id"],
                "sequence": checkpoint["sequence"],
                "state": "pass",
                "observationAuthority": context["session"]["activation"]["authority"],
                "release": self.release,
                "contractSHA256": self.contract_digest,
                "candidateReceiptSHA256": self.manifest["candidateReceiptSHA256"],
                "app": self.app,
                "cellNonce": context["cell"]["cellNonce"],
                "processNonce": context["session"]["processNonce"],
                "hostScopeSHA256": context["cell"]["hostScopeSHA256"],
                "os": context["cell"]["os"],
                "predecessorSHA256": predecessor,
            }
            path = assistive.receipt_path(
                context["cell_path"],
                context["locale"],
                checkpoint["sequence"],
                checkpoint["id"],
            )
            assistive.atomic_write_json(path, document)
            predecessor = assistive.sha256_file(path)
        return predecessor

    def materialize_complete_run(self, root, tahoe_host="8" * 64):
        candidate = self.write_candidate_receipt(root / "candidate.json")
        evidence = root / "evidence"
        evidence.mkdir(mode=0o700)
        manifest = copy.deepcopy(self.manifest)
        manifest["candidateReceiptSHA256"] = assistive.sha256_file(candidate)
        assistive.atomic_write_json(evidence / "run.json", manifest)
        original_manifest = self.manifest
        self.manifest = manifest
        try:
            cell_index = 0
            process_index = 0
            for technology in ("voiceover", "voice-control"):
                for platform, major, host in (
                    ("sequoia", 15, "7" * 64),
                    ("tahoe", 26, tahoe_host),
                ):
                    cell_index += 1
                    proof = assistive.proof_for(self.contract, technology, platform)
                    cell_path = assistive.prepare_cell_directories(evidence, proof)
                    operating_system = self.system(major, host)["os"]
                    cell = {
                        "schemaVersion": 1,
                        "kind": "assistive-technology-cell",
                        "createdAt": self.timestamp,
                        "runID": manifest["runID"],
                        "proof": proof,
                        "technology": technology,
                        "platform": platform,
                        "release": self.release,
                        "contractSHA256": self.contract_digest,
                        "candidateReceiptSHA256": manifest[
                            "candidateReceiptSHA256"
                        ],
                        "app": self.app,
                        "cellNonce": str(
                            uuid.uuid5(uuid.NAMESPACE_DNS, f"cell-{cell_index}")
                        ),
                        "hostScopeSHA256": host,
                        "os": operating_system,
                    }
                    assistive.atomic_write_json(cell_path / "cell.json", cell)
                    for locale in ("en", "es"):
                        process_index += 1
                        activation = (
                            {
                                "authority": "nsworkspace-and-human",
                                "systemObserved": True,
                            }
                            if technology == "voiceover"
                            else {
                                "authority": "human-observed",
                                "systemObserved": None,
                            }
                        )
                        session = {
                            "schemaVersion": 1,
                            "kind": "assistive-technology-locale-session",
                            "startedAt": self.timestamp,
                            "runID": manifest["runID"],
                            "proof": proof,
                            "technology": technology,
                            "platform": platform,
                            "locale": locale,
                            "release": self.release,
                            "contractSHA256": self.contract_digest,
                            "candidateReceiptSHA256": manifest[
                                "candidateReceiptSHA256"
                            ],
                            "app": self.app,
                            "cellNonce": cell["cellNonce"],
                            "processNonce": str(
                                uuid.uuid5(
                                    uuid.NAMESPACE_URL, f"process-{process_index}"
                                )
                            ),
                            "processID": 4000 + process_index,
                            "processStarted": f"Wed Aug 26 12:00:{process_index:02d} 2026",
                            "seedReadySHA256": assistive.sha256_bytes(b""),
                            "activation": activation,
                        }
                        session_file = assistive.session_path(cell_path, locale)
                        assistive.atomic_write_json(session_file, session)
                        context = {
                            "cell_path": cell_path,
                            "cell": cell,
                            "session": session,
                            "technology": technology,
                            "locale": locale,
                        }
                        last_digest = self.write_all_observations(context)
                        completion = {
                            "schemaVersion": 1,
                            "kind": "assistive-technology-locale-completion",
                            "completedAt": self.timestamp,
                            "runID": manifest["runID"],
                            "proof": proof,
                            "technology": technology,
                            "platform": platform,
                            "locale": locale,
                            "release": self.release,
                            "contractSHA256": self.contract_digest,
                            "candidateReceiptSHA256": manifest[
                                "candidateReceiptSHA256"
                            ],
                            "app": self.app,
                            "cellNonce": cell["cellNonce"],
                            "processNonce": session["processNonce"],
                            "sessionSHA256": assistive.sha256_file(session_file),
                            "lastObservationSHA256": last_digest,
                            "appExited": True,
                        }
                        assistive.atomic_write_json(
                            assistive.completion_path(cell_path, locale), completion
                        )
        finally:
            self.manifest = original_manifest
        return evidence, candidate

    def rewrite_owner_json(self, path, document):
        path.write_text(json.dumps(document))
        os.chmod(path, 0o600)


if __name__ == "__main__":
    unittest.main()
