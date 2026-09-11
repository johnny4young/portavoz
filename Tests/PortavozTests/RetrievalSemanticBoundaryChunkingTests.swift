import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class RetrievalSemanticBoundaryChunkingTests: XCTestCase {
    func testRelatedAdjacentTurnsJoinWithExactTopologyAndIdentity() async throws {
        let meetingID = meeting(1)
        let speakers = testSpeakers(meetingID: meetingID)
        let segments = [
            segment(
                1, meetingID: meetingID, speakerID: speakers[0].id,
                text: "What ships Friday?", language: "en-US", start: 0),
            segment(
                2, meetingID: meetingID, speakerID: speakers[1].id,
                text: "The local search candidate.", language: "en", start: 1),
            segment(
                3, meetingID: meetingID, speakerID: speakers[0].id,
                text: "Keep the citations exact.", language: "en_GB", start: 2)
        ]
        let embedding = TestSemanticBoundaryEmbedding(
            proposal: proposal(),
            vectorsByText: [
                segments[0].text: [1, 0],
                segments[1].text: [0.98, 0.02],
                segments[2].text: [0.97, 0.03]
            ])

        let result = try await chunks(
            meetingID: meetingID,
            segments: segments,
            speakers: speakers,
            embedding: embedding)

        let chunk = try XCTUnwrap(result.chunks.first)
        XCTAssertEqual(result.chunks.count, 1)
        XCTAssertEqual(chunk.sourceSegmentIDs, segments.map(\.id))
        XCTAssertEqual(chunk.turns.map(\.sourceSegmentIDs), segments.map { [$0.id] })
        XCTAssertEqual(chunk.turns.map(\.speakerIDs), [
            [speakers[0].id], [speakers[1].id], [speakers[0].id]
        ])
        XCTAssertEqual(chunk.speakerIDs, [speakers[0].id, speakers[1].id])
        XCTAssertTrue(
            result.adapterIdentifier.hasPrefix(
                RetrievalSemanticBoundaryChunker.adapterPrefix))
        XCTAssertEqual(
            result.adapterIdentifier.count,
            RetrievalSemanticBoundaryChunker.adapterPrefix.count + 64)
        XCTAssertEqual(result.diagnostics.turnCount, 3)
        XCTAssertEqual(result.diagnostics.vectorizedTurnCount, 3)
        XCTAssertEqual(result.diagnostics.joinedBoundaryCount, 2)
        XCTAssertEqual(result.diagnostics.languageTransitionBoundaryCount, 0)
        XCTAssertEqual(result.diagnostics.unavailableLanguageBoundaryCount, 0)
        XCTAssertEqual(result.diagnostics.resourceBoundaryCount, 0)
        XCTAssertEqual(result.diagnostics.similarityBoundaryCount, 0)
        let requests = await embedding.requests
        XCTAssertEqual(requests.map(\.language), ["en", "en", "en"])
        XCTAssertEqual(requests.map(\.text), segments.map(\.text))
    }

    func testLowSimilarityCreatesABoundary() async throws {
        let meetingID = meeting(2)
        let speakers = testSpeakers(meetingID: meetingID)
        let segments = [
            segment(
                1, meetingID: meetingID, speakerID: speakers[0].id,
                text: "alpha", start: 0),
            segment(
                2, meetingID: meetingID, speakerID: speakers[1].id,
                text: "orthogonal", start: 1)
        ]
        let embedding = TestSemanticBoundaryEmbedding(
            proposal: proposal(),
            vectorsByText: ["alpha": [1, 0], "orthogonal": [0, 1]])

        let result = try await chunks(
            meetingID: meetingID,
            segments: segments,
            speakers: speakers,
            embedding: embedding)

        XCTAssertEqual(result.chunks.map(\.sourceSegmentIDs), segments.map { [$0.id] })
        XCTAssertEqual(result.diagnostics.similarityBoundaryCount, 1)
        XCTAssertEqual(result.diagnostics.joinedBoundaryCount, 0)
    }

    func testLanguageTransitionSplitsDistinctSpacesWithoutCrossComparison() async throws {
        let meetingID = meeting(3)
        let speakers = testSpeakers(meetingID: meetingID)
        let segments = [
            segment(
                1, meetingID: meetingID, speakerID: speakers[0].id,
                text: "English evidence", language: "en", start: 0),
            segment(
                2, meetingID: meetingID, speakerID: speakers[1].id,
                text: "Evidencia en espanol", language: "es-CO", start: 1),
            segment(
                3, meetingID: meetingID, speakerID: speakers[0].id,
                text: "Mas evidencia", language: "es", start: 2)
        ]
        let embedding = TestSemanticBoundaryEmbedding(
            proposal: proposal(),
            vectorsByText: [
                segments[0].text: [1, 0],
                segments[1].text: [1, 0, 0],
                segments[2].text: [0.99, 0.01, 0]
            ])

        let result = try await chunks(
            meetingID: meetingID,
            segments: segments,
            speakers: speakers,
            embedding: embedding)

        XCTAssertEqual(result.chunks.map(\.sourceSegmentIDs), [
            [segments[0].id], [segments[1].id, segments[2].id]
        ])
        XCTAssertEqual(result.diagnostics.languageTransitionBoundaryCount, 1)
        XCTAssertEqual(result.diagnostics.joinedBoundaryCount, 1)
        XCTAssertEqual(result.diagnostics.similarityBoundaryCount, 0)
        let requests = await embedding.requests
        XCTAssertEqual(requests.map(\.language), ["en", "es", "es"])
    }

    func testUnknownAndMixedTurnsStayIsolatedAndAreNeverVectorized() async throws {
        let meetingID = meeting(4)
        let speakers = testSpeakers(meetingID: meetingID)
        let segments = [
            segment(
                1, meetingID: meetingID, speakerID: speakers[0].id,
                text: "known before", language: "en", start: 0),
            segment(
                2, meetingID: meetingID, speakerID: speakers[1].id,
                text: "mixed first", language: "en", start: 1),
            segment(
                3, meetingID: meetingID, speakerID: speakers[1].id,
                text: "mixed second", language: "es", start: 2),
            segment(
                4, meetingID: meetingID, speakerID: speakers[0].id,
                text: "known after", language: "en", start: 3)
        ]
        let embedding = TestSemanticBoundaryEmbedding(
            proposal: proposal(),
            vectorsByText: [
                segments[0].text: [1, 0],
                segments[3].text: [1, 0]
            ])

        let result = try await chunks(
            meetingID: meetingID,
            segments: segments,
            speakers: speakers,
            embedding: embedding)

        XCTAssertEqual(result.chunks.map(\.sourceSegmentIDs), [
            [segments[0].id],
            [segments[1].id, segments[2].id],
            [segments[3].id]
        ])
        XCTAssertEqual(result.diagnostics.turnCount, 3)
        XCTAssertEqual(result.diagnostics.vectorizedTurnCount, 2)
        XCTAssertEqual(result.diagnostics.unavailableLanguageBoundaryCount, 2)
        let requests = await embedding.requests
        XCTAssertEqual(requests.map(\.text), [segments[0].text, segments[3].text])
    }

    func testSharedSpaceProposalIsRejectedByConcreteCandidate() async throws {
        let meetingID = meeting(5)
        let source = segment(1, meetingID: meetingID, text: "evidence", start: 0)
        let embedding = TestSemanticBoundaryEmbedding(
            proposal: sharedProposal(),
            vectorsByText: [source.text: [1, 0]])

        await assertChunkingError(
            embedding: embedding,
            meetingID: meetingID,
            segments: [source],
            expected: .sharedEmbeddingSpaceNotImplemented)
    }

    func testVectorsFailClosedOnLanguageProfileDimensionAndNumericIdentity() async {
        let meetingID = meeting(6)
        let source = segment(1, meetingID: meetingID, text: "evidence", start: 0)
        let cases: [(RetrievalSemanticBoundaryVector, RetrievalSemanticBoundaryChunkingError)] = [
            (
                RetrievalSemanticBoundaryVector(
                    language: "es",
                    profileFingerprint: englishProfile.fingerprint,
                    values: [1, 0]),
                .vectorLanguageMismatch("en")),
            (
                RetrievalSemanticBoundaryVector(
                    language: "en",
                    profileFingerprint: spanishProfile.fingerprint,
                    values: [1, 0]),
                .vectorProfileMismatch("en")),
            (
                RetrievalSemanticBoundaryVector(
                    language: "en",
                    profileFingerprint: englishProfile.fingerprint,
                    values: [1]),
                .invalidVector("en")),
            (
                RetrievalSemanticBoundaryVector(
                    language: "en",
                    profileFingerprint: englishProfile.fingerprint,
                    values: [.infinity, 0]),
                .invalidVector("en")),
            (
                RetrievalSemanticBoundaryVector(
                    language: "en",
                    profileFingerprint: englishProfile.fingerprint,
                    values: [0, 0]),
                .invalidVector("en"))
        ]

        for (response, expected) in cases {
            let embedding = TestSemanticBoundaryEmbedding(
                proposal: proposal(),
                responseByText: [source.text: response])
            await assertChunkingError(
                embedding: embedding,
                meetingID: meetingID,
                segments: [source],
                expected: expected)
        }
    }

    func testResourceCeilingKeepsCanonicalTurnsNonOverlapping() async throws {
        let meetingID = meeting(7)
        let speakers = testSpeakers(meetingID: meetingID)
        let segments = (0..<4).map { index in
            segment(
                index + 1,
                meetingID: meetingID,
                speakerID: speakers[index % speakers.count].id,
                text: "turn \(index + 1)",
                start: Double(index))
        }
        let embedding = TestSemanticBoundaryEmbedding(
            proposal: proposal(),
            defaultVectorsByLanguage: ["en": [1, 0], "es": [1, 0, 0]])

        let result = try await chunks(
            meetingID: meetingID,
            segments: segments,
            speakers: speakers,
            embedding: embedding)

        XCTAssertEqual(result.chunks.map(\.sourceSegmentIDs), [
            Array(segments[0...2]).map(\.id), [segments[3].id]
        ])
        XCTAssertTrue(result.chunks.allSatisfy { $0.turns.count <= 3 })
        XCTAssertEqual(result.chunks.flatMap(\.sourceSegmentIDs), segments.map(\.id))
        XCTAssertEqual(result.diagnostics.resourceBoundaryCount, 1)
    }

    func testCharacterBudgetIsAppendOnlyAndKeepsOversizedTurnsVisible() async throws {
        let meetingID = meeting(11)
        let speakers = testSpeakers(meetingID: meetingID)
        let oversized = segment(
            1,
            meetingID: meetingID,
            speakerID: speakers[0].id,
            text: String(repeating: "x", count: 950),
            start: 0)
        let reply = segment(
            2,
            meetingID: meetingID,
            speakerID: speakers[1].id,
            text: "bounded reply",
            start: 1)
        let embedding = TestSemanticBoundaryEmbedding(
            proposal: proposal(),
            defaultVectorsByLanguage: ["en": [1, 0], "es": [1, 0, 0]])

        let result = try await chunks(
            meetingID: meetingID,
            segments: [oversized, reply],
            speakers: speakers,
            embedding: embedding)

        XCTAssertEqual(result.chunks.map(\.sourceSegmentIDs), [
            [oversized.id], [reply.id]
        ])
        XCTAssertEqual(result.chunks[0].text.count, 950)
        XCTAssertEqual(result.diagnostics.resourceBoundaryCount, 1)
    }

    func testCorrectionCanReflowOnlyThroughAdjacentSemanticDecisions() async throws {
        let meetingID = meeting(8)
        let speakers = testSpeakers(meetingID: meetingID)
        let original = (0..<4).map { index in
            segment(
                index + 1,
                meetingID: meetingID,
                speakerID: speakers[index % speakers.count].id,
                text: "turn \(index + 1)",
                start: Double(index))
        }
        var corrected = original
        corrected[1].text = "turn 2 corrected"
        let embedding = TestSemanticBoundaryEmbedding(
            proposal: proposal(),
            vectorsByText: [
                "turn 1": [1, 0],
                "turn 2": [1, 0],
                "turn 2 corrected": [0, 1],
                "turn 3": [0, 1],
                "turn 4": [0, 1]
            ])

        let previous = try await chunks(
            meetingID: meetingID,
            segments: original,
            speakers: speakers,
            embedding: embedding).chunks
        let currentRevision = correction(8)
        let current = try await RetrievalSemanticBoundaryChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            correctionRevision: currentRevision,
            segments: corrected,
            speakers: speakers,
            embedding: embedding).chunks
        let delta = RetrievalChunkDelta.between(previous: previous, current: current)

        XCTAssertEqual(previous.map(\.sourceSegmentIDs), [
            Array(original[0...1]).map(\.id), Array(original[2...3]).map(\.id)
        ])
        XCTAssertEqual(current.map(\.sourceSegmentIDs), [
            [corrected[0].id], Array(corrected[1...3]).map(\.id)
        ])
        XCTAssertEqual(current.flatMap(\.sourceSegmentIDs), corrected.map(\.id))
        XCTAssertEqual(delta.upserts.count, 2)
        XCTAssertEqual(delta.removedChunkIDs.count, 2)
        XCTAssertTrue(delta.retained.isEmpty)
        XCTAssertTrue(current.allSatisfy { $0.correctionRevision == currentRevision })
    }

    func testTenThousandTurnsStayWithinOneVectorPerTurnAndBoundedWindows() async throws {
        let meetingID = meeting(9)
        let speakers = testSpeakers(meetingID: meetingID)
        let segments = (0..<10_000).map { index in
            segment(
                index + 1,
                meetingID: meetingID,
                speakerID: speakers[index % speakers.count].id,
                text: "turn \(index + 1)",
                start: Double(index))
        }
        let embedding = TestSemanticBoundaryEmbedding(
            proposal: proposal(),
            defaultVectorsByLanguage: ["en": [1, 0], "es": [1, 0, 0]],
            recordsRequests: false)

        let result = try await chunks(
            meetingID: meetingID,
            segments: segments,
            speakers: speakers,
            embedding: embedding)

        XCTAssertEqual(result.diagnostics.turnCount, 10_000)
        XCTAssertEqual(result.diagnostics.vectorizedTurnCount, 10_000)
        let requestCount = await embedding.requestCount
        XCTAssertEqual(requestCount, 10_000)
        XCTAssertEqual(result.chunks.count, 3_334)
        XCTAssertTrue(result.chunks.allSatisfy { (1...3).contains($0.turns.count) })
        XCTAssertEqual(result.chunks.flatMap(\.sourceSegmentIDs), segments.map(\.id))
        XCTAssertEqual(
            Set(result.chunks.flatMap(\.sourceSegmentIDs)).count,
            segments.count)
    }

    func testCancellationStopsSuspendedVectorWork() async throws {
        let meetingID = meeting(10)
        let source = segment(1, meetingID: meetingID, text: "evidence", start: 0)
        let vectorStarted = expectation(description: "vector adapter entered")
        let embedding = TestSemanticBoundaryEmbedding(
            proposal: proposal(),
            defaultVectorsByLanguage: ["en": [1, 0], "es": [1, 0, 0]],
            vectorDelay: .seconds(30),
            onVectorStarted: { vectorStarted.fulfill() })
        let operation = Task {
            try await RetrievalSemanticBoundaryChunker.chunks(
                meetingID: meetingID,
                transcriptRevision: 1,
                correctionRevision: .accepted,
                segments: [source],
                speakers: [],
                embedding: embedding)
        }
        defer { operation.cancel() }
        // Yielding a fixed number of times does not establish provider entry.
        await fulfillment(of: [vectorStarted], timeout: 5)
        let requestCount = await embedding.requestCount
        XCTAssertEqual(requestCount, 1)

        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("expected cancellation to propagate")
        } catch is CancellationError {
            // Expected cooperative cancellation from the vector adapter.
        }
        let finalRequestCount = await embedding.requestCount
        XCTAssertEqual(finalRequestCount, 1)
    }

    private func chunks(
        meetingID: MeetingID,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        embedding: any RetrievalSemanticBoundaryEmbedding
    ) async throws -> RetrievalSemanticBoundaryChunkingResult {
        try await RetrievalSemanticBoundaryChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: 1,
            correctionRevision: .accepted,
            segments: segments,
            speakers: speakers,
            embedding: embedding)
    }

    private func assertChunkingError(
        embedding: any RetrievalSemanticBoundaryEmbedding,
        meetingID: MeetingID,
        segments: [TranscriptSegment],
        expected: RetrievalSemanticBoundaryChunkingError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await chunks(
                meetingID: meetingID,
                segments: segments,
                speakers: [],
                embedding: embedding)
            XCTFail("expected semantic-boundary chunking to fail", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? RetrievalSemanticBoundaryChunkingError,
                expected,
                file: file,
                line: line)
        }
    }

    private func segment(
        _ value: Int,
        meetingID: MeetingID,
        speakerID: SpeakerID? = nil,
        text: String,
        language: String? = "en",
        start: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: uuid(value),
            meetingID: meetingID,
            speakerID: speakerID,
            channel: .system,
            text: text,
            language: language,
            startTime: start,
            endTime: start + 0.8,
            isFinal: true)
    }

    private func testSpeakers(meetingID: MeetingID) -> [Speaker] {
        [
            Speaker(
                id: SpeakerID(rawValue: uuid(20_001)),
                meetingID: meetingID,
                label: "A"),
            Speaker(
                id: SpeakerID(rawValue: uuid(20_002)),
                meetingID: meetingID,
                label: "B")
        ]
    }

    private func meeting(_ value: Int) -> MeetingID {
        MeetingID(rawValue: uuid(10_000 + value))
    }

    private func correction(_ value: Int) -> TranscriptCorrectionRevision {
        TranscriptCorrectionRevision(rawValue: String(format: "%064x", value))!
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private var englishProfile: SemanticEmbeddingProfile {
        Self.englishProfile
    }

    private var spanishProfile: SemanticEmbeddingProfile {
        Self.spanishProfile
    }

    private func proposal() -> RetrievalSemanticBoundaryProposal {
        Self.proposal()
    }

    private func sharedProposal() -> RetrievalSemanticBoundaryProposal {
        RetrievalSemanticBoundaryProposal(
            candidateIdentifier: "test-semantic-boundary",
            candidateRevision: 1,
            scope: .benchmarkOnly,
            canonicalUnit: .completeTurn,
            sourceReuse: .nonOverlapping,
            actorTopology: .preserved,
            resourceBounds: .conversationWindowCeiling,
            boundarySignal: .semanticSimilarity(embeddingSpace: .shared(
                profile: Self.englishProfile,
                supportedLanguages: ["en", "es"],
                minimumCosineSimilarity: 0.8)))
    }

    fileprivate static let englishProfile = SemanticEmbeddingProfile(
        modelIdentifier: "test-sentence-en",
        modelRevision: 1,
        vectorDimension: 2,
        pipelineIdentifier: "test-cosine",
        pipelineRevision: 1,
        vectorSchemaVersion: 1)

    fileprivate static let spanishProfile = SemanticEmbeddingProfile(
        modelIdentifier: "test-sentence-es",
        modelRevision: 1,
        vectorDimension: 3,
        pipelineIdentifier: "test-cosine",
        pipelineRevision: 1,
        vectorSchemaVersion: 1)

    fileprivate static func proposal() -> RetrievalSemanticBoundaryProposal {
        RetrievalSemanticBoundaryProposal(
            candidateIdentifier: "test-semantic-boundary",
            candidateRevision: 1,
            scope: .benchmarkOnly,
            canonicalUnit: .completeTurn,
            sourceReuse: .nonOverlapping,
            actorTopology: .preserved,
            resourceBounds: .conversationWindowCeiling,
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .partitionedByLanguage([
                    .init(
                        language: "en",
                        profile: englishProfile,
                        minimumCosineSimilarity: 0.8),
                    .init(
                        language: "es",
                        profile: spanishProfile,
                        minimumCosineSimilarity: 0.8)
                ])))
    }
}

private actor TestSemanticBoundaryEmbedding: RetrievalSemanticBoundaryEmbedding {
    struct Request: Equatable, Sendable {
        let text: String
        let language: String
    }

    private let proposalValue: RetrievalSemanticBoundaryProposal
    private let responseByText: [String: RetrievalSemanticBoundaryVector]
    private let defaultVectorsByLanguage: [String: [Float]]
    private let recordsRequests: Bool
    private let vectorDelay: Duration?
    private let onVectorStarted: (@Sendable () -> Void)?
    private(set) var requests: [Request] = []
    private(set) var requestCount = 0

    init(
        proposal: RetrievalSemanticBoundaryProposal,
        responseByText: [String: RetrievalSemanticBoundaryVector] = [:],
        defaultVectorsByLanguage: [String: [Float]] = [:],
        recordsRequests: Bool = true,
        vectorDelay: Duration? = nil,
        onVectorStarted: (@Sendable () -> Void)? = nil
    ) {
        self.proposalValue = proposal
        self.responseByText = responseByText
        self.defaultVectorsByLanguage = defaultVectorsByLanguage
        self.recordsRequests = recordsRequests
        self.vectorDelay = vectorDelay
        self.onVectorStarted = onVectorStarted
    }

    init(
        proposal: RetrievalSemanticBoundaryProposal,
        vectorsByText: [String: [Float]],
        recordsRequests: Bool = true
    ) {
        self.init(
            proposal: proposal,
            responseByText: Dictionary(uniqueKeysWithValues: vectorsByText.map {
                let language = $0.value.count
                    == RetrievalSemanticBoundaryChunkingTests
                        .englishProfile.vectorDimension ? "en" : "es"
                let profile = language == "en"
                    ? RetrievalSemanticBoundaryChunkingTests.englishProfile
                    : RetrievalSemanticBoundaryChunkingTests.spanishProfile
                return (
                    $0.key,
                    RetrievalSemanticBoundaryVector(
                        language: language,
                        profileFingerprint: profile.fingerprint,
                        values: $0.value))
            }),
            recordsRequests: recordsRequests)
    }

    func boundaryProposal() -> RetrievalSemanticBoundaryProposal {
        proposalValue
    }

    func vector(
        for text: String,
        language: String
    ) async throws -> RetrievalSemanticBoundaryVector {
        requestCount += 1
        if recordsRequests {
            requests.append(Request(text: text, language: language))
        }
        onVectorStarted?()
        if let vectorDelay {
            try await Task.sleep(for: vectorDelay)
        }
        if let response = responseByText[text] {
            return response
        }
        guard let values = defaultVectorsByLanguage[language] else {
            throw TestSemanticBoundaryEmbeddingError.missingVector(text)
        }
        let profile = language == "en"
            ? RetrievalSemanticBoundaryChunkingTests.englishProfile
            : RetrievalSemanticBoundaryChunkingTests.spanishProfile
        return RetrievalSemanticBoundaryVector(
            language: language,
            profileFingerprint: profile.fingerprint,
            values: values)
    }
}

private enum TestSemanticBoundaryEmbeddingError: Error {
    case missingVector(String)
}
