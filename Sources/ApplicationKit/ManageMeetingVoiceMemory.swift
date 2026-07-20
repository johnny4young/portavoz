import DiarizationKit
import Foundation
import PortavozCore

public struct MeetingVoiceSuggestion: Equatable, Sendable {
    public let speakerLabel: String
    public let name: String
    public let distance: Float

    public init(speakerLabel: String, name: String, distance: Float) {
        self.speakerLabel = speakerLabel
        self.name = name
        self.distance = distance
    }
}

public protocol RememberedVoiceMemory: Sendable {
    func rememberedVoices() async throws -> [RememberedVoice]
    func rememberVoice(_ voice: RememberedVoice) async throws
}

public protocol MeetingVoiceprintExtracting: Sendable {
    func extractVoiceprints(
        from detail: MeetingLibraryDetail,
        speakerLabels: [String]
    ) async throws -> [String: Voiceprint]
}

public enum ManageMeetingVoiceMemoryAction: Sendable {
    case suggestions(meetingID: MeetingID)
    case canRemember(name: String)
    case remember(meetingID: MeetingID, speakerID: SpeakerID)
}

public struct ManageMeetingVoiceMemoryRequest: Sendable {
    public let action: ManageMeetingVoiceMemoryAction

    public init(action: ManageMeetingVoiceMemoryAction) {
        self.action = action
    }
}

public enum ManageMeetingVoiceMemoryResult: Equatable, Sendable {
    case suggestions([MeetingVoiceSuggestion])
    case canRemember(Bool)
    case remembered
    case insufficientAudio
}

public enum ManageMeetingVoiceMemoryError: Error, Equatable, LocalizedError, Sendable {
    case meetingNotFound
    case namedSpeakerNotFound

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound:
            "The meeting no longer exists."
        case .namedSpeakerNotFound:
            "Choose a named participant before remembering their voice."
        }
    }
}

/// Owns cross-meeting voice suggestion and explicit memory policy. The
/// concrete encrypted gallery, recording paths, and diarization model remain
/// outer adapters; no match mutates a speaker automatically.
public struct ManageMeetingVoiceMemory: ApplicationUseCase {
    private let library: QueryMeetingLibrary
    private let memory: any RememberedVoiceMemory
    private let extractor: any MeetingVoiceprintExtracting

    public init(
        library: QueryMeetingLibrary,
        memory: any RememberedVoiceMemory,
        extractor: any MeetingVoiceprintExtracting
    ) {
        self.library = library
        self.memory = memory
        self.extractor = extractor
    }

    public func execute(
        _ request: ManageMeetingVoiceMemoryRequest
    ) async throws -> ManageMeetingVoiceMemoryResult {
        switch request.action {
        case .suggestions(let meetingID):
            return try await suggestions(for: meetingID)
        case .canRemember(let name):
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .canRemember(false) }
            guard let voices = try? await memory.rememberedVoices() else {
                return .canRemember(true)
            }
            return .canRemember(!voices.contains {
                $0.name.compare(name, options: .caseInsensitive) == .orderedSame
            })
        case .remember(let meetingID, let speakerID):
            return try await remember(meetingID: meetingID, speakerID: speakerID)
        }
    }
}

private extension ManageMeetingVoiceMemory {
    func suggestions(
        for meetingID: MeetingID
    ) async throws -> ManageMeetingVoiceMemoryResult {
        guard let detail = try await library.detail(meetingID) else {
            throw ManageMeetingVoiceMemoryError.meetingNotFound
        }
        let targets = detail.speakers.filter {
            !$0.isMe && $0.displayName == nil
        }
        guard !targets.isEmpty,
              let voices = try? await memory.rememberedVoices(),
              !voices.isEmpty,
              let prints = try? await extractor.extractVoiceprints(
                from: detail,
                speakerLabels: targets.map(\.label)),
              !prints.isEmpty
        else { return .suggestions([]) }

        let matches = VoiceMatcher.matches(
            speakers: prints.map { ($0.key, $0.value.embedding) },
            gallery: voices)
        return .suggestions(matches.map {
            MeetingVoiceSuggestion(
                speakerLabel: $0.voiceLabel,
                name: $0.name,
                distance: $0.distance)
        })
    }

    func remember(
        meetingID: MeetingID,
        speakerID: SpeakerID
    ) async throws -> ManageMeetingVoiceMemoryResult {
        guard let detail = try await library.detail(meetingID) else {
            throw ManageMeetingVoiceMemoryError.meetingNotFound
        }
        guard let speaker = detail.speakers.first(where: {
            $0.id == speakerID && !$0.isMe
        }), let name = speaker.displayName, !name.isEmpty else {
            throw ManageMeetingVoiceMemoryError.namedSpeakerNotFound
        }
        guard let prints = try? await extractor.extractVoiceprints(
            from: detail,
            speakerLabels: [speaker.label]),
            let voiceprint = prints[speaker.label]
        else { return .insufficientAudio }

        try await memory.rememberVoice(RememberedVoice(
            name: name,
            embedding: voiceprint.embedding))
        return .remembered
    }
}
