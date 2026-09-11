import copy
import hashlib
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


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "production_sync_qualification.py"
sys.path.insert(0, str(REPOSITORY / "scripts"))

import production_sync_qualification as MODULE  # noqa: E402


class ProductionSyncQualificationTests(unittest.TestCase):
    def test_exact_checkout_includes_untracked_source(self):
        source = SCRIPT.read_text()
        self.assertIn("--untracked-files=all", source)
        self.assertNotIn("--untracked-files=no", source)

    def test_contract_is_finite_bilingual_and_contiguous(self):
        contract, digest = MODULE.load_contract()

        self.assertEqual(contract["roles"], ["a", "b"])
        self.assertEqual(contract["corpus"]["languages"], ["en", "es"])
        self.assertEqual(len(contract["stages"]), 27)
        self.assertEqual(
            MODULE.stage_catalog(contract)["b.await-push"]["requires"],
            ["b.receive-retry"],
        )
        self.assertEqual(
            MODULE.stage_catalog(contract)["a.push-source"]["requiresLiveStage"],
            "b.await-push",
        )
        self.assertEqual(
            MODULE.stage_catalog(contract)["a.offline-attempt"]["externalAction"],
            "disable-network",
        )
        self.assertRegex(digest, r"^[0-9a-f]{64}$")
        for role, count in (("a", 18), ("b", 9)):
            self.assertEqual(
                sorted(
                    stage["roleSequence"]
                    for stage in contract["stages"]
                    if stage["role"] == role
                ),
                list(range(1, count + 1)),
            )

    def test_initializes_exact_owner_only_manifest_from_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, release = self.make_app(root)
            workspace = root / "workspace"
            arguments = self.namespace(
                app=app,
                workspace=workspace,
                version=release["version"],
                build=release["build"],
                commit=release["commit"],
            )

            with mock.patch.object(MODULE, "require_exact_checkout") as exact:
                MODULE.initialize(arguments)

            exact.assert_called_once_with(release["commit"])
            manifest_path = workspace / "run.json"
            MODULE.require_owner_directory(workspace, "workspace")
            MODULE.require_owner_only(manifest_path, "manifest")
            manifest = MODULE.validate_manifest(
                MODULE.load_json(manifest_path, "manifest")
            )
            self.assertEqual(manifest["release"], release)
            self.assertEqual(
                manifest["executableSHA256"],
                MODULE.sha256_file(app / "Contents" / "MacOS" / "portavoz-app"),
            )
            self.assertEqual(
                manifest["codeResourcesSHA256"],
                MODULE.sha256_file(
                    app / "Contents" / "_CodeSignature" / "CodeResources"
                ),
            )
            self.assertEqual(
                manifest["provisioningProfileSHA256"],
                MODULE.sha256_file(
                    app / "Contents" / "embedded.provisionprofile"
                ),
            )
            self.assertEqual(len(set(self.identities(manifest))), 5)

    def test_stage_rejects_signature_or_profile_drift_before_app_launch(self):
        for relative_path, pattern in (
            (
                Path("Contents/_CodeSignature/CodeResources"),
                "code resources differ",
            ),
            (
                Path("Contents/embedded.provisionprofile"),
                "provisioning profile differs",
            ),
        ):
            with self.subTest(path=relative_path), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app, release = self.make_app(root)
                workspace = root / "workspace"
                with mock.patch.object(MODULE, "require_exact_checkout"):
                    MODULE.initialize(
                        self.namespace(
                            app=app,
                            workspace=workspace,
                            version=release["version"],
                            build=release["build"],
                            commit=release["commit"],
                        )
                    )
                (app / relative_path).write_bytes(b"drifted after manifest")

                with mock.patch("subprocess.run") as process, self.assertRaisesRegex(
                    MODULE.ProductionSyncQualificationError,
                    pattern,
                ):
                    MODULE.run_stage(
                        self.namespace(
                            app=app,
                            workspace=workspace,
                            role="a",
                            stage="prepare-existing",
                            timeout=None,
                        )
                    )
                process.assert_not_called()

    def test_initializer_rejects_contract_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, release = self.make_app(root)
            resource = (
                app
                / "Contents"
                / "Resources"
                / "production-sync-qualification.json"
            )
            document = json.loads(resource.read_text(encoding="utf-8"))
            document["limits"]["maximumPushWakes"] = 9
            resource.write_text(json.dumps(document), encoding="utf-8")

            with self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "contract digest is not the frozen contract",
            ):
                MODULE.initialize(
                    self.namespace(
                        app=app,
                        workspace=root / "workspace",
                        version=release["version"],
                        build=release["build"],
                        commit=release["commit"],
                    )
                )

    def test_initializer_rejects_nonempty_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, release = self.make_app(root)
            workspace = root / "workspace"
            workspace.mkdir()
            (workspace / "private.sqlite").write_bytes(b"do not overwrite")

            with self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "absent or empty",
            ):
                MODULE.initialize(
                    self.namespace(
                        app=app,
                        workspace=workspace,
                        version=release["version"],
                        build=release["build"],
                        commit=release["commit"],
                    )
                )

    def test_stage_workspace_must_be_a_strict_home_or_temp_descendant(self):
        with self.assertRaisesRegex(
            MODULE.ProductionSyncQualificationError,
            "must be below home or the temporary directory",
        ):
            MODULE.require_stage_workspace_location(Path.home().resolve())
        with self.assertRaisesRegex(
            MODULE.ProductionSyncQualificationError,
            "must be below home or the temporary directory",
        ):
            MODULE.require_stage_workspace_location(Path("/Volumes/external-run"))

        MODULE.require_stage_workspace_location(
            Path(tempfile.gettempdir()).resolve() / "portavoz-sync-run"
        )

    def test_stage_directory_tree_is_owner_only_and_rejects_symlink_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / "workspace"
            workspace.mkdir(mode=0o700)

            shell = MODULE.prepare_stage_directories(workspace, "a")

            self.assertEqual(shell, workspace / "app-shell" / "a")
            for path in (
                workspace / "roles",
                workspace / "roles" / "a",
                workspace / "receipts",
                workspace / "receipts" / "a",
                workspace / "receipts" / "b",
                workspace / "live",
                workspace / "app-shell",
                workspace / "app-shell" / "a",
            ):
                MODULE.require_owner_directory(path, str(path))

            outside = root / "outside"
            outside.mkdir(mode=0o700)
            roles = workspace / "roles"
            (roles / "a").rmdir()
            roles.rmdir()
            roles.symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "must not be a symbolic link",
            ):
                MODULE.prepare_stage_directories(workspace, "a")

    def test_contract_rejects_duplicate_and_orphaned_stages(self):
        contract, _ = MODULE.load_contract()
        duplicate = copy.deepcopy(contract)
        duplicate["stages"].append(copy.deepcopy(duplicate["stages"][0]))
        with self.assertRaises(MODULE.ProductionSyncQualificationError):
            MODULE.validate_contract(duplicate)

        orphaned = copy.deepcopy(contract)
        orphaned["stages"][0]["requires"] = ["b.unknown"]
        with self.assertRaises(MODULE.ProductionSyncQualificationError):
            MODULE.validate_contract(orphaned)

        repeated = copy.deepcopy(contract)
        repeated["stages"][1]["requires"] *= 2
        with self.assertRaisesRegex(
            MODULE.ProductionSyncQualificationError,
            "repeats a requirement",
        ):
            MODULE.validate_contract(repeated)

        cyclic = copy.deepcopy(contract)
        cyclic["stages"][0]["requires"] = ["a.enable"]
        with self.assertRaisesRegex(
            MODULE.ProductionSyncQualificationError,
            "cyclic",
        ):
            MODULE.validate_contract(cyclic)

    def test_stage_refuses_to_launch_before_required_receipt_exists(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, release = self.make_app(root)
            workspace = root / "workspace"
            with mock.patch.object(MODULE, "require_exact_checkout"):
                MODULE.initialize(
                    self.namespace(
                        app=app,
                        workspace=workspace,
                        version=release["version"],
                        build=release["build"],
                        commit=release["commit"],
                    )
                )

            with mock.patch("subprocess.run") as process, self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "requires completed receipt a.prepare-existing",
            ):
                MODULE.run_stage(
                    self.namespace(
                        app=app,
                        workspace=workspace,
                        role="a",
                        stage="enable",
                        timeout=None,
                    )
                )
            process.assert_not_called()

    def test_external_actions_require_exact_confirmation_without_becoming_proof(self):
        contract, _ = MODULE.load_contract()
        catalog = MODULE.stage_catalog(contract)

        with self.assertRaisesRegex(
            MODULE.ProductionSyncQualificationError,
            "requires --confirm-external-action disable-network",
        ):
            MODULE.validate_external_action(
                "a.offline-attempt",
                catalog["a.offline-attempt"],
                None,
            )
        MODULE.validate_external_action(
            "a.offline-attempt",
            catalog["a.offline-attempt"],
            "disable-network",
        )
        with self.assertRaisesRegex(
            MODULE.ProductionSyncQualificationError,
            "accepts no external-action confirmation",
        ):
            MODULE.validate_external_action(
                "a.enable",
                catalog["a.enable"],
                "disable-network",
            )

    def test_stage_environment_drops_every_inherited_portavoz_override(self):
        database = Path("/private/tmp/workspace/app-shell/a/exact.sqlite")
        with mock.patch.dict(
            os.environ,
            {
                "PATH": "/usr/bin:/bin",
                "PORTAVOZ_RESET_APP_LANGUAGE": "1",
                "PORTAVOZ_AUDIO_ROOT": "/private/library",
                "PORTAVOZ_UI_TEST_DATABASE_PATH": "/private/other.sqlite",
            },
            clear=True,
        ):
            environment = MODULE.qualification_environment(database)

        self.assertEqual(environment["PATH"], "/usr/bin:/bin")
        self.assertEqual(
            environment["PORTAVOZ_UI_TEST_DATABASE_PATH"],
            str(database),
        )
        self.assertEqual(
            {key for key in environment if key.startswith("PORTAVOZ_")},
            {"PORTAVOZ_UI_TEST_DATABASE_PATH"},
        )

    def test_stage_reservation_prevents_duplicate_processes_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            reservation = workspace / ".production-sync-a-enable.lock"
            reservation.write_text("content-free reservation")
            with self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "stage a.enable is already running",
            ), MODULE.reserve_stage(workspace, "a", "enable"):
                self.fail("an existing reservation must prevent entry")

            reservation.unlink()
            with self.assertRaisesRegex(RuntimeError, "simulated crash"):
                with MODULE.reserve_stage(workspace, "a", "enable"):
                    self.assertTrue(reservation.exists())
                    self.assertEqual(
                        stat.S_IMODE(reservation.stat().st_mode),
                        0o600,
                    )
                    raise RuntimeError("simulated crash")
            self.assertFalse(reservation.exists())

    def test_complete_real_app_receipt_matrix_finalizes_admission(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, manifest, _, _ = self.make_evidence(root)
            output = root / "output"

            with mock.patch.object(MODULE, "require_exact_checkout") as exact:
                MODULE.finalize(
                    self.namespace(evidence_root=evidence, output=output)
                )

            exact.assert_called_once_with(manifest["release"]["commit"])
            qualification = MODULE.load_json(
                output / "qualification.json", "qualification"
            )
            _, release, scope, proofs = (
                MODULE.release_reliability.validate_qualification_receipt(
                    qualification,
                    "qualification",
                )
            )
            self.assertEqual(release, manifest["release"])
            self.assertEqual(scope, "production-sync")
            self.assertEqual(proofs, {"admission": "pass"})
            authority = MODULE.load_json(output / "authority.json", "authority")
            self.assertEqual(
                qualification["authoritySHA256"],
                MODULE.release_reliability.canonical_document_sha256(authority),
            )
            self.assertEqual(len(authority["stages"]), 27)
            self.assertEqual(len(set(authority["hostScopes"])), 2)
            self.assertNotEqual(
                authority["accountScopes"]["original"],
                authority["accountScopes"]["switched"],
            )
            live_marker_digest = MODULE.sha256_file(
                MODULE.live_stage_marker_path(evidence, "b.await-push")
            )
            self.assertEqual(
                authority["liveStageMarkerSHA256"],
                live_marker_digest,
            )
            self.assertRegex(live_marker_digest, r"^[0-9a-f]{64}$")
            MODULE.require_owner_only(output / "qualification.json", "qualification")
            MODULE.require_owner_only(output / "authority.json", "authority")

    def test_missing_stage_cannot_finalize(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence, _, contract, _ = self.make_evidence(Path(directory))
            stage = MODULE.stage_catalog(contract)["b.await-push"]
            MODULE.receipt_path(
                evidence, "b", stage["roleSequence"], "await-push"
            ).unlink()

            with mock.patch.object(MODULE, "require_exact_checkout"), self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "missing stage receipt",
            ):
                MODULE.finalize(
                    self.namespace(
                        evidence_root=evidence,
                        output=evidence.parent / "output",
                    )
                )

    def test_missing_live_push_marker_cannot_finalize(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, _, _, _ = self.make_evidence(root)
            MODULE.live_stage_marker_path(evidence, "b.await-push").unlink()

            with mock.patch.object(MODULE, "require_exact_checkout"), self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "live-stage marker b.await-push must be a regular file",
            ):
                MODULE.finalize(
                    self.namespace(
                        evidence_root=evidence,
                        output=root / "output",
                    )
                )

    def test_push_receipt_must_bind_the_live_waiting_process(self):
        self.assert_finalizer_mutation_fails(
            lambda receipts: receipts["a.push-source"].update(
                {"liveStageMarkerSHA256": "f" * 64}
            ),
            "push-source did not consume the live await-push marker",
        )

    def test_same_host_scope_for_both_roles_cannot_finalize(self):
        self.assert_finalizer_mutation_fails(
            lambda receipts: [
                receipt.update({"hostScopeSHA256": "a" * 64})
                for receipt in receipts.values()
            ],
            "two distinct Mac host scopes",
        )

    def test_same_account_cannot_satisfy_account_switch(self):
        def mutate(receipts):
            original = receipts["a.enable"]["accountScopeSHA256"]
            for key in (
                "a.observe-account-switch",
                "a.enable-switched-account",
            ):
                receipts[key]["accountScopeSHA256"] = original

        self.assert_finalizer_mutation_fails(mutate, "another account")

    def test_inconsistent_switched_account_cannot_finalize(self):
        self.assert_finalizer_mutation_fails(
            lambda receipts: receipts["a.enable-switched-account"].update(
                {"accountScopeSHA256": "e" * 64}
            ),
            "switched iCloud account scope is inconsistent",
        )

    def test_role_cannot_change_operating_system_mid_run(self):
        self.assert_finalizer_mutation_fails(
            lambda receipts: receipts["b.pause"]["os"].update(
                {"build": "25A363"}
            ),
            "role b changed operating system",
        )

    def test_same_os_generation_on_both_roles_cannot_finalize(self):
        def mutate(receipts):
            for receipt in receipts.values():
                receipt["os"].update(
                    {
                        "major": 26,
                        "minor": 0,
                        "patch": 1,
                        "build": "25A362",
                    }
                )

        self.assert_finalizer_mutation_fails(
            mutate,
            "must pair Sequoia with Tahoe or newer",
        )

    def test_unsupported_macos_major_cannot_finalize(self):
        self.assert_finalizer_mutation_fails(
            lambda receipts: receipts["a.enable"]["os"].update(
                {"major": 25}
            ),
            "not Sequoia, Tahoe, or newer",
        )

    def test_broken_predecessor_chain_cannot_finalize(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, _, contract, receipts = self.make_evidence(root)
            descriptor = MODULE.stage_catalog(contract)["a.edit-a"]
            path = MODULE.receipt_path(
                evidence,
                "a",
                descriptor["roleSequence"],
                descriptor["id"],
            )
            receipts["a.edit-a"]["predecessorSHA256"] = "f" * 64
            MODULE.atomic_write_json(path, receipts["a.edit-a"])

            with mock.patch.object(MODULE, "require_exact_checkout"), self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "stage chain breaks",
            ):
                MODULE.finalize(
                    self.namespace(
                        evidence_root=evidence,
                        output=root / "output",
                    )
                )

    def test_reused_process_cannot_claim_relaunch(self):
        def mutate(receipts):
            receipts["a.retry-relaunch"]["processNonce"] = receipts[
                "a.offline-attempt"
            ]["processNonce"]

        self.assert_finalizer_mutation_fails(
            mutate,
            "distinct app process",
        )

    def test_content_bearing_receipt_is_rejected(self):
        self.assert_finalizer_mutation_fails(
            lambda receipts: receipts["b.receive-existing"].update(
                {"transcript": "private words"}
            ),
            "forbidden content key transcript",
        )

    def test_receipt_with_unknown_field_is_rejected(self):
        self.assert_finalizer_mutation_fails(
            lambda receipts: receipts["b.receive-existing"].update(
                {"unexpected": True}
            ),
            "invalid shape",
        )

    def test_wrong_corpus_state_is_rejected(self):
        self.assert_finalizer_mutation_fails(
            lambda receipts: receipts["b.receive-existing"]["corpus"].update(
                {"state": "editA"}
            ),
            "wrong corpus state",
        )

    def test_green_offline_attempt_is_rejected(self):
        def mutate(receipts):
            lifecycle = receipts["a.offline-attempt"]["lifecycle"]
            lifecycle.update(
                {
                    "phase": "synchronized",
                    "pendingLocalChanges": 0,
                    "queuedTransfers": 0,
                }
            )

        self.assert_finalizer_mutation_fails(
            mutate,
            "offline attempt did not fail or retry",
        )

    def test_silent_push_requires_a_real_wake(self):
        self.assert_finalizer_mutation_fails(
            lambda receipts: receipts["b.await-push"].update(
                {"pushWakes": 0}
            ),
            "lacks an APNs wake",
        )

    def test_unexpected_receipt_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence, _, _, _ = self.make_evidence(Path(directory))
            extra = evidence / "receipts" / "a" / "99-forged.json"
            MODULE.atomic_write_json(extra, {"schemaVersion": 1})

            with mock.patch.object(MODULE, "require_exact_checkout"), self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "unexpected stage receipts",
            ):
                MODULE.finalize(
                    self.namespace(
                        evidence_root=evidence,
                        output=evidence.parent / "output",
                    )
                )

    def test_unexpected_empty_evidence_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, _, _, _ = self.make_evidence(root)
            (evidence / "unclaimed").mkdir(mode=0o700)

            with mock.patch.object(MODULE, "require_exact_checkout"), self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "unexpected files",
            ):
                MODULE.finalize(
                    self.namespace(
                        evidence_root=evidence,
                        output=root / "output",
                    )
                )

    def test_non_owner_receipt_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence, _, contract, _ = self.make_evidence(Path(directory))
            stage = MODULE.stage_catalog(contract)["a.edit-a"]
            path = MODULE.receipt_path(
                evidence, "a", stage["roleSequence"], "edit-a"
            )
            path.chmod(0o644)

            with mock.patch.object(MODULE, "require_exact_checkout"), self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "mode 0600",
            ):
                MODULE.finalize(
                    self.namespace(
                        evidence_root=evidence,
                        output=evidence.parent / "output",
                    )
                )

    def test_non_owner_evidence_root_is_rejected_before_finalization(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, _, _, _ = self.make_evidence(root)
            evidence.chmod(0o755)

            with self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "evidence root must have mode 0700",
            ):
                MODULE.finalize(
                    self.namespace(
                        evidence_root=evidence,
                        output=root / "output",
                    )
                )

    def test_status_lists_every_missing_stage_without_minting_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contract, digest = MODULE.load_contract()
            manifest = self.manifest(digest, contract)
            MODULE.atomic_write_json(root / "run.json", manifest)

            with mock.patch("builtins.print") as output:
                MODULE.status(self.namespace(evidence_root=root))

            self.assertEqual(output.call_count, len(contract["stages"]))
            self.assertTrue(
                all(call.args[0].startswith("MISSING") for call in output.call_args_list)
            )
            self.assertFalse((root / "qualification.json").exists())

    def test_status_rejects_an_existing_malformed_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, _, contract, _ = self.make_evidence(root)
            descriptor = MODULE.stage_catalog(contract)["a.enable"]
            path = MODULE.receipt_path(
                evidence,
                "a",
                descriptor["roleSequence"],
                descriptor["id"],
            )
            document = MODULE.load_json(path, "receipt")
            document["stage"] = "forged"
            MODULE.atomic_write_json(path, document)

            with mock.patch("builtins.print") as output, self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "invalid stage receipts: a.enable",
            ):
                MODULE.status(self.namespace(evidence_root=evidence))

            markers = [call.args[0] for call in output.call_args_list]
            self.assertIn("INVALID a.enable", markers)

    def test_finalizer_publishes_both_files_or_neither(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, _, _, _ = self.make_evidence(root)
            output = root / "output"
            original_write = MODULE.atomic_write_json

            def fail_second(path, document):
                if path.name == "qualification.json":
                    raise OSError("simulated publication failure")
                original_write(path, document)

            with mock.patch.object(MODULE, "require_exact_checkout"), mock.patch.object(
                MODULE,
                "atomic_write_json",
                side_effect=fail_second,
            ), self.assertRaisesRegex(OSError, "simulated publication failure"):
                MODULE.finalize(
                    self.namespace(evidence_root=evidence, output=output)
                )

            self.assertFalse(output.exists())
            self.assertEqual(list(root.glob(".output.*")), [])

    def test_finalizer_rejects_existing_or_concurrently_reserved_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, _, _, _ = self.make_evidence(root)
            output = root / "output"
            output.mkdir()

            with mock.patch.object(MODULE, "require_exact_checkout"), self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "output must be absent",
            ):
                MODULE.finalize(
                    self.namespace(evidence_root=evidence, output=output)
                )

            output.rmdir()
            lock = root / ".output.publish.lock"
            lock.write_text("content-free reservation")
            with mock.patch.object(MODULE, "require_exact_checkout"), self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "publication is already in progress",
            ):
                MODULE.finalize(
                    self.namespace(evidence_root=evidence, output=output)
                )
            self.assertFalse(output.exists())
            self.assertTrue(lock.exists())

    def test_finalizer_cannot_publish_inside_its_evidence_root(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence, _, _, _ = self.make_evidence(Path(directory))

            with self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                "output must be outside the evidence root",
            ):
                MODULE.finalize(
                    self.namespace(
                        evidence_root=evidence,
                        output=evidence / "authority",
                    )
                )

    def assert_finalizer_mutation_fails(self, mutate, pattern):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence, _, contract, receipts = self.make_evidence(root)
            mutate(receipts)
            self.rewrite_receipts(evidence, contract, receipts)

            with mock.patch.object(MODULE, "require_exact_checkout"), self.assertRaisesRegex(
                MODULE.ProductionSyncQualificationError,
                pattern,
            ):
                MODULE.finalize(
                    self.namespace(
                        evidence_root=evidence,
                        output=root / "output",
                    )
                )

    def make_evidence(self, root):
        evidence = root / "evidence"
        evidence.mkdir(mode=0o700)
        contract, digest = MODULE.load_contract()
        manifest = self.manifest(digest, contract)
        MODULE.atomic_write_json(evidence / "run.json", manifest)
        receipts = {
            f"{stage['role']}.{stage['id']}": self.receipt(
                manifest,
                stage,
            )
            for stage in contract["stages"]
        }
        marker = self.live_stage_marker(manifest, receipts["b.await-push"])
        marker_path = MODULE.live_stage_marker_path(evidence, "b.await-push")
        MODULE.atomic_write_json(marker_path, marker)
        marker_digest = MODULE.sha256_file(marker_path)
        receipts["a.push-source"]["liveStageMarkerSHA256"] = marker_digest
        receipts["b.await-push"]["liveStageMarkerSHA256"] = marker_digest
        self.rewrite_receipts(evidence, contract, receipts)
        return evidence, manifest, contract, receipts

    def rewrite_receipts(self, evidence, contract, receipts):
        receipts_root = evidence / "receipts"
        if receipts_root.exists():
            for path in receipts_root.glob("*/*.json"):
                path.unlink()
        for role in contract["roles"]:
            predecessor = None
            role_stages = sorted(
                (stage for stage in contract["stages"] if stage["role"] == role),
                key=lambda stage: stage["roleSequence"],
            )
            for stage in role_stages:
                key = f"{role}.{stage['id']}"
                receipt = receipts[key]
                receipt["predecessorSHA256"] = predecessor
                path = MODULE.receipt_path(
                    evidence,
                    role,
                    stage["roleSequence"],
                    stage["id"],
                )
                MODULE.atomic_write_json(path, receipt)
                predecessor = MODULE.sha256_file(path)

    def receipt(self, manifest, stage):
        key = f"{stage['role']}.{stage['id']}"
        state = MODULE.EXPECTED_CORPUS_STATE[key]
        if state == "absent":
            live, deleted = 0, 0
        elif state == "deleted":
            live, deleted = 0, 1
        else:
            live, deleted = 1, 0
        if key == "a.prepare-existing":
            lifecycle = self.lifecycle("localOnly", "unknown", False, "blocked")
            account = None
        elif key == "a.offline-prepare":
            lifecycle = self.lifecycle(
                "pending", "available", True, "complete", pending=1
            )
            account = "1" * 64
        elif key == "a.offline-attempt":
            lifecycle = self.lifecycle(
                "failed", "available", True, "complete", pending=1, queued=1
            )
            account = "1" * 64
        elif key == "a.observe-signout":
            lifecycle = self.lifecycle("paused", "signedOut", True, "blocked")
            account = "1" * 64
        elif key in {"a.observe-account-switch", "a.observe-account-restore"}:
            lifecycle = self.lifecycle("localOnly", "available", False, "blocked")
            account = "2" * 64 if key.endswith("switch") else "1" * 64
        elif key in {"a.pause", "b.pause"}:
            lifecycle = self.lifecycle("localOnly", "available", False, "blocked")
            account = "1" * 64
        elif key in {"a.remove-device", "b.remove-device"}:
            lifecycle = self.lifecycle("localOnly", "unknown", False, "blocked")
            account = "1" * 64
        else:
            initial = "notRequested"
            if stage["role"] == "a" and key not in {
                "a.enable",
                "a.enable-switched-account",
                "a.enable-restored-account",
            }:
                initial = "complete"
            lifecycle = self.lifecycle(
                "synchronized", "available", True, initial
            )
            account = (
                "2" * 64
                if key == "a.enable-switched-account"
                else "1" * 64
            )
        return {
            "schemaVersion": 1,
            "kind": "production-sync-stage",
            "collectedAt": "2026-08-25T12:00:00Z",
            "runID": manifest["runID"],
            "contractSHA256": manifest["contractSHA256"],
            "release": manifest["release"],
            "executableSHA256": manifest["executableSHA256"],
            "codeResourcesSHA256": manifest["codeResourcesSHA256"],
            "provisioningProfileSHA256": manifest["provisioningProfileSHA256"],
            "role": stage["role"],
            "stage": stage["id"],
            "roleSequence": stage["roleSequence"],
            "processNonce": str(uuid.uuid4()),
            "hostScopeSHA256": "a" * 64 if stage["role"] == "a" else "b" * 64,
            "accountScopeSHA256": account,
            "predecessorSHA256": None,
            "liveStageMarkerSHA256": None,
            "corpus": {
                "sha256": manifest["corpus"]["sha256"],
                "state": state,
                "liveMeetings": live,
                "deletedMeetings": deleted,
            },
            "lifecycle": lifecycle,
            "pushWakes": 1 if key == "b.await-push" else 0,
            "os": {
                "major": 15 if stage["role"] == "a" else 26,
                "minor": 7 if stage["role"] == "a" else 0,
                "patch": 1,
                "build": "24G90" if stage["role"] == "a" else "25A362",
                "architecture": "arm64",
            },
        }

    @staticmethod
    def live_stage_marker(manifest, waiter):
        return {
            "schemaVersion": 1,
            "kind": "production-sync-live-stage",
            "collectedAt": "2026-08-25T11:59:59Z",
            "runID": manifest["runID"],
            "contractSHA256": manifest["contractSHA256"],
            "release": manifest["release"],
            "executableSHA256": manifest["executableSHA256"],
            "codeResourcesSHA256": manifest["codeResourcesSHA256"],
            "provisioningProfileSHA256": manifest["provisioningProfileSHA256"],
            "role": "b",
            "stage": "await-push",
            "processNonce": waiter["processNonce"],
            "hostScopeSHA256": waiter["hostScopeSHA256"],
        }

    @staticmethod
    def lifecycle(
        phase,
        account_status,
        enabled,
        seed,
        *,
        pending=0,
        queued=0,
        retrying=0,
        failed=0,
    ):
        return {
            "phase": phase,
            "accountStatus": account_status,
            "isEnabled": enabled,
            "initialSeedState": seed,
            "pendingLocalChanges": pending,
            "queuedTransfers": queued,
            "retryingTransfers": retrying,
            "failedTransfers": failed,
        }

    @staticmethod
    def manifest(digest, contract):
        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=REPOSITORY,
            capture_output=True,
            check=True,
            text=True,
        ).stdout.strip()
        return {
            "schemaVersion": 1,
            "kind": "production-sync-qualification-run",
            "runID": str(uuid.uuid4()),
            "createdAt": "2026-08-25T12:00:00Z",
            "release": {
                "version": "1.0.0",
                "build": "202608250001",
                "commit": commit,
            },
            "contractSHA256": digest,
            "executableSHA256": "3" * 64,
            "codeResourcesSHA256": "5" * 64,
            "provisioningProfileSHA256": "6" * 64,
            "runNonce": "4" * 64,
            "corpus": {
                "sha256": contract["corpus"]["sha256"],
                "meetingID": str(uuid.uuid4()),
                "speakerIDs": [str(uuid.uuid4()), str(uuid.uuid4())],
                "segmentIDs": [str(uuid.uuid4()), str(uuid.uuid4())],
            },
        }

    @staticmethod
    def make_app(root):
        app = (root / "Portavoz Sync Qualification.app").resolve()
        resources = app / "Contents" / "Resources"
        executable_directory = app / "Contents" / "MacOS"
        resources.mkdir(parents=True)
        executable_directory.mkdir()
        executable = executable_directory / "portavoz-app"
        executable.write_bytes(b"exact qualification executable")
        executable.chmod(0o755)
        code_resources = app / "Contents" / "_CodeSignature" / "CodeResources"
        code_resources.parent.mkdir()
        code_resources.write_bytes(b"exact sealed resources")
        (app / "Contents" / "embedded.provisionprofile").write_bytes(
            b"exact production profile"
        )
        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=REPOSITORY,
            capture_output=True,
            check=True,
            text=True,
        ).stdout.strip()
        release = {
            "version": "1.0.0",
            "build": "202608250001",
            "commit": commit,
        }
        with (app / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "app.portavoz.mac",
                    "CFBundleDisplayName": "Portavoz Sync Qualification",
                    "CFBundleName": "Portavoz Sync Qualification",
                    "CFBundleExecutable": "portavoz-app",
                    "CFBundleShortVersionString": release["version"],
                    "CFBundleVersion": release["build"],
                    "PortavozSourceCommit": release["commit"],
                },
                handle,
            )
        (
            resources / "production-sync-qualification.json"
        ).write_bytes(MODULE.DEFAULT_CONTRACT.read_bytes())
        return app, release

    @staticmethod
    def identities(manifest):
        return [
            manifest["corpus"]["meetingID"],
            *manifest["corpus"]["speakerIDs"],
            *manifest["corpus"]["segmentIDs"],
        ]

    @staticmethod
    def namespace(**values):
        return type("Arguments", (), values)()


if __name__ == "__main__":
    unittest.main()
