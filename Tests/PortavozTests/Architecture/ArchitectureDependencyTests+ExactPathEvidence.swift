import ApplicationKit
import Foundation
import XCTest

extension ArchitectureDependencyTests {
    func testFirstSemanticResearchEngineSourceRemainsPinnedAndStatic() throws {
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let vendor = try Self.contents(of: "scripts/vendor-sqlite-vec.sh")
        let license = try Self.contents(
            of: "scripts/vendor-metadata/sqlite-vec/LICENSE-MIT")

        XCTAssertTrue(decisions.contains("## D211"))
        XCTAssertTrue(architecture.contains("sqlite-vec v0.1.9 exact full-scan"))
        XCTAssertTrue(architecture.contains("`Vendor/sqlite-vec` now retains"))
        for required in [
            #"readonly VERSION="0.1.9""#,
            #"readonly ARCHIVE_NAME="sqlite-vec-${VERSION}-amalgamation.zip""#,
            #"readonly ARCHIVE_SHA256="b87cdda12112657ba5ab8842f0088a4090982eaf41f22b2bd6d495b81765a8c9""#,
            #"readonly C_SHA256="ba081a47fa02eadc3cf6b16c314b695b84081269349aac722b4efa338fe8fd85""#,
            #"readonly HEADER_SHA256="4f022d5ff3f97e521c7aef473a6991a7819a4d226be4267d3ee03138904d9968""#,
            #"readonly LICENSE_SHA256="e49d7859a0fd8d3f8a2a7b81ca1dbddf61bd4f9e981d12908ead721a78c42f32""#,
            #"actual_sha256="$(shasum -a 256 "$verified_archive""#,
            #"actual_license_sha256="$(shasum -a 256 "$license_source""#,
            "find_exactly_one sqlite-vec.c",
            "find_exactly_one sqlite-vec.h",
            #"[[ ! -e "$destination" ]]"#,
            "Dynamic extension loading is forbidden."
        ] {
            XCTAssertTrue(vendor.contains(required), "missing \(required)")
        }
        for forbidden in [
            "enable_load_extension", "sqlite3_load_extension", "dlopen(", ".load "
        ] {
            XCTAssertFalse(
                vendor.contains(forbidden),
                "dynamic loading leaked: \(forbidden)")
        }
        XCTAssertTrue(license.contains("MIT License"))
        XCTAssertTrue(license.contains("Copyright (c) 2024 Alex Garcia"))

        XCTAssertFalse(vendor.contains("sqlite3_load_extension"))
        XCTAssertFalse(vendor.contains("dlopen("))
        XCTAssertFalse(vendor.contains("enable_load_extension"))
    }

    func testFirstSemanticResearchEngineCompilesOnlyForIsolatedTests() throws {
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let provenance = try Self.contents(of: "Vendor/sqlite-vec/PROVENANCE.md")
        let attributes = try Self.contents(of: ".gitattributes")
        let wrapper = try Self.contents(
            of: "Sources/CSQLiteVecResearch/SQLiteVecResearch.c")
        let targets = try TargetManifestParser.declarations(
            in: Self.contents(of: "Package.swift"))

        XCTAssertTrue(decisions.contains("## D212"))
        XCTAssertTrue(architecture.contains("CSQLiteVecResearch"))
        XCTAssertNotNil(targets["CSQLiteVecResearch"])
        XCTAssertTrue(try XCTUnwrap(targets["PortavozTests"]).dependencies.contains(
            "CSQLiteVecResearch"))
        for productTarget in ["portavoz-app", "portavoz-cli"] {
            XCTAssertFalse(try XCTUnwrap(targets[productTarget]).dependencies.contains(
                "CSQLiteVecResearch"))
        }

        for required in [
            "de3176f9ca28a273c5086f1cc995ebf4e3c04c22",
            "ba081a47fa02eadc3cf6b16c314b695b84081269349aac722b4efa338fe8fd85",
            "f49f62f6552b45ac612d236af96979aaba5bac8c",
            "4f022d5ff3f97e521c7aef473a6991a7819a4d226be4267d3ee03138904d9968",
            "test target",
        ] {
            XCTAssertTrue(provenance.contains(required), "missing \(required)")
        }
        XCTAssertTrue(attributes.contains(
            "Vendor/sqlite-vec/sqlite-vec.c -text linguist-vendored=true"))
        XCTAssertTrue(attributes.contains(
            "Vendor/sqlite-vec/sqlite-vec.h -text linguist-vendored=true"))
        for required in [
            "#define SQLITE_CORE 1",
            "#define SQLITE_VEC_STATIC 1",
            "#define SQLITE_VEC_OMIT_FS 1",
            #"#include "../../Vendor/sqlite-vec/sqlite-vec.c""#,
            "portavoz_sqlite_vec_run_exact_query_smoke",
            "vec_distance_cosine(embedding, ?1) AS distance",
            "ORDER BY distance, rowid LIMIT ?2",
        ] {
            XCTAssertTrue(wrapper.contains(required), "missing \(required)")
        }

        let productMatches = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"CSQLiteVecResearch|sqlite3_vec_init|USING\s+vec0"#)
        XCTAssertEqual(productMatches, [])
    }

    func testFirstSemanticResearchRankerRemainsDisposableShadowOnly() throws {
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let ranker = try Self.contents(
            of: "Sources/SQLiteVecResearchKit/SQLiteVecExactShadowRanker.swift")
        let native = try Self.contents(
            of: "Sources/CSQLiteVecResearch/SQLiteVecResearch.c")
        let semanticTests = try Self.contents(
            of: "Tests/PortavozTests/SemanticIndexTests.swift")
        let targets = try TargetManifestParser.declarations(
            in: Self.contents(of: "Package.swift"))

        XCTAssertTrue(decisions.contains("## D213"))
        XCTAssertTrue(architecture.contains("SQLiteVecExactShadowRanker"))
        XCTAssertTrue(try XCTUnwrap(targets["SQLiteVecResearchKit"]).dependencies.contains(
            "CSQLiteVecResearch"))
        XCTAssertFalse(try XCTUnwrap(targets["SQLiteVecResearchKit"]).dependencies.contains(
            "ApplicationKit"))
        XCTAssertTrue(try XCTUnwrap(targets["PortavozTests"]).dependencies.contains(
            "SQLiteVecResearchKit"))
        for productTarget in ["portavoz-app", "portavoz-cli", "ApplicationKit"] {
            let dependencies = try XCTUnwrap(targets[productTarget]).dependencies
            XCTAssertFalse(dependencies.contains("SQLiteVecResearchKit"))
            XCTAssertFalse(dependencies.contains("CSQLiteVecResearch"))
        }

        for required in [
            "public actor SQLiteVecExactShadowRanker",
            "entry.identity.transcriptRevision >= 0",
            "segmentIDs.insert(entry.identity.segmentID).inserted",
            "query.allSatisfy(\\.isFinite)",
            "withTaskCancellationHandler",
            "cancellation.cancel()",
        ] {
            XCTAssertTrue(ranker.contains(required), "missing \(required)")
        }
        for required in [
            "distance_metric=cosine",
            "vec_distance_cosine(embedding, ?1) AS distance",
            "ORDER BY distance, rowid LIMIT ?2",
            "index->live_count",
            "sqlite3_bind_int(statement, 2, requested)",
            "sqlite3_progress_handler",
        ] {
            XCTAssertTrue(native.contains(required), "missing \(required)")
        }
        XCTAssertTrue(semanticTests.contains(
            "testSQLiteVecRankerRunsBehindProjectionAndAggregateShadowOnly"))
        XCTAssertTrue(semanticTests.contains(
            "testSQLiteVecExactRankerSupportsCorporaBeyondKNNWindow"))
        XCTAssertTrue(semanticTests.contains(
            "ProjectedSemanticIndexShadowCandidate"))
        XCTAssertTrue(semanticTests.contains("ShadowComparingSemanticIndex"))
        XCTAssertTrue(semanticTests.contains(
            "SQLiteVecShadowRankerAdapter: SemanticIndexShadowRanking"))
    }

    func testExactPathScaleHarnessRemainsIsolatedContentFreeAndReproducible() throws {
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let specification = try Self.contents(of: "docs/specs/04-intelligence.md")
        let harness = try Self.contents(
            of: "Tests/PortavozTests/ExactPathScaleBenchmarkTests.swift")
        let runner = try Self.contents(
            of: "scripts/run-exact-path-shadow-benchmark.sh")

        XCTAssertTrue(decisions.contains("## D214"))
        XCTAssertTrue(architecture.contains("synthetic-exact-path-v1"))
        XCTAssertTrue(specification.contains("alternating-query-order-v1"))
        for required in [
            "static let canonicalCorpusSizes = [1_000, 10_000, 50_000, 100_000]",
            "dimension: 512",
            "queryCount: 8",
            "resultLimit: 10",
            "AccelerateExactSemanticIndex",
            "SQLiteVecExactShadowRanker",
            "fixturePreparationMilliseconds",
            "buildMilliseconds",
            "queryWallMilliseconds",
            "topHitMatchCount",
            "exactRankMatchCount",
            "overlapAtKCount",
        ] {
            XCTAssertTrue(harness.contains(required), "missing \(required)")
        }

        let reportStart = try XCTUnwrap(harness.range(
            of: "private struct ExactPathScaleBenchmarkReport"))
        let reportEnd = try XCTUnwrap(harness.range(
            of: "private struct MillisecondDistribution",
            range: reportStart.upperBound..<harness.endIndex))
        let reportSchema = String(
            harness[reportStart.lowerBound..<reportEnd.lowerBound])
        for forbidden in [
            "segmentID", "meetingID", "transcript", "queryVector",
            "modelIdentifier", "databasePath", "filePath", "rawError",
        ] {
            XCTAssertFalse(
                reportSchema.contains(forbidden),
                "report schema leaked \(forbidden)")
        }

        for required in [
            "swift test -c release",
            "1000 10000 50000 100000",
            "PORTAVOZ_EXACT_PATH_REPORT",
            "Each corpus size gets a fresh XCTest process.",
            "does not persist benchmark results",
        ] {
            XCTAssertTrue(runner.contains(required), "missing \(required)")
        }
        XCTAssertFalse(runner.contains("--output"))
    }

    func testExactPathMutationHarnessRemainsAtomicContentFreeAndTestOnly() throws {
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let specification = try Self.contents(of: "docs/specs/04-intelligence.md")
        let harness = try Self.contents(
            of: "Tests/PortavozTests/ExactPathMutationBenchmarkTests.swift")
        let runner = try Self.contents(
            of: "scripts/run-exact-path-mutation-benchmark.sh")
        let ranker = try Self.contents(
            of: "Sources/SQLiteVecResearchKit/SQLiteVecExactShadowRanker.swift")
        let native = try Self.contents(
            of: "Sources/CSQLiteVecResearch/SQLiteVecResearch.c")
        let targets = try TargetManifestParser.declarations(
            in: Self.contents(of: "Package.swift"))

        XCTAssertTrue(decisions.contains("## D218"))
        XCTAssertTrue(architecture.contains("synthetic-exact-path-mutation-v1"))
        XCTAssertTrue(specification.contains("alternating-mutation-engine-order-v1"))
        for required in [
            "static let canonicalBatchSizes = [1, 10, 100]",
            "fullRebuildMilliseconds",
            "mutationLifecycle",
            "control-authoritative-source-publication-vs-candidate-prepared-vectors-v1",
            "case add",
            "case update",
            "case delete",
            "AccelerateExactSemanticIndex",
            "SQLiteVecExactShadowRanker",
            "topKSetMatchCount",
        ] {
            XCTAssertTrue(harness.contains(required), "missing \(required)")
        }
        for required in [
            "BEGIN IMMEDIATE",
            "ROLLBACK",
            "index->slot_count += append_count",
            "index->live_count += append_count - delete_count",
        ] {
            XCTAssertTrue(native.contains(required), "missing \(required)")
        }
        for required in [
            "public struct SQLiteVecShadowMutation",
            "deleted slots are never reused",
            "Swift state changes only after the native transaction",
        ] {
            XCTAssertTrue(ranker.contains(required), "missing \(required)")
        }

        let reportStart = try XCTUnwrap(harness.range(
            of: "private struct ExactPathMutationReport"))
        let reportEnd = try XCTUnwrap(harness.range(
            of: "private struct MutationMillisecondDistribution",
            range: reportStart.upperBound..<harness.endIndex))
        let reportSchema = String(
            harness[reportStart.lowerBound..<reportEnd.lowerBound])
        for forbidden in [
            "segmentID", "meetingID", "transcript", "queryVector",
            "modelIdentifier", "databasePath", "filePath", "rawError",
        ] {
            XCTAssertFalse(
                reportSchema.contains(forbidden),
                "report schema leaked \(forbidden)")
        }

        for required in [
            "swift test -c release",
            "1000 10000 50000 100000",
            "PORTAVOZ_EXACT_PATH_MUTATION_REPORT",
            "Each corpus size gets a fresh XCTest process.",
            "does not persist benchmark results",
        ] {
            XCTAssertTrue(runner.contains(required), "missing \(required)")
        }
        XCTAssertFalse(runner.contains("--output"))
        for productTarget in ["portavoz-app", "portavoz-cli", "ApplicationKit"] {
            let dependencies = try XCTUnwrap(targets[productTarget]).dependencies
            XCTAssertFalse(dependencies.contains("SQLiteVecResearchKit"))
            XCTAssertFalse(dependencies.contains("CSQLiteVecResearch"))
        }
    }

    func testExactPathMutationHostReceiptRequiresReviewWithoutThresholds() throws {
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let specification = try Self.contents(of: "docs/specs/04-intelligence.md")
        let contract = try Self.contents(
            of: "docs/evidence/exact-path-mutation-matrix.json")
        let validator = try Self.contents(
            of: "scripts/exact_path_mutation_matrix.py")
        let runner = try Self.contents(
            of: "scripts/run-exact-path-mutation-host-matrix.sh")
        let makefile = try Self.contents(of: "Makefile")
        let hygiene = try Self.contents(
            of: "scripts/check-repository-hygiene.sh")

        XCTAssertTrue(decisions.contains("## D219"))
        XCTAssertTrue(architecture.contains(
            "human-threshold-free-mutation-review-v1"))
        XCTAssertTrue(specification.contains(
            "exact-path-mutation-host-receipt"))
        XCTAssertTrue(try Self.contents(of: "docs/specs/08-quality.md").contains("make exact-path-mutation-host"))
        for required in [
            "\"minimumObservations\": 3",
            "\"reviewPolicyVersion\": \"human-threshold-free-mutation-review-v1\"",
            "\"batchSizes\"",
            "\"supportedOperatingSystemMajors\""
        ] {
            XCTAssertTrue(contract.contains(required), "missing \(required)")
        }
        XCTAssertFalse(contract.contains("maximumTimingP95ToP50Ratio"))
        XCTAssertFalse(contract.contains("minimumPerformanceImprovement"))

        for required in [
            "review-required",
            "agreement-failed",
            "observation_wall",
            "foundation.nearest_rank",
            "validate_host_receipt",
            "return 0 if receipt[\"outcome\"] == \"review-required\" else 1"
        ] {
            XCTAssertTrue(validator.contains(required), "missing \(required)")
        }
        for forbidden in [
            "segmentID", "meetingID", "transcript", "queryVector",
            "modelIdentifier", "databasePath", "filePath", "rawError"
        ] {
            XCTAssertFalse(validator.contains(forbidden), "leaked \(forbidden)")
        }
        for required in [
            "requires a clean committed checkout",
            "for _ in 1 2 3",
            "--matrix --runs 5",
            "source checkout changed during exact-path mutation collection",
            "not a performance pass or engine decision"
        ] {
            XCTAssertTrue(runner.contains(required), "missing \(required)")
        }
        XCTAssertFalse(runner.contains("--output"))
        XCTAssertTrue(makefile.contains("test-exact-path-mutation-host:") &&
                      makefile.contains("exact-path-mutation-host:"))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_exact_path_mutation_matrix"))
        XCTAssertTrue(hygiene.contains(
            "bash -n scripts/run-exact-path-mutation-host-matrix.sh"))
    }

    func testExactPathMutationCrossHostReviewIsThresholdFreeAndRecomputable() throws {
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let specification = try Self.contents(of: "docs/specs/04-intelligence.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")
        let contract = try Self.contents(
            of: "docs/evidence/exact-path-mutation-cross-host-matrix.json")
        let validator = try Self.contents(
            of: "scripts/exact_path_mutation_cross_host.py")
        let makefile = try Self.contents(of: "Makefile")
        let hygiene = try Self.contents(
            of: "scripts/check-repository-hygiene.sh")

        XCTAssertTrue(decisions.contains("## D220"))
        XCTAssertTrue(architecture.contains(
            "human-threshold-free-mutation-cross-host-review-v1"))
        XCTAssertTrue(specification.contains(
            "exact-path-mutation-cross-host-review"))
        XCTAssertTrue(quality.contains("make exact-path-mutation-cross-host"))
        for required in [
            "\"hostReceiptSchemaVersion\": 1",
            "\"hostReviewPolicyVersion\": \"human-threshold-free-mutation-review-v1\"",
            "\"requiredHostProfiles\"",
            "\"requiredOperatingSystemMajors\"",
        ] {
            XCTAssertTrue(contract.contains(required), "missing \(required)")
        }
        XCTAssertFalse(contract.contains("minimumPerformanceImprovement"))
        XCTAssertFalse(contract.contains("maximumTimingP95ToP50Ratio"))

        for required in [
            "exact-path-mutation-cross-host-review",
            "review-required",
            "validate_scorecard_against_receipts",
            "host_matrix.validate_host_receipt",
            "copy.deepcopy",
            "sameSourceCommit",
            "sameToolchain",
            "return 0 if scorecard[\"outcome\"] == \"review-required\" else 1",
        ] {
            XCTAssertTrue(validator.contains(required), "missing \(required)")
        }
        for forbidden in [
            "candidateToControl", "performanceRatio", "speedup",
            "minimumPerformanceImprovement", "maximumTimingP95ToP50Ratio",
        ] {
            XCTAssertFalse(validator.contains(forbidden), "forbidden \(forbidden)")
        }
        XCTAssertTrue(makefile.contains("test-exact-path-mutation-cross-host:"))
        XCTAssertTrue(makefile.contains("exact-path-mutation-cross-host:"))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_exact_path_mutation_cross_host"))
    }

    func testMutationBaselineNeedsExplicitReviewWithoutDecisionAuthority() throws {
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let specification = try Self.contents(of: "docs/specs/04-intelligence.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")
        let contract = try Self.contents(
            of: "docs/evidence/exact-path-mutation-baseline-admission.json")
        let publisher = try Self.contents(
            of: "scripts/exact_path_mutation_baseline.py")
        let makefile = try Self.contents(of: "Makefile")
        let hygiene = try Self.contents(of: "scripts/check-repository-hygiene.sh")

        XCTAssertTrue(decisions.contains("## D221"))
        XCTAssertTrue(architecture.contains(
            "explicit-human-review-digest-and-source-v1"))
        XCTAssertTrue(specification.contains(
            "exact-path-mutation-cross-host-research-baseline"))
        XCTAssertTrue(quality.contains("make exact-path-mutation-baseline"))
        for required in [
            #""authority": "research-correction-cost-only""#,
            #""engineDecision": "not-evaluated""#,
            #""performanceDecision": "not-evaluated""#,
            #""requiredScorecardOutcome": "review-required""#,
            #""requiredReviewAcknowledgement": "timings-reviewed-no-engine-decision-v1""#
        ] {
            XCTAssertTrue(contract.contains(required), "missing \(required)")
        }
        for required in [
            "validate_baseline", "require_source_checkout",
            "validate_output_destination", "write_owner_only", "withdraw_output"
        ] {
            XCTAssertTrue(publisher.contains(required), "missing \(required)")
        }
        XCTAssertTrue(makefile.contains("test-exact-path-mutation-baseline:"))
        XCTAssertTrue(makefile.contains("exact-path-mutation-baseline:"))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_exact_path_mutation_baseline"))
        XCTAssertTrue(try Self.sourceMatches(
            under: "Sources",
            pattern: "exact-path-mutation-cross-host-research-baseline"
        ).isEmpty)
    }

    func testExactPathHostReceiptRequiresACompleteStableContentFreeMatrix() throws {
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let specification = try Self.contents(of: "docs/specs/04-intelligence.md")
        let contract = try Self.contents(
            of: "docs/evidence/exact-path-shadow-matrix.json")
        let evaluator = try Self.contents(of: "scripts/exact_path_matrix.py")
        let runner = try Self.contents(
            of: "scripts/run-exact-path-shadow-matrix.sh")

        XCTAssertTrue(decisions.contains("## D215"))
        XCTAssertTrue(architecture.contains("exact-path-shadow-host-receipt"))
        XCTAssertTrue(specification.contains("nearest-rank-p95-p50-v1"))
        for required in [
            #""canonicalScales": ["#,
            #""minimumStableObservations": 3"#,
            #""maximumTimingP95ToP50Ratio": 1.25"#,
            #""hostReceiptSchemaVersion": 2"#,
            #""supportedOperatingSystemMajors": ["#,
        ] {
            XCTAssertTrue(contract.contains(required), "missing \(required)")
        }
        for required in [
            "reject_duplicate_keys",
            "exact_object",
            "observations came from different hosts",
            "scale {corpus_size} has excess or duplicate observations",
            "agreement-failed",
            "exact-path-shadow-host-receipt",
            "maximumWithinObservationTimingP95ToP50Ratio",
            "validate_host_receipt",
            "return 0 if receipt[\"outcome\"] == \"pass\" else 1",
        ] {
            XCTAssertTrue(evaluator.contains(required), "missing \(required)")
        }
        for required in [
            "git status --porcelain --untracked-files=all",
            "git rev-parse HEAD",
            "for _ in 1 2 3",
            "--matrix --runs 5",
            "source checkout changed during exact-path collection",
            "No raw observation or aggregate output path is accepted.",
        ] {
            XCTAssertTrue(runner.contains(required), "missing \(required)")
        }
        XCTAssertFalse(evaluator.contains("--output"))
        XCTAssertFalse(runner.contains("--output"))

        let productReferences = try Self.sourceMatches(
            under: "Sources",
            pattern: #"exact[_-]path[_-](?:matrix|shadow-host-receipt)"#)
        XCTAssertTrue(
            productReferences.isEmpty,
            "Exact-path acceptance tooling entered product code: \(productReferences)")
    }

    func testExactPathCrossHostScorecardRequiresComparableProfileAndOSCoverage() throws {
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let specification = try Self.contents(of: "docs/specs/04-intelligence.md")
        let contract = try Self.contents(
            of: "docs/evidence/exact-path-cross-host-matrix.json")
        let evaluator = try Self.contents(of: "scripts/exact_path_cross_host.py")

        XCTAssertTrue(decisions.contains("## D216"))
        XCTAssertTrue(architecture.contains("exact-path-shadow-cross-host-scorecard"))
        XCTAssertTrue(specification.contains("sameSourceCommit"))
        for required in [
            #""requiredHostProfiles": ["#,
            #""memory-8gb""#,
            #""memory-16gb""#,
            #""reference""#,
            #""requiredOperatingSystemMajors": ["#,
            #""hostReceiptSchemaVersion": 2"#,
            #""comparisonPolicyVersion": "within-host-query-p50-p95-ratio-v1""#,
        ] {
            XCTAssertTrue(contract.contains(required), "missing \(required)")
        }
        for required in [
            "host_matrix.validate_host_receipt",
            "host receipt stream repeats profile",
            "missingOperatingSystemMajors",
            "sameSourceCommit",
            "sameToolchain",
            "candidateToControlQueryP50Ratio",
            "not-comparable",
            "exact-path-shadow-cross-host-scorecard",
            "return 0 if scorecard[\"outcome\"] == \"pass\" else 1",
        ] {
            XCTAssertTrue(evaluator.contains(required), "missing \(required)")
        }
        XCTAssertFalse(evaluator.contains("--output"))

        let productReferences = try Self.sourceMatches(
            under: "Sources",
            pattern: #"exact[_-]path[_-](?:cross[_-]host|shadow-cross-host-scorecard)"#)
        XCTAssertTrue(
            productReferences.isEmpty,
            "Cross-host exact-path tooling entered product code: \(productReferences)")
    }

    func testExactPathResearchBaselineRequiresDigestBoundPrivateAdmission() throws {
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let specification = try Self.contents(of: "docs/specs/04-intelligence.md")
        let contract = try Self.contents(
            of: "docs/evidence/exact-path-baseline-admission.json")
        let admission = try Self.contents(of: "scripts/exact_path_baseline.py")
        let publication = try Self.contents(
            of: "scripts/private_research_baseline.py")

        XCTAssertTrue(decisions.contains("## D217"))
        XCTAssertTrue(architecture.contains(
            "exact-path-shadow-cross-host-research-baseline"))
        XCTAssertTrue(specification.contains(
            "explicit-scorecard-digest-and-source-v1"))
        for required in [
            #""authority": "research-comparison-only""#,
            #""engineDecision": "not-evaluated""#,
            #""maximumBaselineBytes": 2097152"#,
            #""reviewPolicyVersion": "explicit-scorecard-digest-and-source-v1""#,
        ] {
            XCTAssertTrue(contract.contains(required), "missing \(required)")
        }
        for required in [
            "cross_host.validate_scorecard_against_receipts",
            "canonical_scorecard_file_bytes",
            "--accept-scorecard-sha256",
            "--accept-source-commit",
            "withdraw_output(output)",
            "research-comparison-only",
            "not-evaluated",
        ] {
            XCTAssertTrue(admission.contains(required), "missing \(required)")
        }
        for required in [
            "source worktree must be clean for baseline retention",
            "repository-local baseline output must be ignored",
            "os.fchmod(descriptor, 0o600)",
            "os.link(temporary, path)",
        ] {
            XCTAssertTrue(publication.contains(required), "missing \(required)")
        }

        let productReferences = try Self.sourceMatches(
            under: "Sources",
            pattern: #"exact[_-]path[_-](?:baseline|research-baseline)"#)
        XCTAssertTrue(
            productReferences.isEmpty,
            "Exact-path baseline admission entered product code: \(productReferences)")
    }

    func testTopicContinuityKeepsLabelsAsCandidatesAndMutationsExplicit() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/TopicContinuity.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/TopicContinuity.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+TopicContinuity.swift")
        let confirmation = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+TopicContinuityConfirmation.swift")
        let evidence = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+TopicContinuityEvidence.swift")
        let identity = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+TopicContinuityIdentity.swift")
        let migration = try Self.contents(
            of: "Sources/StorageKit/Schema+TopicContinuity.swift")
        let package = try Self.contents(of: "Package.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(core.contains("struct Topic:"))
        XCTAssertTrue(core.contains("struct TopicLinkProposal:"))
        XCTAssertTrue(core.contains("case generatedSimilarity"))
        XCTAssertTrue(core.contains("enum TopicEvidenceAvailability"))
        XCTAssertTrue(application.contains("protocol TopicContinuityStore"))
        XCTAssertTrue(application.contains("struct ConfirmTopicLink"))
        XCTAssertTrue(application.contains("struct ConfirmTopicMerge"))
        XCTAssertTrue(application.contains("struct ConfirmTopicSplit"))
        XCTAssertFalse(application.contains("import IntelligenceKit"))
        XCTAssertTrue(storage.contains("topicIdentityHistory"))
        XCTAssertTrue(confirmation.contains("source transcript revision is stale"))
        XCTAssertTrue(evidence.contains("acceptedSegmentHasNoActiveCorrectionSQL"))
        XCTAssertTrue(identity.contains("topicIdentityEvent"))
        XCTAssertTrue(migration.contains("registerMigration(\"v25\")"))
        XCTAssertTrue(migration.contains("topicMeetingEvidence"))
        XCTAssertTrue(migration.contains("topicIdentityEvent"))
        XCTAssertFalse(package.localizedCaseInsensitiveContains("neo4j"))
        XCTAssertTrue(decisions.contains("## D271"))
    }

    func testResourceBaselineEvidenceIsCompleteFailClosedAndToolingOnly() throws {
        let contract = try Self.jsonObject(
            at: "docs/evidence/resource-baseline-matrix.json")
        let profiles = try XCTUnwrap(contract["profiles"] as? [[String: Any]])
        let scenarios = try XCTUnwrap(contract["scenarios"] as? [[String: Any]])
        XCTAssertEqual(
            Set(profiles.compactMap { $0["id"] as? String }),
            Set(["memory-8gb", "memory-16gb", "reference"]))
        XCTAssertEqual(
            Set(scenarios.compactMap { $0["id"] as? String }),
            Set([
                "idle", "recording", "stop", "refine", "summary", "ask",
                "indexing", "recording-indexing", "recording-batch",
            ]))
        XCTAssertEqual(contract["minimumStableSamples"] as? Int, 3)
        XCTAssertEqual(contract["schemaVersion"] as? Int, 4)
        XCTAssertEqual(
            contract["minimumBlockingTimingDeltaMilliseconds"] as? Int,
            100)
        let recordingInput = try XCTUnwrap(
            contract["recordingInput"] as? [String: Any])
        XCTAssertEqual(
            recordingInput["generation"] as? String,
            "public-synthetic-dual-channel-v2")
        XCTAssertEqual(recordingInput["sampleRate"] as? Int, 16_000)
        XCTAssertEqual(recordingInput["chunkFrames"] as? Int, 1_600)
        let preparations = try XCTUnwrap(
            contract["preparations"] as? [[String: Any]])
        XCTAssertEqual(preparations.count, 2)
        XCTAssertEqual(preparations[0]["id"] as? String, "refine-runtime")
        XCTAssertEqual(preparations[1]["id"] as? String, "summary-runtime")
        XCTAssertEqual(
            preparations[1]["generation"] as? String, "summary-runtime-preparation-v1")
        XCTAssertEqual(
            preparations[1]["marker"] as? String,
            "portavoz-resource-summary-runtime-prepared-v1\n")
        XCTAssertEqual(
            preparations[0]["generation"] as? String,
            "refine-runtime-preparation-v2")
        XCTAssertEqual(
            preparations[0]["marker"] as? String,
            "portavoz-resource-refine-runtime-prepared-v2\n")
        XCTAssertEqual(
            contract["maximumTimingP95ToP50Ratio"] as? Double,
            1.25)

        let evaluator = try Self.contents(of: "scripts/resource_baseline.py")
        let hygiene = try Self.contents(
            of: "scripts/check-repository-hygiene.sh")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        XCTAssertTrue(evaluator.contains(
            #"if all(row["state"] == "pass" for row in measurements)"#))
        XCTAssertTrue(evaluator.contains("object_pairs_hook=reject_duplicate_keys"))
        XCTAssertTrue(evaluator.contains("os.chmod(temporary, 0o600)"))
        XCTAssertTrue(evaluator.contains(
            "contract.maximumTimingP95ToP50Ratio must be <= 1.25"))
        XCTAssertTrue(evaluator.contains(
            "contract.minimumBlockingTimingDeltaMilliseconds must be <= 100"))
        for forbidden in [
            "meetingTitle", "transcriptText", "sourcePath", "modelName",
            "errorMessage",
        ] {
            XCTAssertFalse(
                evaluator.contains(forbidden),
                "Resource evidence must not admit payload field \(forbidden)")
        }
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_resource_baseline"))
        XCTAssertTrue(decisions.contains("## D149"))
        XCTAssertTrue(decisions.contains("## D150"))
        XCTAssertTrue(decisions.contains("## D444"))

        let nativeProbe = try Self.contents(
            of: "Sources/portavoz-app/ResourceRunProbe.swift")
        let benchProbes = try Self.contents(
            of: "Sources/portavoz-app/BenchRecordResourceProbes.swift")
        let scenarioProbe = try Self.contents(
            of: "Sources/portavoz-app/BenchResourceScenarioProbe.swift")
        let benchMode = try Self.contents(
            of: "Sources/portavoz-app/BenchMode.swift")
        let askBench = try Self.contents(
            of: "Sources/portavoz-app/BenchMode+ResourceAsk.swift")
        let refinePreparationMode = try Self.contents(
            of: "Sources/portavoz-app/BenchMode+ResourceRefinePreparation.swift")
        let recordingRunner = try Self.contents(
            of: "Sources/portavoz-app/BenchRecordingResourceRunner.swift")
        let syntheticCapture = try Self.contents(
            of: "Sources/portavoz-app/BenchSyntheticRecordingRuntime.swift")
        let resourceWatchdog = try Self.contents(
            of: "Sources/portavoz-app/BenchResourceProcessWatchdog.swift")
        let launchProbe = try Self.contents(
            of: "Sources/portavoz-app/BenchResourceLaunchProbe.swift")
        let indexingBench = try Self.contents(
            of: "Sources/portavoz-app/BenchMode+ResourceIndexing.swift")
        let batchBench = try Self.contents(
            of: "Sources/portavoz-app/BenchMode+ResourceBatch.swift")
        let app = try Self.contents(
            of: "Sources/portavoz-app/AppLaunchModel.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices.swift")
        let volatileSecrets = try Self.contents(
            of: "Sources/PlatformKit/VolatileSecretStore.swift")
        let scheduler = try Self.contents(
            of: "Sources/IntelligenceKit/IntelligenceScheduler.swift")
        let mlxProvider = try Self.contents(
            of: "Sources/IntelligenceKit/MLXSummaryProvider.swift")
        let postCapture = try Self.contents(
            of: "Sources/portavoz-app/PostCaptureProcessingCoordinator.swift")
        let runner = try Self.contents(
            of: "scripts/run-resource-baseline.sh")
        let resourceBenchEntitlements = try Self.contents(
            of: "packaging/portavoz-resource-bench.entitlements")
        let localEntitlements = try Self.contents(
            of: "packaging/portavoz-local.entitlements")
        let compatibilityRunner = try Self.contents(
            of: "scripts/run-resource-recording-baseline.sh")
        XCTAssertTrue(nativeProbe.contains("proc_pid_rusage"))
        XCTAssertTrue(syntheticCapture.contains(
            "public-synthetic-dual-channel-v2"))
        XCTAssertTrue(syntheticCapture.contains(
            "expectedFrames: expectedFrames"))
        XCTAssertTrue(syntheticCapture.contains(
            "let emission = lock.withLock"))
        XCTAssertTrue(syntheticCapture.contains(
            "startedAt.advanced(by: offset)"))
        XCTAssertTrue(syntheticCapture.contains(
            "runtime.engine.transcribe"))
        XCTAssertFalse(syntheticCapture.contains(
            "Task.sleep(for: .milliseconds(100))"))
        XCTAssertTrue(syntheticCapture.contains(
            "BenchSyntheticCapturePolicy.hasExactFrames"))
        XCTAssertTrue(syntheticCapture.contains(
            "appearsOnce(\"-use-temp-store\", in: arguments)"))
        XCTAssertFalse(syntheticCapture.contains("MicrophoneSource("))
        XCTAssertFalse(syntheticCapture.contains("ProcessTapSource("))
        XCTAssertFalse(syntheticCapture.contains("requestAccess"))
        XCTAssertTrue(recordingRunner.contains(
            "BenchSyntheticCapturePolicy"))
        XCTAssertTrue(recordingRunner.contains(
            "BenchLiveSpeechResourceWarmup.run"))
        XCTAssertTrue(recordingRunner.contains(
            ".validateResourceRequest(arguments: arguments)"))
        XCTAssertTrue(recordingRunner.contains(
            "BenchRecordingResourcePolicy.duration"))
        XCTAssertTrue(recordingRunner.contains(
            "guard case .done = recording.phase else"))
        XCTAssertTrue(recordingRunner.contains(
            "await services.authorizeMicrophoneForRecording()"))
        XCTAssertTrue(resourceWatchdog.contains(
            "expirationStatus: Int32 = 124"))
        XCTAssertTrue(resourceWatchdog.contains(
            "Darwin._exit(expirationStatus)"))
        XCTAssertTrue(resourceWatchdog.contains(
            "BenchMode.runsIsolatedBenchmark"))
        XCTAssertTrue(runner.contains(
            "PROCESS_TIMEOUT >= MAX_BENCHMARK_PHASE_TIMEOUT + 420"))
        XCTAssertTrue(runner.contains(
            "guard_timeout=$((PROCESS_TIMEOUT + 30))"))
        XCTAssertTrue(runner.contains(
            #"pgrep -f -- "$APP/Contents/MacOS/portavoz-app""#))
        XCTAssertTrue(nativeProbe.contains("ri_energy_nj"))
        XCTAssertTrue(nativeProbe.contains(
            "IOPSGetProvidingPowerSourceType"))
        XCTAssertTrue(nativeProbe.contains(".posixPermissions: 0o600"))
        XCTAssertTrue(nativeProbe.contains(
            "enum ResourceProbeHostReadiness"))
        XCTAssertTrue(nativeProbe.contains(
            "consecutiveNominal == 2"))
        XCTAssertTrue(benchProbes.contains(
            "finishRecordingAndBeginStop"))
        XCTAssertTrue(benchProbes.contains(
            "func measureIdle()"))
        XCTAssertTrue(benchProbes.contains(
            "ResourceProbeHostReadiness.waitUntilNominal()"))
        XCTAssertTrue(benchProbes.contains(
            "replayingActive: true"))
        XCTAssertTrue(benchProbes.contains(
            "freezeBeforeStop"))
        XCTAssertTrue(benchProbes.contains(
            "finishAfterStopAndWrite"))
        XCTAssertTrue(recordingRunner.contains(
            #"arguments.contains("-use-temp-store")"#))
        let permissionPreflight = try XCTUnwrap(recordingRunner.range(
            of: "authorizeMicrophoneForRecording()"))
        let recordingProbeStart = try XCTUnwrap(recordingRunner.range(
            of: "baselineProbes?.beginRecording()"))
        XCTAssertLessThan(
            permissionPreflight.lowerBound,
            recordingProbeStart.lowerBound)
        XCTAssertTrue(recordingRunner.contains(
            "recording Stop exceeded 30 seconds"))
        XCTAssertTrue(recordingRunner.contains(
            "prepareIndexingResourceWorkload"))
        XCTAssertTrue(recordingRunner.contains(
            "concurrent semantic indexing complete"))
        XCTAssertTrue(recordingRunner.contains(
            "prepareBatchTranscriptionResourceWorkload"))
        XCTAssertTrue(recordingRunner.contains(
            "concurrent batch transcription complete"))
        XCTAssertTrue(batchBench.contains(
            "services.transcriptionScheduler.batch"))
        XCTAssertTrue(batchBench.contains(
            "workloadClass: .postCapture"))
        XCTAssertTrue(batchBench.contains(
            "BenchResourceTimedOperation.run"))
        XCTAssertTrue(recordingRunner.contains(
            "concurrentWorkload.prepareForMeasurement"))
        XCTAssertTrue(recordingRunner.contains(
            "BenchMode.prepareIndexingResourceWarmup"))
        XCTAssertTrue(recordingRunner.contains(
            "let transcription = try await workload.run"))
        XCTAssertTrue(recordingRunner.contains(
            "try workload.validate(transcription)"))
        let liveWarmup = try XCTUnwrap(recordingRunner.range(
            of: "BenchLiveSpeechResourceWarmup.run"))
        let batchWarmup = try XCTUnwrap(recordingRunner.range(
            of: "concurrentWorkload.prepareForMeasurement"))
        let recordingReadiness = try XCTUnwrap(recordingRunner.range(
            of: "ResourceProbeHostReadiness.waitUntilNominal()"))
        XCTAssertLessThan(liveWarmup.lowerBound, batchWarmup.lowerBound)
        XCTAssertLessThan(batchWarmup.lowerBound, recordingReadiness.lowerBound)
        XCTAssertLessThan(
            recordingReadiness.lowerBound,
            recordingProbeStart.lowerBound)
        XCTAssertTrue(services.contains(
            "usesTemporarySensitiveStore"))
        XCTAssertTrue(services.contains(
            "VolatileSecretStore()"))
        XCTAssertTrue(services.contains(
            "voiceprintStore = sensitiveStorage.voiceprintStore"))
        XCTAssertFalse(volatileSecrets.contains("Security"))
        XCTAssertFalse(volatileSecrets.contains("SecItem"))
        XCTAssertTrue(refinePreparationMode.contains(
            "runRefineResourcePreparationIfRequested"))
        XCTAssertTrue(refinePreparationMode.contains(
            "services.refineMeeting.draft"))
        XCTAssertTrue(refinePreparationMode.contains(".execute(request)"))
        XCTAssertTrue(refinePreparationMode.contains("draft.segments.count"))
        XCTAssertTrue(refinePreparationMode.contains("BenchRefineRuntimePreparation.run"))
        XCTAssertTrue(launchProbe.contains(
            "portavoz-resource-refine-runtime-prepared-v2"))
        XCTAssertTrue(app.contains(
            "runRefineResourcePreparationIfRequested"))
        XCTAssertTrue(runner.contains(
            "--bench-resource-prepare-refine"))
        XCTAssertTrue(runner.contains(
            "--preparation \"refine-runtime=$refine_runtime_marker\""))
        let refinePreparation = try XCTUnwrap(runner.range(
            of: "Preparing Refine runtime before repeated measurement"))
        let batchRuns = try XCTUnwrap(runner.range(
            of: "Collecting recording plus batch resource sample"))
        let refineRuns = try XCTUnwrap(runner.range(
            of: "Collecting Refine resource sample"))
        XCTAssertLessThan(batchRuns.lowerBound, refinePreparation.lowerBound)
        XCTAssertLessThan(refinePreparation.lowerBound, refineRuns.lowerBound)
        XCTAssertTrue(runner.contains("--bench-resource-preparation-audio"))
        XCTAssertEqual(
            runner.components(
                separatedBy: "for ((run = 1; run <= RUNS; run++)); do"
            ).count - 1,
            7)
        XCTAssertTrue(runner.contains(
            "Keep the three samples for each scenario family adjacent"))
        XCTAssertTrue(benchMode.contains(
            "runRefineResourceBenchIfRequested"))
        XCTAssertTrue(benchMode.contains(
            "services.refineMeeting.draft.execute"))
        XCTAssertTrue(benchMode.contains(
            "runSummaryResourceBenchIfRequested"))
        XCTAssertTrue(benchMode.contains(
            "services.regenerateSummary.execute"))
        XCTAssertTrue(benchMode.contains(
            "providerOverride: .mlx"))
        XCTAssertTrue(askBench.contains(
            "runAskResourceBenchIfRequested"))
        XCTAssertTrue(askBench.contains(
            "services.semanticIndexingCoordinator.all"))
        XCTAssertTrue(askBench.contains(
            "allowAssetDownload: false"))
        XCTAssertTrue(askBench.contains("pendingAtSeed"))
        let preparation = try XCTUnwrap(askBench.range(
            of: "let preparation = try await prepareAskResourceBenchmark("))
        let measuredWindow = try XCTUnwrap(askBench.range(
            of: "let citations = try await probe.measure(scenario:"))
        XCTAssertLessThan(preparation.lowerBound, measuredWindow.lowerBound)
        XCTAssertTrue(askBench.contains("try pipeline.writeSample(to: output"))
        XCTAssertTrue(askBench.contains("try pipelineProbe.writePreparedSample("))

        XCTAssertTrue(askBench.contains(
            "source: .library"))
        XCTAssertTrue(indexingBench.contains(
            "runIndexingResourceBenchIfRequested"))
        XCTAssertTrue(indexingBench.contains(
            "IndexSemanticCorpus("))
        XCTAssertTrue(indexingBench.contains(
            "try await workload.run("))
        XCTAssertTrue(indexingBench.contains(
            "let store = try MeetingStore.inMemory()"))
        XCTAssertTrue(indexingBench.contains(
            "store: services.store"))
        let standaloneIndexWarmup = try XCTUnwrap(indexingBench.range(
            of: "try await prepareIndexingResourceWarmup("))
        let standaloneIndexProbe = try XCTUnwrap(indexingBench.range(
            of: "try await probe.measure(scenario: \"indexing\")"))
        XCTAssertLessThan(
            standaloneIndexWarmup.lowerBound,
            standaloneIndexProbe.lowerBound)
        let indexWarmupDeclaration = try XCTUnwrap(indexingBench.range(
            of: "static func prepareIndexingResourceWarmup("))
        let indexWorkloadsDeclaration = try XCTUnwrap(indexingBench.range(
            of: "private static func prepareIndexingResourceWorkloads("))
        let indexWarmupBody = String(indexingBench[
            indexWarmupDeclaration.lowerBound..<indexWorkloadsDeclaration.lowerBound
        ])
        XCTAssertTrue(indexWarmupBody.contains(
            "let store = try MeetingStore.inMemory()"))
        XCTAssertTrue(indexWarmupBody.contains("iteration: 0"))
        XCTAssertTrue(indexWarmupBody.contains("prepareRuntime: false"))
        XCTAssertTrue(indexWarmupBody.contains(
            "let result = try await workload.run("))
        XCTAssertTrue(indexWarmupBody.contains(
            "try await workload.validate(result)"))
        XCTAssertFalse(indexWarmupBody.contains("services.store"))
        XCTAssertTrue(benchMode.contains(
            "runsIsolatedBenchmark"))
        let benchmarkExit = try XCTUnwrap(app.range(
            of: "guard !runsIsolatedBenchmark else { return }"))
        let normalStartup = try XCTUnwrap(app.range(
            of: "await services.meetingSync.start"))
        XCTAssertLessThan(benchmarkExit.lowerBound, normalStartup.lowerBound)
        XCTAssertTrue(app.contains(
            "if !runsIsolatedBenchmark"))
        let appShell = try Self.contents(
            of: "Sources/portavoz-app/PortavozApp.swift")
        XCTAssertTrue(appShell.contains(
            "if runsIsolatedBenchmark {"))
        XCTAssertTrue(appShell.contains(
            "? .constant(false)\n            : $menuBarEnabled"))
        let isolatedView = try XCTUnwrap(appShell.range(
            of: "if runsIsolatedBenchmark {"))
        let productView = try XCTUnwrap(appShell.range(
            of: "AppLaunchRootView(model: launch)"))
        XCTAssertLessThan(isolatedView.lowerBound, productView.lowerBound)
        XCTAssertTrue(benchMode.contains(
            "forceVerification: true"))
        XCTAssertTrue(scenarioProbe.contains(
            "BenchResourceTimedOperation"))
        XCTAssertTrue(scenarioProbe.contains(
            "ResourceProbeHostReadiness.waitUntilNominal()"))
        XCTAssertTrue(scenarioProbe.contains(
            "replayingActive: true"))
        XCTAssertTrue(scenarioProbe.contains(
            "probe.writeSample"))
        XCTAssertTrue(services.contains(
            "AppInitialModelReadinessPolicy.schedulesRefresh("))
        XCTAssertTrue(services.contains(
            "!BenchMode.runsIsolatedBenchmark(arguments: arguments)"))
        XCTAssertTrue(runner.contains(
            "app.portavoz.mac.resource-bench"))
        XCTAssertTrue(runner.contains(
            "packaging/portavoz-resource-bench.entitlements"))
        XCTAssertTrue(runner.contains(
            "--bench-resource-launch-probe"))
        XCTAssertTrue(runner.contains(
            "portavoz-resource-benchmark-ready-v1"))
        XCTAssertTrue(runner.contains(
            "entitlements = plistlib.load(handle)"))
        XCTAssertTrue(runner.contains(
            "could not inspect the signed library-validation entitlement"))
        XCTAssertFalse(runner.contains(
            "plutil -extract com.apple.security.cs.disable-library-validation"))
        XCTAssertTrue(resourceBenchEntitlements.contains(
            "com.apple.security.cs.disable-library-validation"))
        XCTAssertFalse(localEntitlements.contains(
            "com.apple.security.cs.disable-library-validation"))
        XCTAssertEqual(
            runner.components(separatedBy: "run_benchmark_app").count - 1,
            11)
        XCTAssertFalse(runner.contains(
            #"open -W -n "$APP/Contents/MacOS/portavoz-app""#))
        XCTAssertTrue(runner.contains(
            "resource_baseline.py assemble"))
        XCTAssertTrue(runner.contains(
            #"sample_arguments+=(--sample "idle=$idle_sample")"#))
        XCTAssertTrue(runner.contains(
            #"sample_arguments+=(--sample "refine=$refine_sample")"#))
        XCTAssertTrue(runner.contains(
            #"sample_arguments+=(--sample "summary=$summary_sample")"#))
        XCTAssertTrue(runner.contains(
            #"sample_arguments+=(--sample "ask=$ask_sample")"#))
        XCTAssertTrue(runner.contains(
            #"sample_arguments+=(--sample "indexing=$indexing_sample")"#))
        XCTAssertTrue(runner.contains(
            "--bench-resource-recording-indexing"))
        XCTAssertTrue(runner.contains(
            #""recording-indexing=$recording_indexing_sample""#))
        XCTAssertTrue(runner.contains(
            "--bench-resource-recording-batch"))
        XCTAssertTrue(runner.contains(
            #""recording-batch=$recording_batch_sample""#))
        XCTAssertTrue(scheduler.contains(
            "static let mlx = IntelligenceScheduler"))
        XCTAssertTrue(mlxProvider.contains(
            "IntelligenceScheduler.mlx.run(priority)"))
        XCTAssertTrue(postCapture.contains(
            "priority: .background"))
        XCTAssertTrue(compatibilityRunner.contains(
            #"exec "$ROOT/scripts/run-resource-baseline.sh" "$@""#))
        XCTAssertFalse(runner.contains("/Applications/Portavoz.app"))
        for forbidden in [
            "meetingTitle", "transcriptText", "sourcePath", "modelName",
            "errorMessage",
        ] {
            XCTAssertFalse(
                nativeProbe.contains(forbidden),
                "Native resource samples must not admit \(forbidden)")
        }

        let appSources = try Self.sourceMatches(
            under: "Sources",
            pattern: #"resource-baseline(?:-matrix|-scorecard)?"#)
        XCTAssertTrue(
            appSources.isEmpty,
            "Production packages must not read resource evidence: \(appSources)")
    }

    func testLongCaptureEvidenceUsesProductionSessionAndBoundedHeap() throws {
        let writer = try Self.contents(
            of: "Sources/AudioCaptureKit/CaptureFileWriter.swift")
        let session = try Self.contents(
            of: "Sources/AudioCaptureKit/RecordingSession.swift")
        let publication = try Self.contents(
            of: "Sources/AudioCaptureKit/CaptureFilePublication.swift")
        let command = try Self.contents(
            of: "Sources/portavoz-cli/CLIBenchCapture.swift")
        let dispatch = try Self.contents(of: "Sources/portavoz-cli/CLI.swift")
        let runner = try Self.contents(
            of: "scripts/run-long-capture-baseline.sh")
        let validator = try Self.contents(
            of: "scripts/long_capture_evidence.py")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(writer.contains(
            "private var reusableBuffer: AVAudioPCMBuffer?"))
        XCTAssertTrue(writer.contains("func close()"))
        XCTAssertTrue(session.contains(
            "public let framesWritten: [AudioChannel: Int64]"))
        XCTAssertTrue(session.contains(
            "for writer in writers.values { writer.close() }"))
        XCTAssertTrue(publication.contains(
            "let reachedEnd = try autoreleasepool"))
        XCTAssertTrue(publication.contains(
            "handle.read(upToCount: 1 << 20)"))

        XCTAssertTrue(dispatch.contains(#"case "bench-capture":"#))
        XCTAssertTrue(command.contains(
            "let channels: [AudioChannel] = [.microphone, .system]"))
        XCTAssertTrue(command.contains(
            "barrier.wait("))
        XCTAssertFalse(command.contains("bufferingNewest"))
        XCTAssertTrue(command.contains(
            "maximumIncrementalHeapBytesInUse: UInt64 = 16 * 1_024 * 1_024"))
        XCTAssertTrue(runner.contains(
            "git status --porcelain --untracked-files=all"))
        XCTAssertTrue(runner.contains("output already exists"))
        XCTAssertTrue(runner.contains(
            "the source commit or worktree changed during collection"))
        XCTAssertTrue(runner.contains("swift build -c release --product portavoz-cli"))
        XCTAssertTrue(runner.contains("--duration-seconds 10800"))
        XCTAssertTrue(runner.contains("--source-commit \"$COMMIT\""))
        XCTAssertTrue(validator.contains("TOP_LEVEL_KEYS"))
        XCTAssertTrue(validator.contains("contentSource must be synthetic-only"))
        XCTAssertTrue(validator.contains("duration-invariant heap bound was exceeded"))
        XCTAssertTrue(decisions.contains("## D191"))
    }

    func testEncryptedVoiceIdentityMutationsRemainCrossProcessTransactions() throws {
        let gallery = try Self.contents(of: "Sources/DiarizationKit/VoiceGallery.swift")
        let voiceprint = try Self.contents(
            of: "Sources/DiarizationKit/VoiceprintStore.swift")
        let transaction = try Self.contents(
            of: "Sources/DiarizationKit/VoiceIdentityStorageTransaction.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertEqual(
            gallery.components(separatedBy:
                "VoiceIdentityStorageTransaction.withExclusiveAccess").count - 1,
            4)
        XCTAssertEqual(
            voiceprint.components(separatedBy:
                "VoiceIdentityStorageTransaction.withExclusiveAccess").count - 1,
            3)
        XCTAssertTrue(gallery.contains("var all = try readWithoutLock()"))
        XCTAssertFalse(gallery.contains("var all = try voices()"))
        XCTAssertTrue(transaction.contains("O_CLOEXEC | O_NOFOLLOW"))
        XCTAssertTrue(transaction.contains("Darwin.fchmod"))
        XCTAssertTrue(transaction.contains("S_IRUSR | S_IWUSR"))
        XCTAssertTrue(transaction.contains("LOCK_EX"))
        XCTAssertTrue(transaction.contains("code == EINTR"))
        XCTAssertTrue(transaction.contains(#"@_silgen_name("flock")"#))
        XCTAssertTrue(decisions.contains(
            "D358 — Encrypted voice identity mutations are serialized across processes"))
    }

    func testRealModelGateReservesContextAndNeverEchoesTranscriptContent() throws {
        let formatter = try Self.contents(
            of: "Sources/IntelligenceKit/TranscriptFormatter.swift")
        let provider = try Self.contents(
            of: "Sources/IntelligenceKit/FoundationModelSummaryProvider.swift")
        let intelligenceTests = try Self.contents(
            of: "Tests/PortavozTests/IntelligenceTests.swift")
        let parakeetTests = try Self.contents(
            of: "Tests/PortavozTests/ParakeetIntegrationTests.swift")
        let makefile = try Self.contents(of: "Makefile")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let intelligenceSpec = try Self.contents(of: "docs/specs/04-intelligence.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(formatter.contains("onDeviceChunkBudget = 4000"))
        XCTAssertTrue(formatter.contains("onDeviceReduceBudget = 3000"))
        XCTAssertTrue(formatter.contains("onDeviceRetryFloor = 500"))
        XCTAssertFalse(formatter.contains("from a 4500-char chunk"))
        XCTAssertTrue(formatter.contains("line.count > effectiveBudget"))
        XCTAssertTrue(formatter.contains("limitedBy: line.endIndex"))
        XCTAssertTrue(provider.contains("exceededContextWindowSize"))
        XCTAssertTrue(provider.contains("nextOnDeviceRetryBudget"))
        XCTAssertTrue(intelligenceTests.contains(
            "testOnDeviceBudgetsReserveGuidedGenerationHeadroom"))
        XCTAssertTrue(intelligenceTests.contains(
            "testOversizedSingleUtteranceCannotEscapeTheChunkBudget"))

        XCTAssertTrue(parakeetTests.contains("#if DEBUG"))
        XCTAssertTrue(parakeetTests.contains("lexicalCharacterCount"))
        XCTAssertTrue(parakeetTests.contains("duration <= 600"))
        XCTAssertTrue(parakeetTests.contains("producer.cancel()"))
        XCTAssertFalse(parakeetTests.contains("wavPath!"))
        XCTAssertFalse(parakeetTests.contains("floatChannelData!"))
        XCTAssertFalse(parakeetTests.contains(#"fullText.contains("fox")"#))
        XCTAssertFalse(parakeetTests.contains("unexpected live transcript"))

        XCTAssertTrue(makefile.contains(
            "swift test --configuration release --filter"))
        XCTAssertTrue(makefile.contains(
            #"grep -Eq '\[DEBUG\] \[FluidAudio\.'"#))
        XCTAssertTrue(makefile.contains("private log withheld"))
        XCTAssertTrue(makefile.contains(#"trap 'rm -f "$$log"' EXIT"#))
        XCTAssertTrue(makefile.contains("trap 'exit 129' HUP"))
        XCTAssertTrue(makefile.contains("trap 'exit 130' INT"))
        XCTAssertTrue(makefile.contains("trap 'exit 143' TERM"))
        XCTAssertFalse(makefile.contains(#"tail -20 "$$log""#))

        XCTAssertTrue(architecture.contains("4096-token guided-generation context"))
        XCTAssertTrue(intelligenceSpec.contains("FluidAudio 0.15.6"))
        XCTAssertTrue(decisions.contains("## D380"))
    }

    func testBandFourScaleBaselineStaysMeasuredAndDisposable() throws {
        let cli = try Self.contents(of: "Sources/portavoz-cli/CLIBenchScale.swift")
        let semanticCLI = try Self.contents(
            of: "Sources/portavoz-cli/CLIBenchSemantic.swift")
        let waveformCLI = try Self.contents(
            of: "Sources/portavoz-cli/CLIBenchWaveform.swift")
        let spotlightCLI = try Self.contents(
            of: "Sources/portavoz-cli/CLIBenchSpotlight.swift")
        let dispatch = try Self.contents(of: "Sources/portavoz-cli/CLI.swift")
        let package = try Self.contents(of: "Package.swift")
        let performanceBinary = try Self.contents(of: "scripts/perf-binary.sh")
        let scaleRunner = try Self.contents(of: "scripts/run-scale-baseline.sh")
        let semanticRunner = try Self.contents(
            of: "scripts/run-semantic-scale-baseline.sh")
        let semanticControlRunner = try Self.contents(
            of: "scripts/run-semantic-control-baseline.sh")
        let semanticManifest = try Self.contents(
            of: "scripts/semantic_scale_manifest.py")
        let semanticControl = try Self.contents(
            of: "docs/evidence/semantic-scale-current-control-20260813.json")
        let semanticThreeVariant = try Self.contents(
            of: "docs/evidence/semantic-scale-three-variant-diagnostic-20260813.json")
        let semanticCrossHost = try Self.contents(
            of: "docs/evidence/semantic-scale-cross-host-readiness-20260819.json")
        let spotlightRunner = try Self.contents(
            of: "scripts/run-spotlight-scale-baseline.sh")
        let detailRunner = try Self.contents(of: "scripts/run-detail-ui-baseline.sh")
        let detailParser = try Self.contents(of: "scripts/meeting_detail_performance.py")
        let detailTrace = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailPerformanceTrace.swift")
        let detailUITests = try Self.contents(
            of: "Tests/PortavozUITests/MeetingDetailUITests.swift")
        let fixture = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ScaleBenchmark.swift")
        let model = try Self.meetingDetailModelContents()
        let health = try Self.contents(of: "Sources/IntelligenceKit/MeetingHealth.swift")
        let search = try Self.contents(of: "Sources/StorageKit/MeetingStore+Search.swift")
            + Self.contents(
                of: "Sources/StorageKit/MeetingStore+SemanticSearch.swift")
        let ask = try Self.contents(
            of: "Sources/ApplicationKit/LocalAskMeetingRetrieval.swift")
        let waveform = try Self.contents(of: "Sources/AudioPlaybackKit/Waveform.swift")
        let spotlightProjection = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+Spotlight.swift")
        let spotlightIndexer = try Self.contents(
            of: "Sources/portavoz-app/SpotlightIndexer.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let content = try Self.contents(of: "Sources/portavoz-app/ContentView.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(dispatch.contains(#"case "bench-scale":"#))
        XCTAssertTrue(dispatch.contains(#"case "bench-semantic":"#))
        XCTAssertTrue(dispatch.contains(#"case "bench-waveform":"#))
        XCTAssertTrue(dispatch.contains(#"case "bench-spotlight":"#))
        XCTAssertTrue(dispatch.contains("[--mode legacy|snapshot]"))
        XCTAssertTrue(dispatch.contains("[--delivery-items 1000]"))
        XCTAssertTrue(package.contains(#""StorageKit", "IntegrationsKit", "AudioPlaybackKit""#))
        XCTAssertTrue(cli.contains("withTemporaryDirectory(prefix:"))
        XCTAssertTrue(cli.contains("omittingEmptySubsequences: false"))
        XCTAssertTrue(performanceBinary.contains(
            "swift build -c release --product portavoz-cli"))
        XCTAssertTrue(scaleRunner.contains("portavoz_prepare_perf_binary"))
        XCTAssertTrue(scaleRunner.contains(#""$PORTAVOZ_PERF_BINARY" bench-scale"#))
        XCTAssertFalse(scaleRunner.contains("swift build -c release --product portavoz-cli"))
        XCTAssertTrue(scaleRunner.contains(#""buildConfiguration") != "release""#))
        XCTAssertTrue(semanticCLI.contains("let dimension = await embedder.dimension"))
        XCTAssertTrue(semanticCLI.contains("profile: profile"))
        // Variant-count evidence is not interchangeable, so the probe measures
        // the batch path and records how many variants each request carried.
        XCTAssertTrue(semanticCLI.contains(#"case "--variants":"#))
        XCTAssertTrue(semanticCLI.contains("var variants = 1"))
        XCTAssertTrue(semanticCLI.contains("let queryVariants: Int"))
        XCTAssertTrue(semanticCLI.contains("queryVariants: input.options.variants"))
        XCTAssertTrue(semanticCLI.contains("queries,"))
        XCTAssertTrue(dispatch.contains("[--variants 1]"))
        XCTAssertTrue(semanticCLI.contains("mach_timebase_info(&timebase)"))
        XCTAssertTrue(semanticCLI.contains("usage.ri_phys_footprint"))
        XCTAssertTrue(semanticRunner.contains("portavoz_prepare_perf_binary"))
        XCTAssertTrue(semanticRunner.contains(#""$PORTAVOZ_PERF_BINARY" bench-semantic"#))
        XCTAssertFalse(semanticRunner.contains(
            "swift build -c release --product portavoz-cli"))
        XCTAssertTrue(semanticRunner.contains(#"for raw_size in "${checkpoints[@]}""#))
        XCTAssertTrue(semanticRunner.contains(#""$MANIFEST_TOOL" source"#))
        XCTAssertTrue(semanticRunner.contains(#""$MANIFEST_TOOL" snapshot"#))
        XCTAssertTrue(semanticRunner.contains(#""$MANIFEST_TOOL" assemble"#))
        XCTAssertTrue(semanticRunner.contains(
            #"SOURCE_ROOT="${PORTAVOZ_SEMANTIC_SOURCE_ROOT:-$TOOL_ROOT}""#))
        XCTAssertTrue(semanticRunner.contains(
            #"TEMP_ROOT_CANDIDATE="${TMPDIR:-/tmp}""#))
        XCTAssertTrue(semanticRunner.contains(
            "unable to allocate semantic scale workspace"))
        XCTAssertFalse(semanticRunner.contains("/private/tmp"))
        XCTAssertTrue(semanticManifest.contains(#"MANIFEST_KIND = "semantic-scale-run-manifest""#))
        XCTAssertTrue(semanticManifest.contains("identitySHA256"))
        XCTAssertTrue(semanticManifest.contains("retentionEligible"))
        XCTAssertTrue(semanticManifest.contains("legacy-schema-lacks-comparability-identity"))
        XCTAssertTrue(semanticManifest.contains("usedByMeasuredVectors"))
        XCTAssertTrue(semanticManifest.contains(
            #"CONTROL_BASELINE_KIND = "semantic-scale-control-baseline""#))
        XCTAssertTrue(semanticManifest.contains(
            #"CROSS_HOST_MATRIX_KIND = "semantic-scale-cross-host-matrix""#))
        XCTAssertTrue(semanticManifest.contains(
            #""evaluatedStage": "measuredQueries""#))
        XCTAssertTrue(semanticManifest.contains(
            #""diagnosticStages": ["storeOpen", "corpusSeed", "warmupQueries"]"#))
        XCTAssertTrue(semanticRunner.contains(
            #"PORTAVOZ_SEMANTIC_SCALE_VARIANTS"#))
        XCTAssertTrue(semanticControlRunner.contains(
            #"for observation in 1 2 3"#))
        XCTAssertTrue(semanticControlRunner.contains(
            #"PORTAVOZ_SEMANTIC_SCALE_VARIANTS=1"#))
        XCTAssertTrue(semanticControlRunner.contains(
            #"PORTAVOZ_SEMANTIC_SCALE_VARIANTS=3"#))
        XCTAssertTrue(semanticControlRunner.contains(
            #"module.validate_control_baseline"#))
        XCTAssertTrue(semanticControlRunner.contains(
            #"PORTAVOZ_SEMANTIC_SOURCE_ROOT="$ROOT""#))
        XCTAssertTrue(semanticControlRunner.contains(
            #"TEMP_ROOT_CANDIDATE="${TMPDIR:-/tmp}""#))
        XCTAssertTrue(semanticControlRunner.contains(
            "unable to allocate semantic control workspace"))
        XCTAssertFalse(semanticControlRunner.contains("/private/tmp"))
        XCTAssertTrue(semanticControl.contains(
            #""outcome": "current-control-budget-pass""#))
        XCTAssertTrue(semanticControl.contains(
            #""currentControlBudget": "one-host-current-control""#))
        XCTAssertTrue(semanticThreeVariant.contains(
            #""outcome": "stable-three-variant-diagnostic""#))
        XCTAssertTrue(semanticThreeVariant.contains(
            #""currentControlBudget": "none""#))
        XCTAssertTrue(semanticCrossHost.contains(
            #""outcome": "incomplete-required-matrix""#))
        XCTAssertTrue(semanticCrossHost.contains(
            #""observedReceiptCount": 1"#))
        XCTAssertTrue(semanticCrossHost.contains(
            #""crossHostBudget": "none""#))
        XCTAssertTrue(semanticCrossHost.contains(
            #""missing-operating-system:sequoia""#))
        XCTAssertTrue(decisions.contains(
            "## D347 — Cross-host semantic control requires real profile and OS receipts"))
        XCTAssertTrue(waveformCLI.contains("withWaveformTemporaryDirectory"))
        XCTAssertTrue(waveformCLI.contains("FileManager.default.copyItem"))
        XCTAssertTrue(waveformCLI.contains("usage.ri_phys_footprint"))
        XCTAssertTrue(waveformCLI.contains("replacementFingerprint != first.fingerprint"))
        XCTAssertTrue(spotlightCLI.contains("legacyDocuments(store:"))
        XCTAssertTrue(spotlightCLI.contains(#"case "--delivery-items":"#))
        XCTAssertTrue(spotlightCLI.contains("contentSource: \"synthetic-only\""))
        XCTAssertTrue(spotlightCLI.contains("protectionClass: .complete"))
        XCTAssertTrue(spotlightRunner.contains("portavoz_prepare_perf_binary"))
        XCTAssertTrue(spotlightRunner.contains(#""$PORTAVOZ_PERF_BINARY" bench-spotlight"#))
        XCTAssertFalse(spotlightRunner.contains(
            "swift build -c release --product portavoz-cli"))
        XCTAssertTrue(spotlightRunner.contains("for mode in legacy snapshot"))
        XCTAssertTrue(spotlightRunner.contains("resultFingerprintEquivalent"))
        XCTAssertTrue(fixture.contains(#"arguments.contains("-use-temp-store")"#))
        XCTAssertTrue(fixture.contains(#"arguments.contains("-seed-scale")"#))
        XCTAssertTrue(model.contains(#""Meeting Detail First Content""#))
        XCTAssertTrue(detailRunner.contains(#"--template "$template""#))
        XCTAssertTrue(detailRunner.contains(#""$APP" == "/Applications/Portavoz.app""#))
        XCTAssertTrue(detailParser.contains("Trace file had no SwiftUI data"))
        XCTAssertTrue(detailTrace.contains(#"arguments.contains("-use-temp-store")"#))
        XCTAssertTrue(detailTrace.contains(#"arguments.contains("-seed-scale")"#))
        XCTAssertTrue(detailTrace.contains(
            #"arguments.contains("-detail-performance-profile")"#))
        XCTAssertTrue(detailUITests.contains(
            "testTwentyThousandSegmentDetailRendersFromDisposableScaleFixture"))
        XCTAssertTrue(decisions.contains("## D79 — Scale changes follow measured bottlenecks"))
        XCTAssertTrue(decisions.contains("## D80 — Bound interruption scans with prefix evidence"))
        XCTAssertTrue(decisions.contains("## D81 — Bound broad retrieval before vector storage"))
        XCTAssertTrue(decisions.contains("## D82 — Measure semantic cost before changing storage"))
        XCTAssertTrue(decisions.contains("## D83 — Keep exact vectors after the adapter passes"))
        XCTAssertTrue(decisions.contains("## D84 — Vectorize waveform envelopes before caching"))
        XCTAssertTrue(decisions.contains(
            "## D85 — Reconcile Spotlight through a protected measured snapshot"))
        XCTAssertTrue(decisions.contains(
            "## D222 — Freeze Meeting Detail behavior before decomposition"))
        XCTAssertTrue(health.contains("prefixMaximumEnd"))
        XCTAssertTrue(health.contains(
            "guard prefixMaximumEnd[previousIndex] > segment.startTime else { break }"))
        XCTAssertTrue(search.contains("ORDER BY rank"))
        XCTAssertFalse(search.contains("ORDER BY bm25(segmentSearch)"))
        XCTAssertTrue(search.contains("Row.fetchCursor"))
        XCTAssertTrue(search.contains("withUnsafeData(atIndex: 0)"))
        XCTAssertTrue(search.contains("vDSP_dotpr"))
        XCTAssertTrue(search.contains("segment.meetingID NOT IN"))
        XCTAssertTrue(search.contains("ORDER BY segment.rowid ASC"))
        XCTAssertTrue(search.contains("candidates.count == limit"))
        XCTAssertTrue(search.contains("Self.semanticHits("))
        XCTAssertTrue(search.contains("stride(from: 0, to: rowIDs.count, by: 500)"))
        XCTAssertTrue(search.contains("private struct SemanticQueryBatch: Sendable"))
        XCTAssertTrue(search.contains("let batch = SemanticQueryBatch("))
        XCTAssertTrue(search.contains("semanticCandidates(for: batch, in: database)"))
        // Every query variant is scored inside one corpus traversal: a single
        // cursor, one bounded candidate list per variant.
        XCTAssertEqual(
            search.components(separatedBy: "Row.fetchCursor").count - 1,
            1,
            "the semantic scan opens exactly one cursor")
        XCTAssertTrue(search.contains("into candidates: inout [SemanticCandidate]"))
        XCTAssertTrue(search.contains("_ queries: [[Float]]"))
        XCTAssertTrue(ask.contains("public static func retrieveLexical"))
        XCTAssertTrue(ask.contains("guard terms.count <= 8"))
        XCTAssertTrue(ask.contains("1.0 / Double(60 + rank)"))
        XCTAssertTrue(cli.contains("LocalAskMeetingRetrieval.retrieveLexical"))
        XCTAssertTrue(waveform.contains("vDSP_maxmgv"))
        XCTAssertFalse(waveform.contains("WaveformCache"))
        XCTAssertTrue(spotlightProjection.contains("func spotlightDocuments()"))
        XCTAssertTrue(spotlightProjection.contains("func spotlightIndexSnapshot()"))
        XCTAssertTrue(spotlightProjection.contains("ROW_NUMBER() OVER"))
        XCTAssertTrue(spotlightProjection.contains("segmentRank <= 40"))
        XCTAssertTrue(spotlightIndexer.contains("actor SpotlightIndexer"))
        XCTAssertTrue(spotlightIndexer.contains(#"indexName = "app.portavoz.search.v3""#))
        XCTAssertTrue(spotlightIndexer.contains("case meetingDocuments"))
        XCTAssertTrue(spotlightIndexer.contains("case appEntities"))
        XCTAssertTrue(spotlightIndexer.contains("index.indexAppEntities("))
        XCTAssertTrue(spotlightIndexer.contains("index.indexSearchableItems("))
        XCTAssertTrue(spotlightIndexer.contains("protectionClass: .complete"))
        XCTAssertTrue(spotlightIndexer.contains("index.beginBatch()"))
        XCTAssertTrue(spotlightIndexer.contains("endBatch(withClientState:"))
        XCTAssertTrue(spotlightIndexer.contains("retryDelays"))
        XCTAssertFalse(spotlightIndexer.contains("outboxEvent"))
        XCTAssertTrue(services.contains("@ObservationIgnored let spotlightIndexer"))
        XCTAssertTrue(services.contains("func requestSearchReconciliation()"))
        XCTAssertFalse(services.contains("libraryVersion"))
        XCTAssertFalse(content.contains("libraryVersion"))

        let scale = try Self.jsonObject(
            at: "docs/evidence/scale-baseline-20260716.json")
        XCTAssertEqual(scale["buildConfiguration"] as? String, "release")
        let library = try XCTUnwrap(scale["library"] as? [[String: Any]])
        XCTAssertEqual(library.compactMap { $0["totalSegments"] as? Int }, [
            1_000, 10_000, 50_000, 100_000,
        ])
        let meetings = try XCTUnwrap(scale["longMeetings"] as? [[String: Any]])
        XCTAssertEqual(meetings.compactMap { $0["durationMinutes"] as? Int }, [30, 120, 480])

        let detail = try Self.jsonObject(
            at: "docs/evidence/detail-ui-baseline-20260716.json")
        let reproduction = try XCTUnwrap(detail["reproduction"] as? [String: Any])
        XCTAssertEqual(reproduction["releaseApplicationProtected"] as? Bool, true)
        let firstContent = try XCTUnwrap(detail["firstContent"] as? [String: Any])
        XCTAssertGreaterThan(firstContent["durationMilliseconds"] as? Double ?? 0, 0)
        let swiftUI = try XCTUnwrap(detail["swiftUI"] as? [String: Any])
        let status = try XCTUnwrap(swiftUI["status"] as? String)
        XCTAssertTrue(["captured", "unavailable-toolchain"].contains(status))
        if status == "unavailable-toolchain" {
            XCTAssertFalse((detail["limitations"] as? [String] ?? []).isEmpty)
        }

        let afterScale = try Self.jsonObject(
            at: "docs/evidence/scale-baseline-20260716-after-health.json")
        let afterMeetings = try XCTUnwrap(afterScale["longMeetings"] as? [[String: Any]])
        let beforeFiveThousand = try XCTUnwrap(meetings.first {
            $0["segmentCount"] as? Int == 5_000
        })
        let afterFiveThousand = try XCTUnwrap(afterMeetings.first {
            $0["segmentCount"] as? Int == 5_000
        })
        XCTAssertLessThan(
            try Self.p95(in: afterFiveThousand, key: "meetingHealth"),
            try Self.p95(in: beforeFiveThousand, key: "meetingHealth") / 10)

        let afterDetail = try Self.jsonObject(
            at: "docs/evidence/detail-ui-baseline-20260716-after-health.json")
        let afterFirstContent = try XCTUnwrap(afterDetail["firstContent"] as? [String: Any])
        XCTAssertLessThan(afterFirstContent["durationMilliseconds"] as? Double ?? .infinity, 300)
        let afterResponsiveness = try XCTUnwrap(
            afterDetail["responsiveness"] as? [String: Any])
        XCTAssertEqual(afterResponsiveness["potentialHangCount"] as? Int, 0)

        let interactionContract = try Self.jsonObject(
            at: "docs/evidence/meeting-detail-interaction-contract.json")
        XCTAssertEqual(
            interactionContract["kind"] as? String,
            "meeting-detail-interaction-baseline")
        XCTAssertEqual(
            (interactionContract["interactionSignals"] as? [[String: Any]])?.count,
            470)
        XCTAssertEqual(
            (interactionContract["featureOwnership"] as? [[String: Any]])?.count,
            15)

        let detailZero = try Self.jsonObject(
            at: "docs/evidence/meeting-detail-performance-baseline-20260801.json")
        let detailZeroReproduction = try XCTUnwrap(
            detailZero["reproduction"] as? [String: Any])
        XCTAssertEqual(detailZeroReproduction["releaseApplicationProtected"] as? Bool, true)
        XCTAssertEqual(detailZeroReproduction["userLibraryAccess"] as? String, "none")
        let detailZeroProfiles = try XCTUnwrap(
            detailZero["profiles"] as? [[String: Any]])
        XCTAssertEqual(
            detailZeroProfiles.compactMap {
                ($0["fixture"] as? [String: Any])?["segmentCount"] as? Int
            },
            [5_000, 20_000])
        for profile in detailZeroProfiles {
            let interaction = try XCTUnwrap(profile["interaction"] as? [String: Any])
            XCTAssertEqual(interaction["sampleCount"] as? Int, 5)
            let hitches = try XCTUnwrap(profile["animationHitches"] as? [String: Any])
            XCTAssertEqual(hitches["count"] as? Int, 0)
            let responsiveness = try XCTUnwrap(
                profile["responsiveness"] as? [String: Any])
            XCTAssertEqual(responsiveness["potentialHangCount"] as? Int, 0)
        }

        let afterSearch = try Self.jsonObject(
            at: "docs/evidence/scale-baseline-20260716-after-search.json")
        let searchLibrary = try XCTUnwrap(afterSearch["library"] as? [[String: Any]])
        let beforeHundredThousand = try XCTUnwrap(
            try XCTUnwrap(afterScale["library"] as? [[String: Any]]).first {
                $0["totalSegments"] as? Int == 100_000
            })
        let afterHundredThousand = try XCTUnwrap(searchLibrary.first {
            $0["totalSegments"] as? Int == 100_000
        })
        let beforeBroad = try Self.p95(
            in: beforeHundredThousand, key: "questionRetrieval")
        let afterBroad = try Self.p95(
            in: afterHundredThousand, key: "questionRetrieval")
        XCTAssertLessThan(afterBroad, 100)
        XCTAssertLessThan(afterBroad, beforeBroad * 0.75)
        XCTAssertLessThan(
            try Self.p95(in: afterHundredThousand, key: "exactSearch"),
            50)

        let semantic = try Self.jsonObject(
            at: "docs/evidence/semantic-scale-baseline-20260716.json")
        XCTAssertEqual(semantic["buildConfiguration"] as? String, "release")
        let semanticConfiguration = try XCTUnwrap(
            semantic["configuration"] as? [String: Any])
        XCTAssertEqual(semanticConfiguration["embeddingDimension"] as? Int, 512)
        XCTAssertEqual(semanticConfiguration["measurementRuns"] as? Int, 20)
        let semanticCheckpoints = try XCTUnwrap(
            semantic["checkpoints"] as? [[String: Any]])
        XCTAssertEqual(semanticCheckpoints.compactMap { $0["totalSegments"] as? Int }, [
            1_000, 10_000, 50_000, 100_000,
        ])
        let semanticHundredThousand = try XCTUnwrap(semanticCheckpoints.last)
        XCTAssertGreaterThan(
            try Self.p95(in: semanticHundredThousand, key: "wallTime"),
            100)
        XCTAssertGreaterThan(
            try Self.p95(in: semanticHundredThousand, key: "processCPUTime"),
            100)
        let incrementalFootprint = try XCTUnwrap(
            semanticHundredThousand["incrementalPeakPhysicalFootprint"] as? [String: Any])
        XCTAssertLessThan(
            incrementalFootprint["p95Bytes"] as? Int ?? .max,
            64 * 1_048_576)

        let afterSemantic = try Self.jsonObject(
            at: "docs/evidence/semantic-scale-after-adapter-20260717.json")
        XCTAssertEqual(afterSemantic["buildConfiguration"] as? String, "release")
        let afterSemanticConfiguration = try XCTUnwrap(
            afterSemantic["configuration"] as? [String: Any])
        XCTAssertEqual(afterSemanticConfiguration["embeddingDimension"] as? Int, 512)
        XCTAssertEqual(afterSemanticConfiguration["measurementRuns"] as? Int, 20)
        let afterSemanticCheckpoints = try XCTUnwrap(
            afterSemantic["checkpoints"] as? [[String: Any]])
        XCTAssertEqual(
            afterSemanticCheckpoints.compactMap { $0["totalSegments"] as? Int },
            [1_000, 10_000, 50_000, 100_000])
        let afterSemanticHundredThousand = try XCTUnwrap(afterSemanticCheckpoints.last)
        let beforeSemanticWall = try Self.p95(
            in: semanticHundredThousand, key: "wallTime")
        let afterSemanticWall = try Self.p95(
            in: afterSemanticHundredThousand, key: "wallTime")
        let beforeSemanticCPU = try Self.p95(
            in: semanticHundredThousand, key: "processCPUTime")
        let afterSemanticCPU = try Self.p95(
            in: afterSemanticHundredThousand, key: "processCPUTime")
        XCTAssertLessThan(afterSemanticWall, 100)
        XCTAssertLessThan(afterSemanticCPU, 100)
        XCTAssertLessThan(afterSemanticWall, beforeSemanticWall / 3)
        XCTAssertLessThan(afterSemanticCPU, beforeSemanticCPU / 3)
        let afterPeakFootprint = try XCTUnwrap(
            afterSemanticHundredThousand["peakPhysicalFootprint"] as? [String: Any])
        XCTAssertLessThan(
            afterPeakFootprint["p95Bytes"] as? Int ?? .max,
            24 * 1_048_576)

        let waveformBaseline = try Self.jsonObject(
            at: "docs/evidence/waveform-scale-baseline-20260717.json")
        let waveformAfter = try Self.jsonObject(
            at: "docs/evidence/waveform-scale-after-accelerate-20260717.json")
        XCTAssertEqual(waveformBaseline["buildConfiguration"] as? String, "release")
        XCTAssertEqual(waveformAfter["buildConfiguration"] as? String, "release")
        let waveformConfiguration = try XCTUnwrap(
            waveformAfter["configuration"] as? [String: Any])
        XCTAssertEqual(waveformConfiguration["repeatedRuns"] as? Int, 20)
        XCTAssertEqual(waveformConfiguration["bucketCount"] as? Int, 600)
        let waveformSource = try XCTUnwrap(waveformAfter["source"] as? [String: Any])
        XCTAssertEqual(waveformSource["copiedToScratch"] as? Bool, true)
        XCTAssertEqual(waveformSource["channelCount"] as? Int, 2)
        XCTAssertGreaterThan(waveformSource["durationSeconds"] as? Double ?? 0, 3_300)
        XCTAssertGreaterThan(waveformSource["totalBytes"] as? Int ?? 0, 600_000_000)
        let waveformBeforeFirst = try XCTUnwrap(
            waveformBaseline["firstGeneration"] as? [String: Any])
        let waveformAfterFirst = try XCTUnwrap(
            waveformAfter["firstGeneration"] as? [String: Any])
        XCTAssertEqual(
            waveformAfterFirst["resultFingerprint"] as? String,
            waveformBeforeFirst["resultFingerprint"] as? String)
        XCTAssertLessThan(
            waveformAfterFirst["wallMilliseconds"] as? Double ?? .infinity,
            150)
        XCTAssertLessThan(
            waveformAfterFirst["processCPUMilliseconds"] as? Double ?? .infinity,
            120)
        let waveformBeforeRepeat = try XCTUnwrap(
            waveformBaseline["repeatedGeneration"] as? [String: Any])
        let waveformAfterRepeat = try XCTUnwrap(
            waveformAfter["repeatedGeneration"] as? [String: Any])
        let waveformBeforeWall = try Self.p95(in: waveformBeforeRepeat, key: "wallTime")
        let waveformAfterWall = try Self.p95(in: waveformAfterRepeat, key: "wallTime")
        let waveformBeforeCPU = try Self.p95(
            in: waveformBeforeRepeat, key: "processCPUTime")
        let waveformAfterCPU = try Self.p95(
            in: waveformAfterRepeat, key: "processCPUTime")
        XCTAssertGreaterThan(waveformBeforeWall, 500)
        XCTAssertLessThan(waveformAfterWall, 100)
        XCTAssertLessThan(waveformAfterCPU, 100)
        XCTAssertLessThan(waveformAfterWall, waveformBeforeWall / 8)
        XCTAssertLessThan(waveformAfterCPU, waveformBeforeCPU / 8)
        let waveformFootprint = try XCTUnwrap(
            waveformAfterRepeat["incrementalPeakPhysicalFootprint"] as? [String: Any])
        XCTAssertLessThan(
            waveformFootprint["p95Bytes"] as? Int ?? .max,
            2 * 1_048_576)
        let waveformInvalidation = try XCTUnwrap(
            waveformAfter["invalidation"] as? [String: Any])
        XCTAssertEqual(waveformInvalidation["resultChanged"] as? Bool, true)
        XCTAssertNotEqual(
            waveformInvalidation["replacementFingerprint"] as? String,
            waveformAfterFirst["resultFingerprint"] as? String)

        let spotlight = try Self.jsonObject(
            at: "docs/evidence/spotlight-scale-after-snapshot-20260717.json")
        XCTAssertEqual(spotlight["buildConfiguration"] as? String, "release")
        let legacySpotlight = try XCTUnwrap(
            spotlight["legacyCheckpoints"] as? [[String: Any]])
        let snapshotSpotlight = try XCTUnwrap(
            spotlight["snapshotCheckpoints"] as? [[String: Any]])
        XCTAssertEqual(
            legacySpotlight.compactMap { $0["meetingCount"] as? Int },
            [1_000, 10_000, 100_000])
        XCTAssertEqual(
            snapshotSpotlight.compactMap { $0["meetingCount"] as? Int },
            [1_000, 10_000, 100_000])
        let legacySpotlightHundredThousand = try XCTUnwrap(legacySpotlight.last)
        let snapshotSpotlightHundredThousand = try XCTUnwrap(snapshotSpotlight.last)
        let legacySpotlightWall = try Self.p95(
            in: legacySpotlightHundredThousand, key: "projection", nestedKey: "wallTime")
        let snapshotSpotlightWall = try Self.p95(
            in: snapshotSpotlightHundredThousand, key: "projection", nestedKey: "wallTime")
        let snapshotSpotlightCPU = try Self.p95(
            in: snapshotSpotlightHundredThousand,
            key: "projection",
            nestedKey: "processCPUTime")
        XCTAssertGreaterThan(legacySpotlightWall, 20_000)
        XCTAssertLessThan(snapshotSpotlightWall, 500)
        XCTAssertLessThan(snapshotSpotlightCPU, 500)
        XCTAssertLessThan(snapshotSpotlightWall, legacySpotlightWall / 40)
        let snapshotSpotlightResources = try XCTUnwrap(
            snapshotSpotlightHundredThousand["projection"] as? [String: Any])
        XCTAssertLessThan(
            try Self.p95Bytes(
                in: snapshotSpotlightResources,
                key: "peakPhysicalFootprint"),
            160 * 1_048_576)
        XCTAssertLessThan(
            try Self.p95Bytes(
                in: snapshotSpotlightResources,
                key: "incrementalPeakPhysicalFootprint"),
            96 * 1_048_576)
        let spotlightEquivalence = try XCTUnwrap(
            spotlight["equivalence"] as? [[String: Any]])
        XCTAssertTrue(spotlightEquivalence.allSatisfy {
            $0["resultFingerprintEquivalent"] as? Bool == true
        })
        let spotlightDelivery = try XCTUnwrap(
            spotlight["syntheticDelivery"] as? [String: Any])
        XCTAssertEqual(spotlightDelivery["status"] as? String, "completed")
        XCTAssertEqual(spotlightDelivery["syntheticItemCount"] as? Int, 1_000)
        XCTAssertEqual(spotlightDelivery["protection"] as? String, "complete")
        XCTAssertEqual(spotlightDelivery["contentSource"] as? String, "synthetic-only")
        XCTAssertEqual(spotlightDelivery["cleanupSucceeded"] as? Bool, true)
    }
}
