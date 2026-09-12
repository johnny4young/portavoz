import AVFoundation
import ApplicationKit
import DiarizationKit
import Foundation
import PortavozCore
import TranscriptionKit

/// Real file/SQLite/controller/UI journeys use deterministic recognition, never
/// a model-quality claim. Both flags are required; ordinary audio import cannot
/// select this processor or disable its configured summary provider.
actor AudioImportUITestFixture: ImportMeetingProcessor, ImportMeetingSummaryProviderResolver {
    private let holdsFirst: Bool
    private var attempts = 0
    private var rejectsCancellation: Bool
    private var rejectsDeletion: Bool
    nonisolated let clockOffset: TimeInterval

    static func makeIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> AudioImportUITestFixture? {
        guard arguments.contains("-use-temp-store"), arguments.contains("-audio-import-ui-fixture") else { return nil }
        return AudioImportUITestFixture(
            holdsFirst: arguments.contains("-audio-import-hold-first"),
            rejectsMutations: arguments.contains("-audio-import-fail-mutations-once"),
            clockOffset: arguments.contains("-audio-import-expired-owner") ? 121 : 0)
    }

    private init(holdsFirst: Bool, rejectsMutations: Bool, clockOffset: TimeInterval) {
        self.holdsFirst = holdsFirst
        rejectsCancellation = rejectsMutations
        rejectsDeletion = rejectsMutations
        self.clockOffset = clockOffset
    }

    func beforeCancellation() throws {
        guard rejectsCancellation else { return }
        rejectsCancellation = false
        throw AudioImportQueueError.storage
    }

    func beforeLibraryDeletion() throws {
        guard rejectsDeletion else { return }
        rejectsDeletion = false
        throw AudioImportQueueError.storage
    }

    func prepareTranscriber(progress: @escaping ImportMeetingProgressHandler) {}
    func prepareDiarizer() {}

    func transcribe(audio: ImportedMeetingAudio, meetingID: MeetingID,
                    languageHint: String?, vocabulary: [String]) async throws -> FileTranscription {
        attempts += 1
        if holdsFirst, attempts == 1 { try await Task.sleep(for: .seconds(60)) }
        let file = try AVAudioFile(forReading: audio.fileURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let text = "No envíes 2. Don’t send 2."
        return FileTranscription(text: text,
                                 segments: [.init(meetingID: meetingID, channel: .system, text: text,
                                                  startTime: 0, endTime: duration)],
                                 audioDuration: duration, processingTime: 0)
    }
    func diarize(audio: ImportedMeetingAudio) -> [SpeakerTurn] { [] }
    func scheduleIdleRelease() {}
    func resolveImportMeetingSummaryProvider() -> ImportMeetingSummaryProviderResolution { .unavailable }
}
