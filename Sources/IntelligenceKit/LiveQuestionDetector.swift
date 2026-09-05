import Foundation
import NaturalLanguage

public enum LiveQuestionDecision: String, Equatable, Sendable {
    case question
    case notQuestion
    case abstain
}

public enum LiveQuestionKind: String, Equatable, Sendable {
    case knowledge
    case context
    case logistics
}

/// Content-bearing serving result. Validation receipts retain only `decision`;
/// live generation uses the grounded original caption as the displayed question.
public struct LiveQuestionDetection: Equatable, Sendable {
    public let decision: LiveQuestionDecision
    public let question: String
    public let kind: LiveQuestionKind
    public let confidence: Double
    public let providerID: String
    public let modelID: String

    public var isQuestion: Bool { decision == .question }

    public init(
        decision: LiveQuestionDecision,
        question: String,
        kind: LiveQuestionKind,
        confidence: Double,
        providerID: String,
        modelID: String
    ) {
        self.decision = decision
        self.question = question
        self.kind = kind
        self.confidence = confidence
        self.providerID = providerID
        self.modelID = modelID
    }
}

public struct LiveQuestionModelPrediction: Equatable, Sendable {
    public let question: Double
    public let nonQuestion: Double
    public let abstain: Double

    public init(question: Double, nonQuestion: Double, abstain: Double) {
        self.question = question
        self.nonQuestion = nonQuestion
        self.abstain = abstain
    }

    fileprivate var isValid: Bool {
        let values = [question, nonQuestion, abstain]
        return values.allSatisfy { $0.isFinite && (0...1).contains($0) }
            && abs(values.reduce(0, +) - 1) <= 0.02
    }
}

public enum LiveQuestionDetectorError: Error, Equatable, LocalizedError {
    case invalidPrediction
    case modelUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidPrediction:
            "The bundled question detector returned invalid confidence values"
        case .modelUnavailable:
            "The bundled question detector is missing or could not be loaded"
        }
    }
}

public protocol LiveQuestionDetecting: Sendable {
    func detect(
        candidate: String,
        ownerName: String?
    ) async throws -> LiveQuestionDetection
}

/// Pure, calibrated serving policy layered over the frozen Create ML model.
/// Deterministic surface features recover punctuation-free/noisy ASR without
/// allowing a weak question-shaped phrase to create a card on its own.
public enum LiveQuestionAdmissionPolicy {
    public static let providerID = "apple-natural-language"
    public static let modelID = "portavoz-live-question-maxent-en-es-v1"
    public static let sourceModelSHA256 =
        "db169ed16b55eef846eb7e779eb0490e158f872c7c5e25fb025af60ff582e1e8"
    public static let trainingCorpusSHA256 =
        "d7d15611f91148ee4e4dd10cb3ea214b747009b82b2e82647bb7a8ab970dbe3d"

    /// The high-confidence path catches noisy ASR whose first word no longer
    /// matches the lexicon. The lower threshold requires deterministic syntax
    /// or an exact owner-name mention. Values are frozen by LIVE-0 holdout data.
    static let independentQuestionThreshold = 0.82
    static let surfacedQuestionThreshold = 0.58
    static let explicitAbstentionThreshold = 0.42

    public static func decide(
        candidate: String,
        ownerName: String?,
        prediction: LiveQuestionModelPrediction
    ) throws -> LiveQuestionDetection {
        guard prediction.isValid else {
            throw LiveQuestionDetectorError.invalidPrediction
        }
        let question = candidate
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard question.count >= 12 else {
            return result(.abstain, question, .context, prediction.abstain)
        }

        let directed = ownerName.map {
            QuestionHeuristic.mentions($0, in: question)
        } ?? false
        let surfaced = QuestionHeuristic.looksLikeQuestion(question) || directed
        let abstainIsStrongest = prediction.abstain >= prediction.question
            && prediction.abstain >= prediction.nonQuestion
        if abstainIsStrongest,
           prediction.abstain >= explicitAbstentionThreshold {
            return result(.abstain, question, .context, prediction.abstain)
        }

        let admitted = prediction.question >= independentQuestionThreshold
            || (surfaced && prediction.question >= surfacedQuestionThreshold)
        if admitted {
            return result(
                .question,
                question,
                kind(for: question),
                prediction.question)
        }

        let decision: LiveQuestionDecision
        let confidence: Double
        if prediction.nonQuestion >= prediction.question,
           prediction.nonQuestion >= prediction.abstain {
            decision = .notQuestion
            confidence = prediction.nonQuestion
        } else {
            decision = .abstain
            confidence = max(prediction.abstain, prediction.question)
        }
        return result(decision, question, .context, confidence)
    }

    private static func result(
        _ decision: LiveQuestionDecision,
        _ question: String,
        _ kind: LiveQuestionKind,
        _ confidence: Double
    ) -> LiveQuestionDetection {
        LiveQuestionDetection(
            decision: decision,
            question: decision == .question ? question : "",
            kind: kind,
            confidence: confidence,
            providerID: providerID,
            modelID: modelID)
    }

    /// Conservative routing protects BYOK: anything tied to the current room
    /// stays context; only general factual/technical questions become knowledge.
    private static func kind(for question: String) -> LiveQuestionKind {
        let folded = question.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        let logistics = [
            " join ", " attend ", " send ", " schedule ", " call ",
            " prepare ", " deliver ", " accompany ", " unete ",
            " asistir ", " enviar ", " agenda ", " llamar ", " prepara ",
            " entregar ", " acompana "
        ]
        let padded = " \(folded) "
        if logistics.contains(where: padded.contains) { return .logistics }

        let context = [
            " we ", " us ", " our ", " meeting ", " discussed ",
            " agreed ", " decided ", " said ", " changed ", " rollout ",
            " release ", " nos ", " nuestro ", " nuestra ", " reunion ",
            " hablamos ", " acordamos ", " decidimos ", " dijimos ",
            " cambio ", " lanzamiento ", " despliegue "
        ]
        return context.contains(where: padded.contains) ? .context : .knowledge
    }
}

/// Actor isolation is intentional: NaturalLanguage does not declare `NLModel`
/// Sendable, so one loaded 20 KB compiled model owns all sub-millisecond calls.
public actor BundledLiveQuestionDetector: LiveQuestionDetecting {
    public static let shared = BundledLiveQuestionDetector()

    private let model: NLModel?

    nonisolated public static var resourceIsPresent: Bool {
        Bundle.module.url(
            forResource: "PortavozLiveQuestionClassifier",
            withExtension: "mlmodelc") != nil
    }

    nonisolated public static let resourceIsLoadable: Bool = {
        guard let url = Bundle.module.url(
            forResource: "PortavozLiveQuestionClassifier",
            withExtension: "mlmodelc")
        else { return false }
        return (try? NLModel(contentsOf: url)) != nil
    }()

    init(model: NLModel?) {
        self.model = model
    }

    private init() {
        let url = Bundle.module.url(
            forResource: "PortavozLiveQuestionClassifier",
            withExtension: "mlmodelc")
        model = url.flatMap { try? NLModel(contentsOf: $0) }
    }

    public func detect(
        candidate: String,
        ownerName: String? = nil
    ) async throws -> LiveQuestionDetection {
        guard let model else { throw LiveQuestionDetectorError.modelUnavailable }
        let hypotheses = model.predictedLabelHypotheses(
            for: candidate,
            maximumCount: 3)
        guard let question = hypotheses["question"],
              let nonQuestion = hypotheses["nonQuestion"],
              let abstain = hypotheses["abstain"]
        else { throw LiveQuestionDetectorError.invalidPrediction }
        return try LiveQuestionAdmissionPolicy.decide(
            candidate: candidate,
            ownerName: ownerName,
            prediction: LiveQuestionModelPrediction(
                question: question,
                nonQuestion: nonQuestion,
                abstain: abstain))
    }
}
