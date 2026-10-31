import ApplicationKit
import DiarizationKit
import PortavozCore

/// Disposable launches with `-seed-voice-match`: one remembered voice that every
/// requested speaker matches exactly, so no gallery, Keychain or model is touched.
struct MeetingVoiceMatchFixture: RememberedVoiceMemory, MeetingVoiceprintExtracting {
    static let argument = "-seed-voice-match"
    static let rememberedName = "Marta"
    private static let embedding: [Float] = [1, 0, 0]

    func rememberedVoices() async throws -> [RememberedVoice] {
        [RememberedVoice(name: Self.rememberedName, embedding: Self.embedding)]
    }

    func rememberVoice(_ voice: RememberedVoice) async throws {}

    func extractVoiceprints(
        from detail: MeetingLibraryDetail,
        speakerLabels: [String]
    ) async throws -> [String: Voiceprint] {
        Dictionary(uniqueKeysWithValues: speakerLabels.map { ($0, Voiceprint(embedding: Self.embedding)) })
    }
}
