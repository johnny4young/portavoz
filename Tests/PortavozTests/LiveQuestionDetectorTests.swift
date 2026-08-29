import CryptoKit
import Foundation
@testable import IntelligenceKit
import PortavozCore
import XCTest

final class LiveQuestionAdmissionPolicyTests: XCTestCase {
    func testAdmitsStrongNoisyASRWithoutLexicalSurface() throws {
        let result = try LiveQuestionAdmissionPolicy.decide(
            candidate: "wher shud we put the signed recipt",
            ownerName: "Alex",
            prediction: LiveQuestionModelPrediction(
                question: 0.86,
                nonQuestion: 0.08,
                abstain: 0.06))
        XCTAssertEqual(result.decision, .question)
        XCTAssertEqual(result.providerID, LiveQuestionAdmissionPolicy.providerID)
        XCTAssertEqual(result.modelID, LiveQuestionAdmissionPolicy.modelID)
    }

    func testWeakQuestionShapeCannotCreateFalsePrompt() throws {
        let result = try LiveQuestionAdmissionPolicy.decide(
            candidate: "What a good result we recorded today",
            ownerName: nil,
            prediction: LiveQuestionModelPrediction(
                question: 0.53,
                nonQuestion: 0.38,
                abstain: 0.09))
        XCTAssertNotEqual(result.decision, .question)
    }

    func testExplicitQuotedAndFragmentAbstentionsStayClosed() throws {
        let quoted = try LiveQuestionAdmissionPolicy.decide(
            candidate: "The document quotes: why did the job fail?",
            ownerName: nil,
            prediction: LiveQuestionModelPrediction(
                question: 0.01,
                nonQuestion: 0.01,
                abstain: 0.98))
        XCTAssertEqual(quoted.decision, .abstain)

        let fragment = try LiveQuestionAdmissionPolicy.decide(
            candidate: "can the",
            ownerName: nil,
            prediction: LiveQuestionModelPrediction(
                question: 0.56,
                nonQuestion: 0.25,
                abstain: 0.19))
        XCTAssertEqual(fragment.decision, .abstain)
    }

    func testRejectsMalformedProbabilitiesFailClosed() {
        XCTAssertThrowsError(try LiveQuestionAdmissionPolicy.decide(
            candidate: "How do we ship this safely?",
            ownerName: nil,
            prediction: LiveQuestionModelPrediction(
                question: .nan,
                nonQuestion: 0.2,
                abstain: 0.8))) { error in
            XCTAssertEqual(error as? LiveQuestionDetectorError, .invalidPrediction)
        }
    }
}

final class BundledLiveQuestionDetectorTests: XCTestCase {
    private struct ValidationFixture: Decodable {
        struct Session: Decodable {
            struct Event: Decodable {
                let channel: AudioChannel
                let expectedDecision: String
                let text: String
            }

            let ownerName: String
            let events: [Event]
        }

        let questionSessions: [Session]
    }

    private struct TrainingFixture: Decodable {
        let labels: [String: [String]]
    }

    func testBundledModelPassesFrozenBilingualQuestionHoldout() async throws {
        XCTAssertTrue(BundledLiveQuestionDetector.resourceIsPresent)
        XCTAssertTrue(BundledLiveQuestionDetector.resourceIsLoadable)
        let fixture = try JSONDecoder().decode(
            ValidationFixture.self,
            from: Data(contentsOf: Self.validationFixtureURL))
        var questions = 0
        var abstentions = 0
        for session in fixture.questionSessions {
            for event in session.events where event.channel == .system {
                let result = try await BundledLiveQuestionDetector.shared.detect(
                    candidate: event.text,
                    ownerName: session.ownerName)
                switch event.expectedDecision {
                case "question":
                    questions += 1
                    XCTAssertEqual(result.decision, .question, event.text)
                case "abstain":
                    abstentions += 1
                    XCTAssertEqual(result.decision, .abstain, event.text)
                default:
                    XCTAssertNotEqual(result.decision, .question, event.text)
                }
            }
        }
        XCTAssertEqual(questions, 12)
        XCTAssertEqual(abstentions, 8)
    }

    func testTrainingCorpusDoesNotContainHoldoutSentences() throws {
        let validation = try JSONDecoder().decode(
            ValidationFixture.self,
            from: Data(contentsOf: Self.validationFixtureURL))
        let training = try JSONDecoder().decode(
            TrainingFixture.self,
            from: Data(contentsOf: Self.trainingFixtureURL))
        let heldOut = Set(validation.questionSessions.flatMap(\.events).map(\.text))
        let trained = Set(training.labels.values.flatMap { $0 })
        XCTAssertTrue(heldOut.isDisjoint(with: trained))
    }

    func testFrozenTrainingAndSourceModelDigestsMatchServingIdentity() throws {
        XCTAssertEqual(
            Self.sha256(try Data(contentsOf: Self.trainingFixtureURL)),
            LiveQuestionAdmissionPolicy.trainingCorpusSHA256)
        XCTAssertEqual(
            Self.sha256(try Data(contentsOf: Self.sourceModelURL)),
            LiveQuestionAdmissionPolicy.sourceModelSHA256)
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var validationFixtureURL: URL {
        repositoryRoot.appendingPathComponent(
            "Fixtures/LiveAssistValidation/public-bilingual-v1.json")
    }

    private static var trainingFixtureURL: URL {
        repositoryRoot.appendingPathComponent(
            "Fixtures/LiveQuestionDetector/training-public-synthetic-v1.json")
    }

    private static var sourceModelURL: URL {
        repositoryRoot.appendingPathComponent(
            "Fixtures/LiveQuestionDetector/PortavozLiveQuestionClassifier.mlmodel")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class ProviderNeutralProvenanceCompanionTests: XCTestCase {
    func testSequoiaPathPublishesQuestionOnlyArtifactWithBundledProvenance() async throws {
        let meetingID = MeetingID()
        let questionID = UUID()
        let companion = ProviderNeutralProvenanceCompanion(
            detector: FixedLiveQuestionDetector(.init(
                decision: .question,
                question: "Where should we keep the signed receipt?",
                kind: .context,
                confidence: 0.91,
                providerID: LiveQuestionAdmissionPolicy.providerID,
                modelID: LiveQuestionAdmissionPolicy.modelID)),
            allowsFoundationModelChallenger: false,
            now: { Date(timeIntervalSince1970: 100) })
        let result = await companion.generate(CompanionGenerationRequest(
            meetingID: meetingID,
            sourceTranscriptRevision: 3,
            sourceCorrectionRevision: .accepted,
            workflow: .liveRecording,
            candidate: "Where should we keep the signed receipt?",
            questionSegmentIDs: [questionID],
            recentTranscript: [],
            ownerName: "Alex",
            outputLanguage: "en",
            askedAt: 42))
        guard case .artifact(let artifact) = result else {
            return XCTFail("the admitted Sequoia question must produce a safe card")
        }
        XCTAssertTrue(artifact.card.answer.isEmpty)
        XCTAssertFalse(artifact.card.directed)
        XCTAssertEqual(artifact.card.evidence?.questionSegmentIDs, [questionID])
        XCTAssertEqual(
            artifact.generationRun.providerID,
            LiveQuestionAdmissionPolicy.providerID)
        XCTAssertEqual(
            artifact.generationRun.modelID,
            LiveQuestionAdmissionPolicy.modelID)
        XCTAssertTrue(artifact.generationRun.configJSON.contains(
            #""classifierProviderID":"apple-natural-language""#))
        XCTAssertFalse(artifact.generationRun.configJSON.contains(
            #""classifierChallengerProviderID":"foundation-models""#))
    }

    func testNonDirectedLogisticsDoesNotCreateNoiseCard() async {
        let companion = ProviderNeutralProvenanceCompanion(
            detector: FixedLiveQuestionDetector(.init(
                decision: .question,
                question: "Can you join the demo tomorrow?",
                kind: .logistics,
                confidence: 0.95,
                providerID: LiveQuestionAdmissionPolicy.providerID,
                modelID: LiveQuestionAdmissionPolicy.modelID)),
            allowsFoundationModelChallenger: false)
        let result = await companion.generate(Self.request(
            candidate: "Can you join the demo tomorrow?",
            ownerName: "Alex"))
        guard case .noArtifact = result else {
            return XCTFail("non-directed logistics must remain silent")
        }
    }

    func testDirectedLogisticsCreatesOnlyAskedYouCard() async {
        let companion = ProviderNeutralProvenanceCompanion(
            detector: FixedLiveQuestionDetector(.init(
                decision: .question,
                question: "Alex, can you join the demo tomorrow?",
                kind: .logistics,
                confidence: 0.95,
                providerID: LiveQuestionAdmissionPolicy.providerID,
                modelID: LiveQuestionAdmissionPolicy.modelID)),
            allowsFoundationModelChallenger: false)
        let result = await companion.generate(Self.request(
            candidate: "Alex, can you join the demo tomorrow?",
            ownerName: "Alex"))
        guard case .artifact(let artifact) = result else {
            return XCTFail("a directed request must remain visible")
        }
        XCTAssertTrue(artifact.card.directed)
        XCTAssertTrue(artifact.card.answer.isEmpty)
    }

    func testTahoeChallengerCannotRewriteQuestionOrDirectedIdentity() {
        let request = Self.request(
            candidate: "Alex, wher shud we keep the signed recipt",
            ownerName: "Alex")
        let detection = LiveQuestionDetection(
            decision: .question,
            question: "Alex, wher shud we keep the signed recipt",
            kind: .context,
            confidence: 0.9,
            providerID: LiveQuestionAdmissionPolicy.providerID,
            modelID: LiveQuestionAdmissionPolicy.modelID)
        let challenger = CompanionCard(
            question: "Where should the signed receipt be kept?",
            answer: "Keep it in the local audit store.",
            kind: .context,
            source: "on-device",
            directed: false,
            askedAt: 999)

        let grounded = ProviderNeutralProvenanceCompanion.groundedChallengerCard(
            challenger,
            authoritativeDetection: detection,
            request: request)

        XCTAssertEqual(grounded.id, challenger.id)
        XCTAssertEqual(grounded.question, detection.question)
        XCTAssertEqual(grounded.answer, challenger.answer)
        XCTAssertTrue(grounded.directed)
        XCTAssertEqual(grounded.askedAt, request.askedAt)
    }

    private static func request(
        candidate: String,
        ownerName: String?
    ) -> CompanionGenerationRequest {
        CompanionGenerationRequest(
            meetingID: MeetingID(),
            sourceTranscriptRevision: 0,
            sourceCorrectionRevision: .accepted,
            workflow: .liveRecording,
            candidate: candidate,
            recentTranscript: [],
            ownerName: ownerName,
            outputLanguage: "en",
            askedAt: 10)
    }
}

private struct FixedLiveQuestionDetector: LiveQuestionDetecting {
    let result: LiveQuestionDetection

    init(_ result: LiveQuestionDetection) {
        self.result = result
    }

    func detect(
        candidate: String,
        ownerName: String?
    ) async throws -> LiveQuestionDetection {
        result
    }
}
