import ApplicationKit
import PortavozCore
import XCTest

final class RetrievalSemanticBoundaryPreflightTests: XCTestCase {
    func testSharedBilingualProposalIsAdmittedWithCanonicalIdentity() throws {
        let first = try RetrievalSemanticBoundaryPreflight.admit(proposal(
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .shared(
                    profile: profile("shared"),
                    supportedLanguages: ["es", "EN"],
                    minimumCosineSimilarity: 0.7))))
        let reordered = try RetrievalSemanticBoundaryPreflight.admit(proposal(
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .shared(
                    profile: profile("shared"),
                    supportedLanguages: ["en", "es"],
                    minimumCosineSimilarity: 0.7))))

        XCTAssertEqual(
            first.contractVersion,
            "semantic-boundary-preflight-v1")
        XCTAssertEqual(first.candidateIdentifier, "semantic-boundary-v1")
        XCTAssertEqual(first.candidateRevision, 1)
        XCTAssertEqual(first.scope, .benchmarkOnly)
        XCTAssertEqual(first.proposalFingerprint.count, 64)
        XCTAssertEqual(first.proposalFingerprint, reordered.proposalFingerprint)
    }

    func testPartitionedLanguageProfilesForceCanonicalLanguageIdentity() throws {
        let english = RetrievalSemanticBoundaryProposal.LanguageProfile(
            language: "en",
            profile: profile("apple-sentence-en"),
            minimumCosineSimilarity: 0.61)
        let spanish = RetrievalSemanticBoundaryProposal.LanguageProfile(
            language: "es",
            profile: profile("apple-sentence-es"),
            minimumCosineSimilarity: 0.57)
        let first = try RetrievalSemanticBoundaryPreflight.admit(proposal(
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .partitionedByLanguage([spanish, english]))))
        let reordered = try RetrievalSemanticBoundaryPreflight.admit(proposal(
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .partitionedByLanguage([english, spanish]))))
        let recalibratedSpanish = try RetrievalSemanticBoundaryPreflight.admit(
            proposal(boundarySignal: .semanticSimilarity(
                embeddingSpace: .partitionedByLanguage([
                    english,
                    .init(
                        language: "es",
                        profile: profile("apple-sentence-es"),
                        minimumCosineSimilarity: 0.58)
                ]))))

        XCTAssertEqual(first.proposalFingerprint, reordered.proposalFingerprint)
        XCTAssertNotEqual(
            first.proposalFingerprint,
            recalibratedSpanish.proposalFingerprint)
    }

    func testFingerprintChangesWithEveryBehavioralFence() throws {
        let baseline = try RetrievalSemanticBoundaryPreflight.admit(proposal())
        let threshold = try RetrievalSemanticBoundaryPreflight.admit(proposal(
            boundarySignal: sharedSignal(threshold: 0.71)))
        let tighterResources = try RetrievalSemanticBoundaryPreflight.admit(
            proposal(resourceBounds: .init(
                maximumTurns: 3,
                maximumCharacters: 899,
                maximumDuration: 45,
                maximumGap: 2.5)))
        let revised = try RetrievalSemanticBoundaryPreflight.admit(proposal(
            candidateRevision: 2))
        let changedProfile = try RetrievalSemanticBoundaryPreflight.admit(proposal(
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .shared(
                    profile: profile("shared-v2"),
                    supportedLanguages: ["en", "es"],
                    minimumCosineSimilarity: 0.7))))
        let partitioned = try RetrievalSemanticBoundaryPreflight.admit(proposal(
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .partitionedByLanguage([
                    .init(
                        language: "en",
                        profile: profile("sentence-en"),
                        minimumCosineSimilarity: 0.7),
                    .init(
                        language: "es",
                        profile: profile("sentence-es"),
                        minimumCosineSimilarity: 0.7)
                ]))))

        XCTAssertEqual(Set([
            baseline.proposalFingerprint,
            threshold.proposalFingerprint,
            tighterResources.proposalFingerprint,
            revised.proposalFingerprint,
            changedProfile.proposalFingerprint,
            partitioned.proposalFingerprint
        ]).count, 6)
    }

    func testEquivalentNegativeZeroDoesNotForkCandidateIdentity() throws {
        let positive = try RetrievalSemanticBoundaryPreflight.admit(proposal(
            resourceBounds: .init(
                maximumTurns: 3,
                maximumCharacters: 900,
                maximumDuration: 45,
                maximumGap: 0),
            boundarySignal: sharedSignal(threshold: 0)))
        let negative = try RetrievalSemanticBoundaryPreflight.admit(proposal(
            resourceBounds: .init(
                maximumTurns: 3,
                maximumCharacters: 900,
                maximumDuration: 45,
                maximumGap: -0.0),
            boundarySignal: sharedSignal(threshold: -0.0)))

        XCTAssertEqual(positive.proposalFingerprint, negative.proposalFingerprint)
    }

    func testAdmissionRejectsServingFragmentOverlapAndFlattening() {
        assertError(.productServingNotAllowed, proposal(scope: .productServing))
        assertError(
            .canonicalSourceFragmentationNotRepresentable,
            proposal(canonicalUnit: .sentenceFragment))
        assertError(
            .overlappingSourcesNotAllowed,
            proposal(sourceReuse: .overlapping))
        assertError(
            .actorTopologyMustBePreserved,
            proposal(actorTopology: .flattened))
    }

    func testAdmissionRejectsInvalidCandidateIdentity() {
        for identifier in [
            "", "Semantic-boundary", "semantic boundary", "-candidate",
            String(repeating: "a", count: 65)
        ] {
            assertError(
                .invalidCandidateIdentifier,
                proposal(candidateIdentifier: identifier))
        }
        assertError(.invalidCandidateRevision, proposal(candidateRevision: 0))
    }

    func testAdmissionRejectsInvalidOrLooserResourceBounds() {
        let invalid = [
            RetrievalSemanticBoundaryProposal.ResourceBounds(
                maximumTurns: 1,
                maximumCharacters: 900,
                maximumDuration: 45,
                maximumGap: 2.5),
            RetrievalSemanticBoundaryProposal.ResourceBounds(
                maximumTurns: 3,
                maximumCharacters: 0,
                maximumDuration: 45,
                maximumGap: 2.5),
            RetrievalSemanticBoundaryProposal.ResourceBounds(
                maximumTurns: 3,
                maximumCharacters: 900,
                maximumDuration: .infinity,
                maximumGap: 2.5),
            RetrievalSemanticBoundaryProposal.ResourceBounds(
                maximumTurns: 3,
                maximumCharacters: 900,
                maximumDuration: 45,
                maximumGap: -0.1)
        ]
        for bounds in invalid {
            assertError(.invalidResourceBounds, proposal(resourceBounds: bounds))
        }

        let looser = [
            RetrievalSemanticBoundaryProposal.ResourceBounds(
                maximumTurns: 4,
                maximumCharacters: 900,
                maximumDuration: 45,
                maximumGap: 2.5),
            RetrievalSemanticBoundaryProposal.ResourceBounds(
                maximumTurns: 3,
                maximumCharacters: 901,
                maximumDuration: 45,
                maximumGap: 2.5),
            RetrievalSemanticBoundaryProposal.ResourceBounds(
                maximumTurns: 3,
                maximumCharacters: 900,
                maximumDuration: 45.1,
                maximumGap: 2.5),
            RetrievalSemanticBoundaryProposal.ResourceBounds(
                maximumTurns: 3,
                maximumCharacters: 900,
                maximumDuration: 45,
                maximumGap: 2.6)
        ]
        for bounds in looser {
            assertError(
                .resourceBoundsExceedComparableCandidate,
                proposal(resourceBounds: bounds))
        }
    }

    func testAdmissionRejectsUnversionedSentenceTokenizer() {
        assertError(
            .unversionedBoundarySignal,
            proposal(boundarySignal: .operatingSystemSentenceTokenizer))
    }

    func testAdmissionRejectsInvalidProfileAndCosineThreshold() {
        let invalidProfile = SemanticEmbeddingProfile(
            modelIdentifier: "",
            modelRevision: 1,
            vectorDimension: 512,
            pipelineIdentifier: "l2",
            pipelineRevision: 1,
            vectorSchemaVersion: 1)
        assertError(.invalidEmbeddingProfile, proposal(
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .shared(
                    profile: invalidProfile,
                    supportedLanguages: ["en", "es"],
                    minimumCosineSimilarity: 0.7))))
        for threshold in [Double.nan, Double.infinity, -1.01, 1.01] {
            assertError(.invalidCosineThreshold, proposal(
                boundarySignal: sharedSignal(threshold: threshold)))
        }
    }

    func testAdmissionRequiresUnambiguousEnglishAndSpanishCoverage() {
        assertError(.invalidLanguage("en-US"), proposal(
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .shared(
                    profile: profile("shared"),
                    supportedLanguages: ["en-US", "es"],
                    minimumCosineSimilarity: 0.7))))
        assertError(.duplicateLanguage("en"), proposal(
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .shared(
                    profile: profile("shared"),
                    supportedLanguages: ["en", "EN", "es"],
                    minimumCosineSimilarity: 0.7))))
        assertError(.missingRequiredLanguage("es"), proposal(
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .shared(
                    profile: profile("shared"),
                    supportedLanguages: ["en"],
                    minimumCosineSimilarity: 0.7))))
        assertError(.tooManyLanguages, proposal(
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .shared(
                    profile: profile("shared"),
                    supportedLanguages: Array(repeating: "en", count: 17),
                    minimumCosineSimilarity: 0.7))))
    }

    func testPartitionedLanguagesCannotPretendOneProfileIsTwoSpaces() {
        let reused = profile("language-specific")
        assertError(.reusedPartitionedProfile("es"), proposal(
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .partitionedByLanguage([
                    .init(
                        language: "en",
                        profile: reused,
                        minimumCosineSimilarity: 0.7),
                    .init(
                        language: "es",
                        profile: reused,
                        minimumCosineSimilarity: 0.7)
                ]))))
    }

    private func proposal(
        candidateIdentifier: String = "semantic-boundary-v1",
        candidateRevision: Int = 1,
        scope: RetrievalSemanticBoundaryProposal.Scope = .benchmarkOnly,
        canonicalUnit: RetrievalSemanticBoundaryProposal.CanonicalUnit = .completeTurn,
        sourceReuse: RetrievalSemanticBoundaryProposal.SourceReuse = .nonOverlapping,
        actorTopology: RetrievalSemanticBoundaryProposal.ActorTopology = .preserved,
        resourceBounds: RetrievalSemanticBoundaryProposal.ResourceBounds =
            .conversationWindowCeiling,
        boundarySignal: RetrievalSemanticBoundaryProposal.BoundarySignal? = nil
    ) -> RetrievalSemanticBoundaryProposal {
        RetrievalSemanticBoundaryProposal(
            candidateIdentifier: candidateIdentifier,
            candidateRevision: candidateRevision,
            scope: scope,
            canonicalUnit: canonicalUnit,
            sourceReuse: sourceReuse,
            actorTopology: actorTopology,
            resourceBounds: resourceBounds,
            boundarySignal: boundarySignal ?? sharedSignal(threshold: 0.7))
    }

    private func sharedSignal(
        threshold: Double
    ) -> RetrievalSemanticBoundaryProposal.BoundarySignal {
        .semanticSimilarity(
            embeddingSpace: .shared(
                profile: profile("shared"),
                supportedLanguages: ["en", "es"],
                minimumCosineSimilarity: threshold))
    }

    private func profile(_ identifier: String) -> SemanticEmbeddingProfile {
        SemanticEmbeddingProfile(
            modelIdentifier: identifier,
            modelRevision: 2,
            vectorDimension: 512,
            pipelineIdentifier: "sentence-l2",
            pipelineRevision: 1,
            vectorSchemaVersion: 1)
    }

    private func assertError(
        _ expected: RetrievalSemanticBoundaryPreflightError,
        _ proposal: RetrievalSemanticBoundaryProposal,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try RetrievalSemanticBoundaryPreflight.admit(proposal),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? RetrievalSemanticBoundaryPreflightError,
                expected,
                file: file,
                line: line)
        }
    }
}
