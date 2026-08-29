import CryptoKit
import Darwin
import Foundation
import ApplicationKit
import IntelligenceKit
import PortavozCore

struct LiveAssistValidationLanguagePair: Codable, Equatable {
    let source: String
    let target: String
}

private enum LiveAssistValidationAdapterCodingKey: String, CodingKey {
    case id
    case version
    case className = "class"
    case installedModel
}

private enum LiveAssistValidationInterviewCodingKey: String, CodingKey {
    case scenarioID
    case questionID
    case evidenceIDs
}

private enum LiveAssistValidationTranslationCodingKey: String, CodingKey {
    case scenarioID
    case pair
    case pendingIDs
}

enum LiveAssistValidationAdapter: String, Equatable {
    case releasedPrefilter = "released-prefilter"
    case foundationModels = "foundation-models"

    var receipt: LiveAssistValidationObservations.Adapter {
        switch self {
        case .releasedPrefilter:
            .init(
                id: "released-turn-endpoint",
                version: "1.0.0",
                className: "released-prefilter",
                installedModel: false)
        case .foundationModels:
            .init(
                id: "apple-foundation-models-live-question",
                version: "system",
                className: "installed-model",
                installedModel: true)
        }
    }
}

struct LiveAssistValidationConfiguration: Equatable {
    let fixtureURL: URL
    let outputURL: URL
    let adapter: LiveAssistValidationAdapter
    let commit: String
    let build: String
    let sourceState: String
    let iterations: Int

    static func requested(
        arguments: [String]
    ) throws -> LiveAssistValidationConfiguration? {
        guard arguments.contains("--bench-live-assist") else { return nil }
        let reader = LiveAssistValidationOptionReader(arguments: arguments)
        let fixture = try reader.required("--live-assist-fixture")
        let output = try reader.required("--live-assist-output")
        let adapterValue = try reader.required("--live-assist-adapter")
        let commit = try reader.required("--live-assist-commit")
        let build = try reader.required("--live-assist-build")
        let sourceState = try reader.required("--live-assist-source-state")
        let iterations = try reader.integer(
            "--live-assist-iterations",
            defaultValue: 5,
            allowed: 5...100)

        guard let adapter = LiveAssistValidationAdapter(rawValue: adapterValue)
        else { throw LiveAssistValidationError.invalidAdapter }
        guard commit.range(
            of: #"^[0-9a-f]{40}$"#,
            options: .regularExpression) != nil
        else { throw LiveAssistValidationError.invalidCommit }
        guard build.isSafeLiveAssistIdentifier
        else { throw LiveAssistValidationError.invalidBuild }
        guard ["clean", "dirty"].contains(sourceState)
        else { throw LiveAssistValidationError.invalidSourceState }

        return LiveAssistValidationConfiguration(
            fixtureURL: URL(fileURLWithPath: fixture).standardizedFileURL,
            outputURL: URL(fileURLWithPath: output).standardizedFileURL,
            adapter: adapter,
            commit: commit,
            build: build,
            sourceState: sourceState,
            iterations: iterations)
    }
}

private struct LiveAssistValidationOptionReader {
    let arguments: [String]

    func required(_ option: String) throws -> String {
        let matches = arguments.indices.filter { arguments[$0] == option }
        guard matches.count == 1,
              let index = matches.first,
              arguments.indices.contains(index + 1)
        else { throw LiveAssistValidationError.invalidArguments }
        let value = arguments[index + 1]
        guard !value.isEmpty, !value.hasPrefix("--")
        else { throw LiveAssistValidationError.invalidArguments }
        return value
    }

    func integer(
        _ option: String,
        defaultValue: Int,
        allowed: ClosedRange<Int>
    ) throws -> Int {
        let matches = arguments.indices.filter { arguments[$0] == option }
        guard matches.count <= 1 else {
            throw LiveAssistValidationError.invalidIterations
        }
        guard let index = matches.first else { return defaultValue }
        guard arguments.indices.contains(index + 1),
              let value = Int(arguments[index + 1]),
              allowed.contains(value)
        else { throw LiveAssistValidationError.invalidIterations }
        return value
    }
}

enum LiveAssistValidationError: Error, Equatable, LocalizedError {
    case foundationModelsUnavailable
    case hostPowerChanged
    case invalidAdapter
    case invalidArguments
    case invalidBuild
    case invalidCommit
    case invalidFixture
    case invalidIterations
    case invalidSourceState
    case outputAlreadyExists
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .foundationModelsUnavailable:
            "The installed Foundation Models lane is unavailable on this Mac"
        case .hostPowerChanged:
            "The power source changed during live-assistance measurement"
        case .invalidAdapter:
            "The live-assistance adapter is unsupported"
        case .invalidArguments:
            "The live-assistance runner arguments are incomplete or duplicated"
        case .invalidBuild:
            "The live-assistance build identity is invalid"
        case .invalidCommit:
            "The live-assistance commit must be a full lowercase SHA-1"
        case .invalidFixture:
            "The live-assistance public fixture is missing, stale, or malformed"
        case .invalidIterations:
            "Live-assistance iterations must be between 5 and 100"
        case .invalidSourceState:
            "Live-assistance source state must be clean or dirty"
        case .outputAlreadyExists:
            "The live-assistance output already exists"
        case .timedOut(let domain):
            "The \(domain) reliability check exceeded its bounded deadline"
        }
    }
}

private extension String {
    var isSafeLiveAssistIdentifier: Bool {
        guard count <= 96 else { return false }
        return range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._+-]*$"#,
            options: .regularExpression) != nil
    }
}

struct LiveAssistValidationFixture: Decodable {
    static let generation = "public-bilingual-v1"
    static let checksum =
        "287e77db9d9a277c3243c2ce3d7be37f1ada65379e8dae62bb1ed60aba466cb4"

    let schemaVersion: Int
    let kind: String
    let generation: String
    let contentSource: String
    let questionSessions: [QuestionSession]
    let interviewScenarios: [InterviewScenario]
    let rollingSummaryScenarios: [SummaryScenario]
    let translationScenarios: [TranslationScenario]
    let faultScenarios: [FaultScenario]

    struct QuestionSession: Decodable {
        let id: String
        let ownerName: String
        let events: [QuestionEvent]
    }

    struct QuestionEvent: Decodable {
        let id: UUID
        let channel: AudioChannel
        let confidence: Double
        let text: String
    }

    struct InterviewScenario: Decodable {
        let id: String
        let segments: [Segment]
    }

    struct SummaryScenario: Decodable {
        let id: String
        let segments: [Segment]
        let summarizedIDs: [UUID]
        let maximumRows: Int
        let maximumCharacters: Int
    }

    struct TranslationScenario: Decodable {
        let id: String
        let targetLanguage: String
        let segments: [Segment]
        let translatedSourceTexts: [String: String]
        let unsupportedIDs: [UUID]

        var translatedSourceTextByID: [UUID: String] {
            translatedSourceTexts.reduce(into: [:]) { result, item in
                if let id = UUID(uuidString: item.key) {
                    result[id] = item.value
                }
            }
        }
    }

    struct FaultScenario: Decodable {
        let id: String
        let domain: String
        let fault: String
    }

    struct Segment: Decodable {
        let id: UUID
        let meetingID: UUID
        let channel: AudioChannel
        let text: String
        let language: String
        let startSeconds: Double
        let endSeconds: Double
        let isFinal: Bool

        var transcriptSegment: TranscriptSegment {
            TranscriptSegment(
                id: id,
                meetingID: MeetingID(rawValue: meetingID),
                channel: channel,
                text: text,
                language: language,
                startTime: startSeconds,
                endTime: endSeconds,
                isFinal: isFinal)
        }
    }

    static func load(from url: URL) throws -> LiveAssistValidationFixture {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              SHA256.hash(data: data).hexDigest == checksum,
              let fixture = try? JSONDecoder().decode(Self.self, from: data),
              fixture.schemaVersion == 1,
              fixture.kind == "live-assist-validation-fixture",
              fixture.generation == generation,
              fixture.contentSource == "public-synthetic-only",
              fixture.questionSessions.count == 4,
              fixture.questionSessions.allSatisfy({ $0.events.count == 8 }),
              fixture.interviewScenarios.count == 7,
              fixture.rollingSummaryScenarios.count == 5,
              fixture.translationScenarios.count == 6,
              fixture.faultScenarios.count == 8
        else { throw LiveAssistValidationError.invalidFixture }
        return fixture
    }
}

private extension Digest {
    var hexDigest: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

struct LiveAssistValidationObservations: Codable, Equatable {
    struct Adapter: Codable, Equatable {
        let id: String
        let version: String
        let className: String
        let installedModel: Bool

        init(
            id: String,
            version: String,
            className: String,
            installedModel: Bool
        ) {
            self.id = id
            self.version = version
            self.className = className
            self.installedModel = installedModel
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(
                keyedBy: LiveAssistValidationAdapterCodingKey.self)
            id = try values.decode(String.self, forKey: .id)
            version = try values.decode(String.self, forKey: .version)
            className = try values.decode(String.self, forKey: .className)
            installedModel = try values.decode(
                Bool.self,
                forKey: .installedModel)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(
                keyedBy: LiveAssistValidationAdapterCodingKey.self)
            try values.encode(id, forKey: .id)
            try values.encode(version, forKey: .version)
            try values.encode(className, forKey: .className)
            try values.encode(installedModel, forKey: .installedModel)
        }
    }

    struct Run: Codable, Equatable {
        let commit: String
        let build: String
        let platform: String
        let osVersion: String
        let architecture: String
        let sourceState: String
    }

    struct Question: Codable, Equatable {
        let eventID: String
        let decision: String
    }

    struct Interview: Codable, Equatable {
        let scenarioID: String
        let questionID: String?
        let evidenceIDs: [String]

        init(
            scenarioID: String,
            questionID: String?,
            evidenceIDs: [String]
        ) {
            self.scenarioID = scenarioID
            self.questionID = questionID
            self.evidenceIDs = evidenceIDs
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(
                keyedBy: LiveAssistValidationInterviewCodingKey.self)
            scenarioID = try values.decode(String.self, forKey: .scenarioID)
            questionID = try values.decodeIfPresent(
                String.self,
                forKey: .questionID)
            evidenceIDs = try values.decode([String].self, forKey: .evidenceIDs)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(
                keyedBy: LiveAssistValidationInterviewCodingKey.self)
            try values.encode(scenarioID, forKey: .scenarioID)
            if let questionID {
                try values.encode(questionID, forKey: .questionID)
            } else {
                try values.encodeNil(forKey: .questionID)
            }
            try values.encode(evidenceIDs, forKey: .evidenceIDs)
        }
    }

    struct Summary: Codable, Equatable {
        let scenarioID: String
        let selectedIDs: [String]
        let hasBacklog: Bool
    }

    struct Translation: Codable, Equatable {
        let scenarioID: String
        let pair: LiveAssistValidationLanguagePair?
        let pendingIDs: [String]

        init(
            scenarioID: String,
            pair: LiveAssistValidationLanguagePair?,
            pendingIDs: [String]
        ) {
            self.scenarioID = scenarioID
            self.pair = pair
            self.pendingIDs = pendingIDs
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(
                keyedBy: LiveAssistValidationTranslationCodingKey.self)
            scenarioID = try values.decode(String.self, forKey: .scenarioID)
            pair = try values.decodeIfPresent(
                LiveAssistValidationLanguagePair.self,
                forKey: .pair)
            pendingIDs = try values.decode([String].self, forKey: .pendingIDs)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(
                keyedBy: LiveAssistValidationTranslationCodingKey.self)
            try values.encode(scenarioID, forKey: .scenarioID)
            if let pair {
                try values.encode(pair, forKey: .pair)
            } else {
                try values.encodeNil(forKey: .pair)
            }
            try values.encode(pendingIDs, forKey: .pendingIDs)
        }
    }

    struct Fault: Codable, Equatable {
        let scenarioID: String
        let outcome: String
        let latePublicationCount: Int
    }

    struct Timing: Codable, Equatable {
        let firstResultMilliseconds: Double
        let steadyStateMilliseconds: [Double]
    }

    struct Timings: Codable, Equatable {
        let questionDetection: Timing
        let interview: Timing
        let rollingSummary: Timing
        let translation: Timing
    }

    struct Resources: Codable, Equatable {
        let iterations: Int
        let wallDurationMilliseconds: Double
        let cpuTimeMilliseconds: Double
        let initialPhysicalFootprintBytes: UInt64
        let finalPhysicalFootprintBytes: UInt64
        let peakPhysicalFootprintBytes: UInt64
        let energyNanojoules: UInt64
        let maximumThermalState: String
        let powerSource: String
        let lowPowerModeEnabled: Bool
    }

    let schemaVersion: Int
    let kind: String
    let fixtureGeneration: String
    let fixtureChecksum: String
    let adapter: Adapter
    let run: Run
    let questionEvents: [Question]
    let interviewScenarios: [Interview]
    let rollingSummaryScenarios: [Summary]
    let translationScenarios: [Translation]
    let faultScenarios: [Fault]
    let timings: Timings
    let resources: Resources
}

enum LiveAssistValidationPolicy {
    static func interviews(
        _ scenarios: [LiveAssistValidationFixture.InterviewScenario]
    ) -> [LiveAssistValidationObservations.Interview] {
        scenarios.map { scenario in
            let context = InterviewQuestionPolicy.context(
                in: scenario.segments.map(\.transcriptSegment))
            return .init(
                scenarioID: scenario.id,
                questionID: context?.question.segmentID.liveAssistReceiptID,
                evidenceIDs: context?.evidence.map { $0.id.liveAssistReceiptID } ?? [])
        }
    }

    static func summaries(
        _ scenarios: [LiveAssistValidationFixture.SummaryScenario]
    ) -> [LiveAssistValidationObservations.Summary] {
        scenarios.map { scenario in
            let rows = scenario.segments.map(\.transcriptSegment)
            let summarized = Set(scenario.summarizedIDs)
            let selected = LiveSummaryWindowPolicy.unsummarizedClosedRows(
                rows,
                summarizedIDs: summarized,
                maximumRows: scenario.maximumRows,
                maximumCharacters: scenario.maximumCharacters)
            let completed = summarized.union(selected.map(\.id))
            return .init(
                scenarioID: scenario.id,
                selectedIDs: selected.map { $0.id.liveAssistReceiptID },
                hasBacklog: LiveSummaryWindowPolicy.hasUnsummarizedClosedRows(
                    rows,
                    summarizedIDs: completed))
        }
    }

    static func translations(
        _ scenarios: [LiveAssistValidationFixture.TranslationScenario]
    ) -> [LiveAssistValidationObservations.Translation] {
        scenarios.map { scenario in
            let rows = scenario.segments.map(\.transcriptSegment)
            let unsupported = Set(scenario.unsupportedIDs)
            let pair = LiveTranslationRouting.nextPair(
                segments: rows,
                translatedSourceTexts: scenario.translatedSourceTextByID,
                unsupportedIDs: unsupported,
                target: scenario.targetLanguage)
            let pending = pair.map {
                LiveTranslationRouting.pendingRows(
                    segments: rows,
                    translatedSourceTexts: scenario.translatedSourceTextByID,
                    unsupportedIDs: unsupported,
                    pair: $0).map(\.id)
            } ?? []
            return .init(
                scenarioID: scenario.id,
                pair: pair.map {
                    .init(source: $0.source, target: $0.target)
                },
                pendingIDs: pending.map(\.liveAssistReceiptID))
        }
    }
}

extension UUID {
    var liveAssistReceiptID: String {
        uuidString.lowercased()
    }
}

final class LiveAssistResourceMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private let initial: ResourceProbeUsage
    private let startedAt: UInt64
    private var peak: UInt64
    private var maximumThermal: ResourceProbeThermalState
    private var powerSources: Set<ResourceProbePowerSource>
    private var lowPowerObserved: Bool
    private var finished = false
    private var sampler: Task<Void, Never>?

    init() throws {
        let usage = try ResourceProbeUsage.current()
        initial = usage
        startedAt = DispatchTime.now().uptimeNanoseconds
        peak = usage.physicalFootprintBytes
        maximumThermal = usage.thermalState
        powerSources = [usage.powerSource]
        lowPowerObserved = usage.lowPowerModeEnabled
    }

    deinit {
        sampler?.cancel()
    }

    func start() {
        sampler = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(25))
                    try self?.sample()
                } catch is CancellationError {
                    return
                } catch {
                    // The final synchronous sample remains authoritative.
                }
            }
        }
    }

    func finish(iterations: Int) throws -> LiveAssistValidationObservations.Resources {
        sampler?.cancel()
        let final = try ResourceProbeUsage.current()
        let finishedAt = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        ingest(final)
        finished = true
        guard powerSources.count == 1, let powerSource = powerSources.first
        else { throw LiveAssistValidationError.hostPowerChanged }
        return .init(
            iterations: iterations,
            wallDurationMilliseconds: Self.milliseconds(
                finishedAt.liveAssistSubtractingWithoutUnderflow(startedAt)),
            cpuTimeMilliseconds: Self.cpuMilliseconds(
                final.cpuAbsoluteTime.liveAssistSubtractingWithoutUnderflow(
                    initial.cpuAbsoluteTime)),
            initialPhysicalFootprintBytes: initial.physicalFootprintBytes,
            finalPhysicalFootprintBytes: final.physicalFootprintBytes,
            peakPhysicalFootprintBytes: peak,
            energyNanojoules: final.energyNanojoules.liveAssistSubtractingWithoutUnderflow(
                initial.energyNanojoules),
            maximumThermalState: maximumThermal.rawValue,
            powerSource: powerSource.rawValue,
            lowPowerModeEnabled: lowPowerObserved)
    }

    private func sample() throws {
        let usage = try ResourceProbeUsage.current()
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        ingest(usage)
    }

    private func ingest(_ usage: ResourceProbeUsage) {
        peak = max(peak, usage.physicalFootprintBytes)
        if usage.thermalState.rank > maximumThermal.rank {
            maximumThermal = usage.thermalState
        }
        powerSources.insert(usage.powerSource)
        lowPowerObserved = lowPowerObserved || usage.lowPowerModeEnabled
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    private static func cpuMilliseconds(_ ticks: UInt64) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(ticks) * Double(timebase.numer)
            / Double(timebase.denom) / 1_000_000
    }
}

extension UInt64 {
    fileprivate func liveAssistSubtractingWithoutUnderflow(
        _ other: UInt64
    ) -> UInt64 {
        self >= other ? self - other : 0
    }
}
