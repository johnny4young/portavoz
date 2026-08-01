import ApplicationKit
import Darwin
import Foundation
import PortavozCore
import StorageKit

/// Runs the production hybrid retrieval adapter over an isolated judged
/// corpus and emits D194 observations. It never opens the user's library and
/// does not run a generative answer model; answer quality stays explicitly
/// unevaluated until a separate, versioned judge supplies that evidence.
enum BenchAskQualityCommand {
    static func run(_ arguments: [String]) async {
        do {
            let options = try AskQualityBenchmarkOptions(arguments: arguments)
            let fixture = try AskQualityFixture.load(from: options.fixture)
            let observations = try await AskQualityProductionBenchmark.run(
                fixture: fixture,
                build: options.build,
                commit: options.commit)
            try AskQualityPrivateJSONWriter.write(
                observations,
                to: options.output)
            print("Ask quality observations: \(options.output.path)")
        } catch {
            FileHandle.standardError.write(
                Data("bench-ask-quality error: \(error)\n".utf8))
            Foundation.exit(64)
        }
    }
}

struct AskQualityBenchmarkOptions: Equatable {
    let fixture: URL
    let output: URL
    let build: String
    let commit: String

    init(arguments: [String]) throws {
        let values = try Self.parse(arguments)
        guard let fixture = values["--fixture"], !fixture.isEmpty else {
            throw AskQualityBenchmarkError.missingOption("--fixture")
        }
        guard let output = values["--output"], !output.isEmpty else {
            throw AskQualityBenchmarkError.missingOption("--output")
        }
        guard let build = values["--build"], AskQualityIdentity.isSafeBuild(build) else {
            throw AskQualityBenchmarkError.invalidBuild
        }
        guard let commit = values["--commit"], AskQualityIdentity.isCommit(commit) else {
            throw AskQualityBenchmarkError.invalidCommit
        }
        self.fixture = URL(fileURLWithPath: fixture).standardizedFileURL
        self.output = URL(fileURLWithPath: output).standardizedFileURL
        self.build = build
        self.commit = commit
        guard self.fixture != self.output else {
            throw AskQualityBenchmarkError.outputMatchesFixture
        }
    }

    private static func parse(_ arguments: [String]) throws -> [String: String] {
        let allowed = Set(["--fixture", "--output", "--build", "--commit"])
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option) else {
                throw AskQualityBenchmarkError.unknownOption(option)
            }
            index += 1
            guard arguments.indices.contains(index) else {
                throw AskQualityBenchmarkError.missingOptionValue(option)
            }
            values[option] = arguments[index]
            index += 1
        }
        return values
    }
}

enum AskQualityBenchmarkError: Error, Equatable {
    case unknownOption(String)
    case missingOptionValue(String)
    case missingOption(String)
    case invalidBuild
    case invalidCommit
    case outputMatchesFixture
    case invalidFixture(String)
    case invalidTimestamp
    case outputAlreadyExists
    case outputPublicationFailed
}

private enum AskQualityIdentity {
    static func isSafeBuild(_ value: String) -> Bool {
        guard (1...80).contains(value.count) else { return false }
        return value.allSatisfy {
            $0.isLetter || $0.isNumber || ".+_-".contains($0)
        }
    }

    static func isCommit(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

struct AskQualityFixture: Decodable, Sendable {
    let schemaVersion: Int
    let kind: String
    let generation: String
    let contentSource: String
    let segments: [AskQualityFixtureSegment]
    let queries: [AskQualityFixtureQuery]

    static func load(from url: URL) throws -> Self {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw AskQualityBenchmarkError.invalidFixture("fixture cannot be read")
        }
        guard data.count <= 8 * 1_024 * 1_024 else {
            throw AskQualityBenchmarkError.invalidFixture("fixture exceeds 8 MiB")
        }
        let fixture: Self
        do {
            fixture = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw AskQualityBenchmarkError.invalidFixture("fixture is not valid JSON")
        }
        try fixture.validate()
        return fixture
    }

    func validate() throws {
        guard schemaVersion == 1, kind == "ask-quality-fixture" else {
            throw AskQualityBenchmarkError.invalidFixture("unsupported fixture schema")
        }
        guard !generation.isEmpty,
              ["public-synthetic-only", "private-anonymized"].contains(contentSource),
              !segments.isEmpty,
              !queries.isEmpty,
              segments.count <= 10_000,
              queries.count <= 10_000
        else {
            throw AskQualityBenchmarkError.invalidFixture("invalid fixture bounds")
        }
        let segmentIDs = Set(segments.map(\.id))
        guard segmentIDs.count == segments.count,
              Set(queries.map(\.id)).count == queries.count
        else {
            throw AskQualityBenchmarkError.invalidFixture("fixture identities repeat")
        }
        guard segments.allSatisfy({
            !$0.id.isEmpty && !$0.meetingID.isEmpty && !$0.meetingTitle.isEmpty
                && !$0.owner.isEmpty && !$0.text.isEmpty
                && $0.timestampMilliseconds >= 0 && $0.transcriptRevision >= 1
        }) else {
            throw AskQualityBenchmarkError.invalidFixture("invalid segment")
        }
        for query in queries {
            try query.validate(segmentIDs: segmentIDs)
        }
        for group in Dictionary(grouping: segments, by: \.meetingID).values {
            guard Set(group.map(\.meetingTitle)).count == 1,
                  Set(group.map(\.transcriptRevision)).count == 1
            else {
                throw AskQualityBenchmarkError.invalidFixture(
                    "meeting title or transcript revision is inconsistent")
            }
        }
    }
}

struct AskQualityFixtureSegment: Decodable, Sendable {
    let id: String
    let meetingID: String
    let meetingTitle: String
    let timestampMilliseconds: Int
    let transcriptRevision: Int
    let language: String
    let owner: String
    let text: String
}

struct AskQualityFixtureQuery: Decodable, Sendable {
    let id: String
    let text: String
    let relationship: String
    let intent: String
    let relevant: [AskQualityFixtureRelevant]
    let hardNegativeSegmentIDs: [String]
    let answerPolicy: String

    func validate(segmentIDs: Set<String>) throws {
        let relevantIDs = relevant.map(\.segmentID)
        let hardNegativeIDs = hardNegativeSegmentIDs
        guard !id.isEmpty,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["answer", "abstain"].contains(answerPolicy),
              relevant.allSatisfy({
                  segmentIDs.contains($0.segmentID)
                      && (1...3).contains($0.grade)
                      && $0.expectedTimestampMilliseconds >= 0
                      && !$0.expectedOwner.isEmpty
              }),
              hardNegativeIDs.allSatisfy(segmentIDs.contains),
              Set(relevantIDs).count == relevantIDs.count,
              Set(hardNegativeIDs).count == hardNegativeIDs.count,
              Set(relevantIDs).isDisjoint(with: hardNegativeIDs),
              (answerPolicy == "answer") == !relevant.isEmpty
        else {
            throw AskQualityBenchmarkError.invalidFixture("invalid query")
        }
    }
}

struct AskQualityFixtureRelevant: Decodable, Sendable {
    let segmentID: String
    let grade: Int
    let expectedTimestampMilliseconds: Int
    let expectedOwner: String
}

struct AskQualityObservationDocument: Encodable, Sendable {
    let schemaVersion = 1
    let kind = "ask-quality-observations"
    let fixtureGeneration: String
    let adapter: String
    let build: String
    let commit: String
    let queries: [AskQualityQueryObservation]
}

struct AskQualityQueryObservation: Encodable, Sendable {
    let queryID: String
    let hits: [AskQualityHitObservation]
    let answer: AskQualityAnswerObservation
}

struct AskQualityHitObservation: Encodable, Sendable {
    let segmentID: String
    let meetingID: String
    let timestampMilliseconds: Int
    let transcriptRevision: Int
}

struct AskQualityAnswerObservation: Encodable, Sendable {
    let outcome = "notEvaluated"
    let factuality: Double? = nil
    let citationCoverage: Double? = nil
    let unsupportedClaims = 0

    private enum CodingKeys: String, CodingKey {
        case outcome, factuality, citationCoverage, unsupportedClaims
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome, forKey: .outcome)
        try container.encodeNil(forKey: .factuality)
        try container.encodeNil(forKey: .citationCoverage)
        try container.encode(unsupportedClaims, forKey: .unsupportedClaims)
    }
}

enum AskQualityProductionBenchmark {
    static let adapter = "local-hybrid-preindexed-no-expansion-evidence-v2"

    static func run(
        fixture: AskQualityFixture,
        build: String,
        commit: String
    ) async throws -> AskQualityObservationDocument {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "portavoz-ask-quality-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(
            databaseURL: root.appendingPathComponent("quality.sqlite"))
        let mapping = try await AskQualityCorpusMapping.seed(
            fixture: fixture,
            store: store)
        let runtime = CLISemanticEmbeddingRuntime()
        _ = try await prepareCorpus(
            store: store,
            runtime: runtime)
        let retrieval = LocalAskMeetingRetrieval(
            store: store,
            queryExpander: AskQualityNoExpansion(),
            runtime: runtime)
        return try await observe(
            fixture: fixture,
            mapping: mapping,
            retrieval: retrieval,
            build: build,
            commit: commit)
    }

    static func prepareCorpus(
        store: MeetingStore,
        runtime: any SemanticEmbeddingRuntimeClient
    ) async throws -> SemanticCorpusIndexingResult {
        try await runtime.withPreparedEmbedding(
            allowAssetDownload: true
        ) { embedder in
            try await IndexSemanticCorpus(store: store).all(
                using: embedder,
                batchSize: 256)
        }
    }

    static func observe(
        fixture: AskQualityFixture,
        mapping: AskQualityCorpusMapping,
        retrieval: any AskMeetingRetrieving,
        build: String,
        commit: String
    ) async throws -> AskQualityObservationDocument {
        var observations: [AskQualityQueryObservation] = []
        observations.reserveCapacity(fixture.queries.count)
        for query in fixture.queries {
            try Task.checkCancellation()
            let citations = try await retrieval.retrieve(
                question: query.text,
                limit: 10)
            let hits = try citations.map { citation in
                try mapping.observation(for: citation)
            }
            observations.append(AskQualityQueryObservation(
                queryID: query.id,
                hits: hits,
                answer: AskQualityAnswerObservation()))
        }
        return AskQualityObservationDocument(
            fixtureGeneration: fixture.generation,
            adapter: adapter,
            build: build,
            commit: commit,
            queries: observations)
    }
}

struct AskQualityCorpusMapping: Sendable {
    private let externalSegmentIDByUUID: [UUID: String]
    private let externalMeetingIDByDomainID: [MeetingID: String]

    static func seed(
        fixture: AskQualityFixture,
        store: MeetingStore
    ) async throws -> Self {
        let grouped = Dictionary(grouping: fixture.segments, by: \.meetingID)
        var externalSegmentIDByUUID: [UUID: String] = [:]
        var externalMeetingIDByDomainID: [MeetingID: String] = [:]
        for (meetingIndex, externalMeetingID) in grouped.keys.sorted().enumerated() {
            guard let fixtureSegments = grouped[externalMeetingID],
                  !fixtureSegments.isEmpty
            else { continue }
            let result = try await seedMeeting(
                externalMeetingID: externalMeetingID,
                meetingIndex: meetingIndex,
                segments: fixtureSegments,
                store: store)
            externalMeetingIDByDomainID[result.meetingID] = externalMeetingID
            externalSegmentIDByUUID.merge(result.segmentIDs) { _, latest in latest }
        }
        return Self(
            externalSegmentIDByUUID: externalSegmentIDByUUID,
            externalMeetingIDByDomainID: externalMeetingIDByDomainID)
    }

    private static func seedMeeting(
        externalMeetingID: String,
        meetingIndex: Int,
        segments fixtureSegments: [AskQualityFixtureSegment],
        store: MeetingStore
    ) async throws -> (meetingID: MeetingID, segmentIDs: [UUID: String]) {
        let meetingID = MeetingID(rawValue: try deterministicUUID(
            namespace: "ask-quality-meeting",
            identifier: externalMeetingID))
        let speakerByOwner = try speakers(
            for: fixtureSegments,
            externalMeetingID: externalMeetingID)
        let speakers = speakerByOwner.keys.sorted().compactMap { owner in
            speakerByOwner[owner].map {
                Speaker(
                    id: $0,
                    meetingID: meetingID,
                    label: owner,
                    displayName: owner,
                    isMe: false)
            }
        }
        var externalIDs: [UUID: String] = [:]
        let transcriptSegments = try fixtureSegments.sorted {
            ($0.timestampMilliseconds, $0.id) < ($1.timestampMilliseconds, $1.id)
        }.map { segment in
            let identifier = try deterministicUUID(
                namespace: "ask-quality-segment",
                identifier: segment.id)
            externalIDs[identifier] = segment.id
            let start = TimeInterval(segment.timestampMilliseconds) / 1_000
            return TranscriptSegment(
                id: identifier,
                meetingID: meetingID,
                speakerID: speakerByOwner[segment.owner],
                channel: .system,
                text: segment.text,
                language: segment.language,
                startTime: start,
                endTime: start + 0.8,
                confidence: 1,
                isFinal: true)
        }
        let first = fixtureSegments[0]
        let startedAt = Date(
            timeIntervalSince1970: 1_700_000_000 + TimeInterval(meetingIndex * 3_600))
        let meeting = Meeting(
            id: meetingID,
            title: first.meetingTitle,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(
                (transcriptSegments.last?.endTime ?? 0) + 1),
            language: Set(fixtureSegments.map(\.language)).count == 1
                ? first.language
                : nil,
            transcriptRevision: first.transcriptRevision)
        try await store.saveImportedMeeting(
            meeting,
            speakers: speakers,
            segments: transcriptSegments)
        return (meetingID, externalIDs)
    }

    private static func speakers(
        for segments: [AskQualityFixtureSegment],
        externalMeetingID: String
    ) throws -> [String: SpeakerID] {
        try Dictionary(uniqueKeysWithValues: Set(segments.map(\.owner)).map { owner in
            (
                owner,
                SpeakerID(rawValue: try deterministicUUID(
                    namespace: "ask-quality-speaker-\(externalMeetingID)",
                    identifier: owner))
            )
        })
    }

    func observation(
        for citation: AskCitation
    ) throws -> AskQualityHitObservation {
        let segmentID = citation.segmentID.flatMap {
            externalSegmentIDByUUID[$0]
        } ?? "unknown-segment"
        let meetingID = externalMeetingIDByDomainID[citation.meetingID]
            ?? "unknown-meeting"
        let milliseconds = citation.timestamp * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= Double(Int.max)
        else { throw AskQualityBenchmarkError.invalidTimestamp }
        return AskQualityHitObservation(
            segmentID: segmentID,
            meetingID: meetingID,
            timestampMilliseconds: Int(milliseconds.rounded()),
            transcriptRevision: citation.transcriptRevision)
    }

    private static func deterministicUUID(
        namespace: String,
        identifier: String
    ) throws -> UUID {
        let digest = OperationFingerprint.make(
            version: namespace,
            components: [identifier])
        let compact = String(digest.prefix(32))
        let value = [
            compact.prefix(8),
            compact.dropFirst(8).prefix(4),
            compact.dropFirst(12).prefix(4),
            compact.dropFirst(16).prefix(4),
            compact.dropFirst(20).prefix(12)
        ].map(String.init).joined(separator: "-")
        guard let result = UUID(uuidString: value) else {
            throw AskQualityBenchmarkError.invalidFixture("invalid identity digest")
        }
        return result
    }
}

private struct AskQualityNoExpansion: AskQueryExpanding {
    func expand(_ question: String) -> [String] { [question] }
}

enum AskQualityPrivateJSONWriter {
    static func write(
        _ document: AskQualityObservationDocument,
        to output: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document) + Data("\n".utf8)
        let parent = output.deletingLastPathComponent()
        try prepareDirectory(parent)
        let temporary = parent.appendingPathComponent(
            ".\(output.lastPathComponent).\(UUID().uuidString).tmp")
        try publish(data, temporary: temporary, output: output, parent: parent)
    }

    private static func prepareDirectory(_ parent: URL) throws {
        var isDirectory: ObjCBool = false
        let parentExisted = FileManager.default.fileExists(
            atPath: parent.path,
            isDirectory: &isDirectory)
        if parentExisted && !isDirectory.boolValue {
            throw AskQualityBenchmarkError.outputPublicationFailed
        }
        if !parentExisted {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: parent.path)
        }
    }

    private static func publish(
        _ data: Data,
        temporary: URL,
        output: URL,
        parent: URL
    ) throws {
        var descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw AskQualityBenchmarkError.outputPublicationFailed
        }
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: temporary)
        }
        do {
            try writeAll(data, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0,
                  Darwin.close(descriptor) == 0
            else {
                descriptor = -1
                throw AskQualityBenchmarkError.outputPublicationFailed
            }
            descriptor = -1
            guard Darwin.link(temporary.path, output.path) == 0 else {
                if errno == EEXIST {
                    throw AskQualityBenchmarkError.outputAlreadyExists
                }
                throw AskQualityBenchmarkError.outputPublicationFailed
            }
            let directoryDescriptor = Darwin.open(parent.path, O_RDONLY)
            guard directoryDescriptor >= 0 else {
                throw AskQualityBenchmarkError.outputPublicationFailed
            }
            defer { Darwin.close(directoryDescriptor) }
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw AskQualityBenchmarkError.outputPublicationFailed
            }
        } catch let error as AskQualityBenchmarkError {
            throw error
        } catch {
            throw AskQualityBenchmarkError.outputPublicationFailed
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else {
                    throw AskQualityBenchmarkError.outputPublicationFailed
                }
                cursor = cursor.advanced(by: written)
                remaining -= written
            }
        }
    }
}
