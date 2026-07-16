import PortavozCore

/// Content evidence for one channel that will actually reach the Refine
/// transcriber. `contentFingerprint` is already a digest, never a path.
public struct RefineTranscriptionChannelEvidence: Equatable, Sendable {
    public let channel: AudioChannel
    public let contentFingerprint: String

    public init(channel: AudioChannel, contentFingerprint: String) {
        self.channel = channel
        self.contentFingerprint = contentFingerprint
    }
}

public struct RefineTranscriptionOperationInput: Sendable {
    public let meetingID: MeetingID
    public let sourceTranscriptRevision: Int
    public let providerID: String
    public let modelID: String
    public let modelRevision: String?
    public let languageHint: String?
    public let vocabulary: [String]
    public let channels: [RefineTranscriptionChannelEvidence]

    public init(
        meetingID: MeetingID,
        sourceTranscriptRevision: Int,
        providerID: String,
        modelID: String,
        modelRevision: String?,
        languageHint: String?,
        vocabulary: [String],
        channels: [RefineTranscriptionChannelEvidence]
    ) {
        self.meetingID = meetingID
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.providerID = providerID
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.languageHint = languageHint
        self.vocabulary = vocabulary
        self.channels = channels
    }
}

/// Exact privacy-safe identity for one user-reviewed Refine transcript pass.
/// A pass may invoke Whisper for multiple channels, but it produces one
/// coherent draft and therefore one durable generation envelope on Apply.
public enum RefineTranscriptionOperationFingerprint {
    private static let version = "refine-transcription-v1"

    public static func compute(_ input: RefineTranscriptionOperationInput) -> String? {
        let identity = [input.providerID, input.modelID]
            + input.channels.map(\.contentFingerprint)
        guard input.sourceTranscriptRevision >= 0,
              !input.channels.isEmpty,
              identity.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              input.modelRevision.map(Self.isNotBlank) ?? true,
              input.languageHint.map(Self.isNotBlank) ?? true,
              Set(input.channels.map(\.channel.rawValue)).count == input.channels.count
        else { return nil }

        let orderedChannels = input.channels.sorted {
            $0.channel.rawValue < $1.channel.rawValue
        }
        let components = [
            input.meetingID.rawValue.uuidString,
            String(input.sourceTranscriptRevision),
            input.providerID,
            input.modelID,
            input.modelRevision == nil ? "model-revision:none" : "model-revision:some",
            input.modelRevision ?? "",
            input.languageHint == nil ? "language:automatic" : "language:fixed",
            input.languageHint ?? "",
            String(input.vocabulary.count)
        ] + input.vocabulary + [String(orderedChannels.count)] + orderedChannels.flatMap {
            [$0.channel.rawValue, $0.contentFingerprint]
        }
        return OperationFingerprint.make(version: version, components: components)
    }

    private static func isNotBlank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
