import ApplicationKit
import DiarizationKit
import Foundation
import PortavozCore
import StorageKit

extension AppServices {
    func meetingDetailVoiceSuggestions(
        _ meetingID: MeetingID
    ) async throws -> [MeetingVoiceSuggestion] {
        guard case .suggestions(let suggestions) = try await meetingVoiceMemory.execute(
            .init(action: .suggestions(meetingID: meetingID)))
        else { return [] }
        return suggestions
    }

    func canRememberMeetingDetailVoice(named name: String) async -> Bool {
        guard case .canRemember(let canRemember) = try? await meetingVoiceMemory.execute(
            .init(action: .canRemember(name: name)))
        else { return true }
        return canRemember
    }

    func rememberMeetingDetailVoice(
        meetingID: MeetingID,
        speakerID: SpeakerID
    ) async throws -> ManageMeetingVoiceMemoryResult {
        try await meetingVoiceMemory.execute(.init(
            action: .remember(meetingID: meetingID, speakerID: speakerID)))
    }

    private var meetingVoiceMemory: ManageMeetingVoiceMemory {
        ManageMeetingVoiceMemory(
            library: .local(store: store),
            memory: AppRememberedVoiceMemory(
                gallery: voiceGallery,
                disabled: ProcessInfo.processInfo.arguments.contains("-use-temp-store")),
            extractor: AppMeetingVoiceprintExtractor(services: self))
    }
}

private struct AppRememberedVoiceMemory: RememberedVoiceMemory {
    let gallery: VoiceGallery
    let disabled: Bool

    func rememberedVoices() async throws -> [RememberedVoice] {
        guard !disabled else { return [] }
        let gallery = gallery
        return try await Task.detached(priority: .utility) {
            try gallery.voices()
        }.value
    }

    func rememberVoice(_ voice: RememberedVoice) async throws {
        guard !disabled else { return }
        let gallery = gallery
        try await Task.detached(priority: .utility) {
            try gallery.remember(voice)
        }.value
    }
}

@MainActor
private final class AppMeetingVoiceprintExtractor: MeetingVoiceprintExtracting {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    func extractVoiceprints(
        from detail: MeetingLibraryDetail,
        speakerLabels: [String]
    ) async throws -> [String: Voiceprint] {
        guard let services else { throw CancellationError() }
        guard let relative = detail.meeting.audioDirectory else { return [:] }
        let directory = RecordingsLocation.shared.resolve(relative)
        guard let systemURL = MeetingAudioLayout.channelFile(
            named: AudioChannel.system.rawValue,
            in: directory)
        else { return [:] }

        let labels = Set(speakerLabels)
        let labelsByID = Dictionary(
            uniqueKeysWithValues: detail.speakers.map { ($0.id, $0.label) })
        var ranges: [String: [ClosedRange<TimeInterval>]] = [:]
        for segment in detail.segments {
            guard segment.channel == .system,
                  segment.endTime > segment.startTime,
                  let speakerID = segment.speakerID,
                  let label = labelsByID[speakerID],
                  labels.contains(label)
            else { continue }
            ranges[label, default: []].append(segment.startTime...segment.endTime)
        }
        guard !ranges.isEmpty else { return [:] }

        let runtime = try await services.acquireDiarizationRuntime()
        defer {
            _ = services.finishDiarizationRuntime(runtime)
            services.scheduleRecordingEnginesRelease()
        }
        let diarizer = services.makeDiarizer(from: runtime)
        return try await diarizer.extractVoiceprints(
            fromFile: systemURL,
            rangesBySpeaker: ranges)
    }
}
