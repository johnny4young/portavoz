import Foundation

/// Opaque identity of the effective user correction overlay for one accepted
/// transcript revision. It is derived from immutable event identities rather
/// than a device-local counter, so independently replayed sync history
/// converges on the same value.
public struct TranscriptCorrectionRevision: RawRepresentable, Hashable, Sendable {
    public static let accepted = TranscriptCorrectionRevision(rawValue: "accepted")!
    /// Fail-closed presentation sentinel used only when an injected read model
    /// contains malformed correction history. Storage never publishes it.
    public static let unavailable = TranscriptCorrectionRevision(uncheckedRawValue: "unavailable")

    public let rawValue: String

    public init?(rawValue: String) {
        let isDigest = rawValue.count == 64 && rawValue.allSatisfy(\.isHexDigit)
        guard rawValue == "accepted" || isDigest else { return nil }
        self.rawValue = rawValue.lowercased()
    }

    private init(uncheckedRawValue: String) {
        rawValue = uncheckedRawValue
    }

    public static func current(
        meetingID: MeetingID,
        baseTranscriptRevision: Int,
        history: [TranscriptCorrectionEvent]
    ) throws -> TranscriptCorrectionRevision {
        let effective = try TranscriptCorrectionPolicy.effectiveCorrections(
            in: history,
            meetingID: meetingID,
            baseTranscriptRevision: baseTranscriptRevision)
        guard !effective.isEmpty else { return .accepted }
        let value = OperationFingerprint.make(
            version: "transcript-correction-revision-v1",
            components: [
                meetingID.rawValue.uuidString,
                String(baseTranscriptRevision)
            ] + effective.map { $0.id.uuidString }.sorted())
        guard let revision = TranscriptCorrectionRevision(rawValue: value) else {
            throw TranscriptCorrectionValidationError.invalidMetadata(effective[0].id)
        }
        return revision
    }

    public var isAccepted: Bool { self == .accepted }
}

/// Correction lineage carried by generated-artifact provenance.
///
/// Missing metadata is compatible only with an uncorrected accepted reading;
/// malformed metadata always fails closed.
public enum TranscriptCorrectionArtifactSource: Equatable, Sendable {
    case legacyAccepted
    case revision(TranscriptCorrectionRevision)
    case invalid

    public init(generationConfigJSON: String) {
        guard let data = generationConfigJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let config = object as? [String: Any]
        else {
            self = .invalid
            return
        }
        guard let raw = config["sourceCorrectionRevision"] else {
            self = .legacyAccepted
            return
        }
        guard let value = raw as? String,
              let revision = TranscriptCorrectionRevision(rawValue: value)
        else {
            self = .invalid
            return
        }
        self = .revision(revision)
    }

    public func matches(_ current: TranscriptCorrectionRevision) -> Bool {
        switch self {
        case .legacyAccepted:
            current.isAccepted
        case .revision(let revision):
            revision == current
        case .invalid:
            false
        }
    }
}

public enum TranscriptRevisionArtifactSource: Equatable, Sendable {
    case legacy
    case revision(Int)
    case invalid

    public init(generationConfigJSON: String) {
        guard let config = generationConfiguration(generationConfigJSON) else {
            self = .invalid
            return
        }
        guard let raw = config["sourceTranscriptRevision"] else {
            self = .legacy
            return
        }
        guard let revision = raw as? Int, revision >= 0 else {
            self = .invalid
            return
        }
        self = .revision(revision)
    }

    public func matches(_ current: Int, allowsLegacy: Bool = false) -> Bool {
        switch self {
        case .legacy:
            allowsLegacy
        case .revision(let revision):
            revision == current
        case .invalid:
            false
        }
    }
}

public extension GenerationRun {
    var transcriptCorrectionSource: TranscriptCorrectionArtifactSource {
        TranscriptCorrectionArtifactSource(generationConfigJSON: configJSON)
    }

    var transcriptRevisionSource: TranscriptRevisionArtifactSource {
        TranscriptRevisionArtifactSource(generationConfigJSON: configJSON)
    }
}

private func generationConfiguration(_ json: String) -> [String: Any]? {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data)
    else { return nil }
    return object as? [String: Any]
}
