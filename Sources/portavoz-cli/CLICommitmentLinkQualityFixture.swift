import ApplicationKit
import CryptoKit
import Foundation
import PortavozCore
import StorageKit

struct CommitmentLinkQualityFixture: Decodable, Sendable {
    static let canonicalDigest =
        "e9ebeb86f832f726deb82ea5b08953808f23a3ac79ab8018375599d1a6971f0a"

    let schemaVersion: Int
    let kind: String
    let generation: String
    let contentSource: String
    let cases: [CommitmentLinkQualityCase]
    private(set) var fixtureSHA256 = ""

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, generation, contentSource, cases
    }

    fileprivate init(
        schemaVersion: Int,
        kind: String,
        generation: String,
        contentSource: String,
        cases: [CommitmentLinkQualityCase],
        fixtureSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.generation = generation
        self.contentSource = contentSource
        self.cases = cases
        self.fixtureSHA256 = fixtureSHA256
    }

    static func load(from url: URL) throws -> Self {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "fixture cannot be read")
        }
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "fixture exceeds 4 MiB")
        }
        let digest = try canonicalDigest(for: data)
        guard digest == canonicalDigest else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "fixture does not match the canonical public generation")
        }
        var fixture: Self
        do {
            fixture = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "fixture is not valid JSON")
        }
        fixture.fixtureSHA256 = digest
        try fixture.validate()
        return fixture
    }

    fileprivate static func canonicalDigest(for data: Data) throws -> String {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "fixture is not valid JSON")
        }
        let canonical: Data
        do {
            canonical = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "fixture cannot be canonicalized")
        }
        return SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    fileprivate func validate() throws {
        guard schemaVersion == 1,
              kind == "commitment-link-quality-fixture",
              generation == "public-synthetic-v1",
              contentSource == "public-synthetic-only",
              cases.count == 36
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "unsupported fixture schema or bounds")
        }
        try validateCases()
    }

    fileprivate func validateCases() throws {
        guard Set(cases.map(\.id)).count == cases.count else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "fixture case identities are not unique")
        }
        for fixtureCase in cases {
            try fixtureCase.validate()
        }
    }
}

struct CommitmentLinkPrivateAnonymization: Codable, Sendable, Equatable {
    let policy: String
    let reviewStatus: String
    let containsAudio: Bool
    let containsFilePaths: Bool
    let containsAccountIdentifiers: Bool
    let containsDirectIdentifiers: Bool

    fileprivate func validate() throws {
        guard policy == "owner-reviewed-redaction-v1",
              reviewStatus == "owner-reviewed",
              !containsAudio,
              !containsFilePaths,
              !containsAccountIdentifiers,
              !containsDirectIdentifiers
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private anonymization attestation is invalid")
        }
    }
}

struct CommitmentLinkPrivateQualityFixture: Sendable {
    static let kind = "commitment-link-private-quality-fixture"
    static let contentSource = "private-anonymized-local"

    let productFixture: CommitmentLinkQualityFixture
    let anonymization: CommitmentLinkPrivateAnonymization

    var generation: String { productFixture.generation }
    var fixtureSHA256: String { productFixture.fixtureSHA256 }
    var cases: [CommitmentLinkQualityCase] { productFixture.cases }

    static func load(from url: URL) throws -> Self {
        try CommitmentLinkPrivateFixtureFilePolicy.validate(url)
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture cannot be read")
        }
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture exceeds 4 MiB")
        }
        try validateExactShape(in: data)
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture is not valid JSON")
        }
        let digest = try CommitmentLinkQualityFixture.canonicalDigest(for: data)
        let fixture = CommitmentLinkQualityFixture(
            schemaVersion: payload.schemaVersion,
            kind: payload.kind,
            generation: payload.generation,
            contentSource: payload.contentSource,
            cases: payload.cases,
            fixtureSHA256: digest)
        try payload.anonymization.validate()
        try fixture.validatePrivateContract()
        return Self(
            productFixture: fixture,
            anonymization: payload.anonymization)
    }

    private struct Payload: Decodable {
        let schemaVersion: Int
        let kind: String
        let generation: String
        let contentSource: String
        let anonymization: CommitmentLinkPrivateAnonymization
        let cases: [CommitmentLinkQualityCase]
    }

    private static func validateExactShape(in data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture is not valid JSON")
        }
        let root = try exactObject(
            object,
            label: "private fixture",
            keys: [
                "schemaVersion", "kind", "generation", "contentSource",
                "anonymization", "cases"
            ])
        _ = try exactObject(
            root["anonymization"],
            label: "private fixture anonymization",
            keys: [
                "policy", "reviewStatus", "containsAudio",
                "containsFilePaths", "containsAccountIdentifiers",
                "containsDirectIdentifiers"
            ])
        guard let cases = root["cases"] as? [Any] else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture cases are not an array")
        }
        for (caseIndex, value) in cases.enumerated() {
            try validateExactCase(value, index: caseIndex)
        }
    }

    private static func validateExactCase(
        _ value: Any,
        index caseIndex: Int
    ) throws {
        let fixtureCase = try exactObject(
            value,
            label: "private fixture case \(caseIndex)",
            keys: ["id", "language", "class", "candidate", "targets", "expected"])
        let candidate = try exactObject(
            fixtureCase["candidate"],
            label: "private fixture candidate \(caseIndex)",
            keys: [
                "sourceMeetingID", "actionItemID", "language", "text",
                "assignee"
            ])
        try validateExactAssignee(
            candidate["assignee"],
            label: "private fixture candidate assignee \(caseIndex)")
        _ = try exactObject(
            fixtureCase["expected"],
            label: "private fixture expected \(caseIndex)",
            keys: [
                "semanticRelevantCommitmentIDs", "linkableCommitmentIDs",
                "mustAbstain"
            ])
        guard let targets = fixtureCase["targets"] as? [Any] else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture targets are not an array")
        }
        for (targetIndex, targetValue) in targets.enumerated() {
            try validateExactTarget(
                targetValue,
                caseIndex: caseIndex,
                targetIndex: targetIndex)
        }
    }

    private static func validateExactTarget(
        _ value: Any,
        caseIndex: Int,
        targetIndex: Int
    ) throws {
        let target = try exactObject(
            value,
            label: "private fixture target \(caseIndex).\(targetIndex)",
            keys: [
                "id", "title", "status", "assignee",
                "sourceMeetingIDs", "evidence"
            ])
        try validateExactAssignee(
            target["assignee"],
            label: "private fixture target assignee \(caseIndex).\(targetIndex)")
        guard let evidence = target["evidence"] as? [Any] else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture evidence is not an array")
        }
        for (evidenceIndex, evidenceValue) in evidence.enumerated() {
            _ = try exactObject(
                evidenceValue,
                label: "private fixture evidence \(caseIndex).\(targetIndex).\(evidenceIndex)",
                keys: ["id", "meetingID", "language", "text"])
        }
    }

    private static func validateExactAssignee(
        _ value: Any?,
        label: String
    ) throws {
        _ = try exactObject(
            value,
            label: label,
            keys: ["kind", "id"])
    }

    private static func exactObject(
        _ value: Any?,
        label: String,
        keys: Set<String>
    ) throws -> [String: Any] {
        guard let object = value as? [String: Any],
              Set(object.keys) == keys
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "\(label) is not exact")
        }
        return object
    }
}

private enum CommitmentLinkPrivateFixtureFilePolicy {
    static func validate(_ url: URL) throws {
        let values: URLResourceValues
        let attributes: [FileAttributeKey: Any]
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey
            ])
            attributes = try FileManager.default.attributesOfItem(
                atPath: url.path)
        } catch {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture metadata cannot be inspected")
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              permissions == 0o600
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture must be a regular non-symlink mode-0600 file")
        }
    }
}

struct CommitmentLinkQualityCase: Decodable, Sendable {
    let id: String
    let language: String
    let `class`: String
    let candidate: CommitmentLinkQualityCandidate
    let targets: [CommitmentLinkQualityTarget]
    let expected: CommitmentLinkQualityExpected

    func validate() throws {
        let targetIDs = targets.map(\.id)
        let evidenceIDs = targets.flatMap { $0.evidence.map(\.id) }
        guard !id.isEmpty,
              ["en", "es", "mixed"].contains(language),
              !`class`.isEmpty,
              (1...200).contains(targets.count),
              Set(targetIDs).count == targetIDs.count,
              Set(evidenceIDs).count == evidenceIDs.count,
              expected.linkableCommitmentIDs.allSatisfy(targetIDs.contains),
              expected.semanticRelevantCommitmentIDs.allSatisfy(targetIDs.contains),
              Set(expected.linkableCommitmentIDs).isSubset(
                  of: Set(expected.semanticRelevantCommitmentIDs)),
              expected.mustAbstain == expected.linkableCommitmentIDs.isEmpty
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "case \(id) is inconsistent")
        }
        try candidate.validate()
        for target in targets { try target.validate() }
    }
}

struct CommitmentLinkQualityCandidate: Decodable, Sendable {
    let sourceMeetingID: String
    let actionItemID: String
    let language: String
    let text: String
    let assignee: CommitmentLinkQualityAssignee

    func validate() throws {
        guard !sourceMeetingID.isEmpty,
              !actionItemID.isEmpty,
              ["en", "es", "mixed"].contains(language),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 500
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "candidate is invalid")
        }
        try assignee.validate()
    }
}

struct CommitmentLinkQualityTarget: Decodable, Sendable {
    let id: String
    let title: String
    let status: String
    let assignee: CommitmentLinkQualityAssignee
    let sourceMeetingIDs: [String]
    let evidence: [CommitmentLinkQualityEvidence]

    func validate() throws {
        guard !id.isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["confirmed", "done", "dismissed"].contains(status),
              (1...20).contains(sourceMeetingIDs.count),
              Set(sourceMeetingIDs).count == sourceMeetingIDs.count,
              (1...20).contains(evidence.count),
              evidence.allSatisfy({ sourceMeetingIDs.contains($0.meetingID) })
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "target \(id) is invalid")
        }
        try assignee.validate()
    }
}

struct CommitmentLinkQualityEvidence: Decodable, Sendable {
    let id: String
    let meetingID: String
    let language: String
    let text: String
}

struct CommitmentLinkQualityAssignee: Codable, Sendable, Equatable, Hashable {
    let kind: String
    let id: String?

    func validate() throws {
        let valid = switch kind {
        case "person": id?.isEmpty == false
        case "me", "unassigned": id == nil
        default: false
        }
        guard valid else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "assignee is invalid")
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, id }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if let id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encodeNil(forKey: .id)
        }
    }
}

struct CommitmentLinkQualityExpected: Decodable, Sendable {
    let semanticRelevantCommitmentIDs: [String]
    let linkableCommitmentIDs: [String]
    let mustAbstain: Bool
}

private extension CommitmentLinkQualityFixture {
    static let privateClassCounts = [
        "continuation": 12,
        "ambiguous": 3,
        "self-continuation": 3,
        "wrong-person": 3,
        "no-overlap": 3,
        "same-meeting": 3,
        "inactive-target": 3,
        "dismissed-target": 3,
        "unknown-owner": 3
    ]

    func validatePrivateContract() throws {
        guard schemaVersion == 1,
              kind == CommitmentLinkPrivateQualityFixture.kind,
              generation.hasPrefix("private-anonymized-"),
              Self.isSafePrivateIdentifier(generation),
              contentSource == CommitmentLinkPrivateQualityFixture.contentSource,
              cases.count == 36
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture schema or generation is invalid")
        }
        try validateCases()

        let languageCounts = Dictionary(
            grouping: cases,
            by: \.language).mapValues(\.count)
        let classCounts = Dictionary(
            grouping: cases,
            by: \.`class`).mapValues(\.count)
        let linkableCount = cases.filter {
            !$0.expected.linkableCommitmentIDs.isEmpty
        }.count
        guard languageCounts == ["en": 12, "es": 12, "mixed": 12],
              classCounts == Self.privateClassCounts,
              linkableCount == 18,
              cases.filter(\.expected.mustAbstain).count == 18
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture balance is invalid")
        }
        for fixtureCase in cases {
            try Self.validatePrivateCase(fixtureCase)
        }
    }

    static func validatePrivateCase(
        _ fixtureCase: CommitmentLinkQualityCase
    ) throws {
        let candidate = fixtureCase.candidate
        guard isSafePrivateIdentifier(fixtureCase.id),
              isSafePrivateIdentifier(candidate.sourceMeetingID),
              isSafePrivateIdentifier(candidate.actionItemID)
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture contains an unsafe identity")
        }
        try validatePrivateAssignee(candidate.assignee)
        try validatePrivateText(candidate.text)

        let targets = Dictionary(
            uniqueKeysWithValues: fixtureCase.targets.map { ($0.id, $0) })
        for target in fixtureCase.targets {
            guard isSafePrivateIdentifier(target.id),
                  target.sourceMeetingIDs.allSatisfy(isSafePrivateIdentifier)
            else {
                throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                    "private fixture contains an unsafe target identity")
            }
            try validatePrivateAssignee(target.assignee)
            try validatePrivateText(target.title)
            for evidence in target.evidence {
                guard isSafePrivateIdentifier(evidence.id),
                      isSafePrivateIdentifier(evidence.meetingID),
                      ["en", "es", "mixed"].contains(evidence.language)
                else {
                    throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                        "private fixture contains invalid evidence")
                }
                try validatePrivateText(evidence.text)
            }
        }
        for targetID in fixtureCase.expected.linkableCommitmentIDs {
            guard let target = targets[targetID],
                  target.status == "confirmed",
                  candidate.assignee.kind != "unassigned",
                  candidate.assignee == target.assignee,
                  !target.sourceMeetingIDs.contains(candidate.sourceMeetingID)
            else {
                throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                    "private fixture link truth is not legally admissible")
            }
        }
    }

    static func validatePrivateAssignee(
        _ assignee: CommitmentLinkQualityAssignee
    ) throws {
        if let id = assignee.id, !isSafePrivateIdentifier(id) {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture contains an unsafe assignee identity")
        }
    }

    static func validatePrivateText(_ value: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 500,
              !value.contains("\0")
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture contains invalid text")
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        for (label, expression) in privateTextPatterns
        where expression.firstMatch(in: value, range: range) != nil {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "private fixture contains an obvious \(label)")
        }
    }

    static func isSafePrivateIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...96).contains(bytes.count),
              let first = bytes.first,
              isLowercaseASCII(first) || isDigitASCII(first)
        else { return false }
        return bytes.allSatisfy {
            isLowercaseASCII($0) || isDigitASCII($0)
                || $0 == 46 || $0 == 95 || $0 == 45
        }
    }

    static func isLowercaseASCII(_ byte: UInt8) -> Bool {
        (97...122).contains(byte)
    }

    static func isDigitASCII(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    static let privateTextPatterns: [(String, NSRegularExpression)] = [
        ("email address", regularExpression(
            pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            options: [.caseInsensitive])),
        ("URL", regularExpression(
            pattern: #"(?:https?://|\bwww\.)"#,
            options: [.caseInsensitive])),
        ("filesystem path", regularExpression(
            pattern: #"(?:/Users/|/home/|[A-Z]:\\)"#,
            options: [.caseInsensitive])),
        ("UUID", regularExpression(
            pattern: #"\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b"#,
            options: [.caseInsensitive])),
        ("phone-like number", regularExpression(
            pattern: #"(?<!\w)(?:\+?\d[\s().-]*){8,}(?!\w)"#))
    ]

    private static func regularExpression(
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: options)
        else {
            preconditionFailure("invalid private fixture safety pattern")
        }
        return expression
    }
}
