import AVFoundation
import Foundation
import PortavozCore
import Testing
import os

@testable import ApplicationKit
@testable import AudioPlaybackKit
@testable import StorageKit

struct TrailingSilenceTests {
    @Test
    func cutsTenSecondsAfterTheLastPhraseOnlyForALongTail() {
        let meetingID = MeetingID()
        let segments = [
            segment(meetingID, 0, 40), segment(meetingID, 50, 380),
        ]
        let cut = 380 + TrailingSilence.keptAfterSpeech
        let shortest = 380 + TrailingSilence.minimumLength
        #expect(TrailingSilence.cutoff(segments: segments, duration: 10_000) == cut)
        #expect(TrailingSilence.cutoff(segments: segments, duration: shortest - 1) == nil)
        #expect(TrailingSilence.cutoff(segments: segments, duration: shortest) == cut)
        #expect(TrailingSilence.cutoff(segments: [], duration: 10_000) == nil)
    }

    @Test
    func keepsSpeechEndingAtTheAudioBoundary() {
        let meetingID = MeetingID()
        let segments = [segment(meetingID, 0, 100), segment(meetingID, 900, 1_000)]
        #expect(TrailingSilence.cutoff(segments: segments, duration: 1_000) == nil)
    }

    @Test
    func ignoresRowsThatEndPastTheAudio() {
        let meetingID = MeetingID()
        let segments = [segment(meetingID, 0, 100), segment(meetingID, 900, 1_200)]
        #expect(TrailingSilence.cutoff(segments: segments, duration: 1_000) == 100 + TrailingSilence.keptAfterSpeech)
    }
}

struct MeetingStoreAudioTrimTests {
    @Test
    func trimTombstonesLaterRowsClipsTheCrossingRowAndEndsTheMeeting() async throws {
        let store = try MeetingStore.inMemory()
        let start = Date(timeIntervalSince1970: 1_000)
        let meeting = Meeting(
            title: "Trim", startedAt: start, endedAt: start.addingTimeInterval(9_000),
            audioDirectory: "Audio/trim", transcriptRevision: 2)
        try await store.save(meeting)
        let kept = segment(meeting.id, 0, 300)
        let crossing = segment(meeting.id, 380, 400)
        let later = segment(meeting.id, 500, 520)
        try await store.save([kept, crossing, later])

        await #expect(throws: StorageError.self) {
            try await store.trimMeetingTail(meetingID: meeting.id, expectedTranscriptRevision: 1, cutoff: 390)
        }
        try await store.trimMeetingTail(meetingID: meeting.id, expectedTranscriptRevision: 2, cutoff: 390)

        let detail = try #require(try await store.detail(meeting.id))
        #expect(detail.segments.map(\.id) == [kept.id, crossing.id])
        #expect(detail.segments.last?.endTime == 390)
        #expect(detail.meeting.endedAt == start.addingTimeInterval(390))
        #expect(detail.meeting.transcriptRevision == 3)
    }

    @Test
    func trimRejectsAnInvalidCutoff() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Trim", startedAt: Date(), audioDirectory: "Audio/trim")
        try await store.save(meeting)
        await #expect(throws: StorageError.self) {
            try await store.trimMeetingTail(meetingID: meeting.id, expectedTranscriptRevision: 0, cutoff: 0)
        }
    }

    @Test(arguments: [MeetingLifecycleState.ready, .processing, .needsAttention])
    func onlySettledMeetingsCanBeTrimmed(state: MeetingLifecycleState) async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Trim", startedAt: Date(), audioDirectory: "Audio/trim", lifecycleState: state)
        try await store.save(meeting)
        let allowed = try await store.canTrimMeetingAudio(
            meetingID: meeting.id, relativeAudioDirectory: "Audio/trim")
        #expect(allowed == (state == .ready))
        #expect(try await store.canTrimMeetingAudio(
            meetingID: meeting.id, relativeAudioDirectory: "Audio/other") == false)
    }
}

struct AudioTailTrimmerTests {
    @Test(arguments: ["caf", "wav"])
    func stagesVerifiedCopiesAndSwapsThemIn(fileExtension: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("system.\(fileExtension)")
        try writeTone(to: file, seconds: 3)

        let staged = try await AudioTailTrimmer.stage([file], cutoff: 1)
        #expect(staged.count == 1)
        #expect(try audioDuration(file) == 3)
        try AudioTailTrimmer.commit(originals: [file], staged: staged)

        #expect(abs(try audioDuration(file) - 1) < 0.01)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [file.lastPathComponent])
    }

    @Test
    func failedSwapRestoresEveryOriginal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = directory.appendingPathComponent("system.caf")
        let microphone = directory.appendingPathComponent("microphone.caf")
        try writeTone(to: system, seconds: 3)
        try writeTone(to: microphone, seconds: 3)
        let staged = try await AudioTailTrimmer.stage([system, microphone], cutoff: 1)
        try FileManager.default.removeItem(at: staged[1])

        #expect(throws: (any Error).self) {
            try AudioTailTrimmer.commit(originals: [system, microphone], staged: staged)
        }
        #expect(try audioDuration(system) == 3)
        #expect(try audioDuration(microphone) == 3)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            == ["system.caf", "microphone.caf"])
    }

    @Test
    func unsupportedFormatsLeaveNothingBehind() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("system.caf")
        let bad = directory.appendingPathComponent("microphone.ogg")
        try writeTone(to: good, seconds: 2)
        try Data([0]).write(to: bad)

        await #expect(throws: AudioTailTrimmerError.unsupportedFormat("ogg")) {
            _ = try await AudioTailTrimmer.stage([good, bad], cutoff: 1)
        }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            == ["system.caf", "microphone.ogg"])
    }
}

struct TrimMeetingAudioTailUseCaseTests {
    @Test
    func stagesBeforeTheTranscriptCommitAndSwapsLast() async throws {
        let log = TrimLog()
        let useCase = TrimMeetingAudioTail(
            resolver: TrimResolverFake(), trimmer: TrimmerSpy(log: log), store: TrimStoreSpy(log: log))
        let removed = try await useCase.execute(request(duration: 10_000))

        #expect(removed == 10_000 - 390)
        #expect(log.events == ["admit", "stage 390.0", "commit transcript 390.0 r4", "swap"])
    }

    @Test
    func transcriptFailureDiscardsTheStagedCopies() async throws {
        let log = TrimLog()
        let useCase = TrimMeetingAudioTail(
            resolver: TrimResolverFake(), trimmer: TrimmerSpy(log: log),
            store: TrimStoreSpy(log: log, failCommit: true))

        await #expect(throws: StorageError.self) { _ = try await useCase.execute(request(duration: 10_000)) }
        #expect(log.events == ["admit", "stage 390.0", "discard"])
    }

    @Test
    func refusesShortTailsAndUnsettledMeetings() async throws {
        let log = TrimLog()
        let short = TrimMeetingAudioTail(
            resolver: TrimResolverFake(), trimmer: TrimmerSpy(log: log), store: TrimStoreSpy(log: log))
        await #expect(throws: TrimMeetingAudioTailError.nothingToTrim) {
            _ = try await short.execute(request(duration: 500))
        }
        let busy = TrimMeetingAudioTail(
            resolver: TrimResolverFake(), trimmer: TrimmerSpy(log: log),
            store: TrimStoreSpy(log: log, admitted: false))
        await #expect(throws: TrimMeetingAudioTailError.unavailable) {
            _ = try await busy.execute(request(duration: 10_000))
        }
        #expect(log.events == ["admit"])
    }

    private func request(duration: TimeInterval) -> TrimMeetingAudioTailRequest {
        let meetingID = MeetingID()
        return TrimMeetingAudioTailRequest(
            meetingID: meetingID, relativeAudioDirectory: "Audio/trim", transcriptRevision: 4,
            segments: [segment(meetingID, 0, 380)], duration: duration)
    }
}

private func segment(_ meetingID: MeetingID, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
    TranscriptSegment(
        meetingID: meetingID, channel: .system, text: "Line \(Int(start))", startTime: start, endTime: end,
        isFinal: true)
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("trim-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func audioDuration(_ url: URL) throws -> TimeInterval {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
}

private func writeTone(to url: URL, seconds: Double) throws {
    let rate = 16_000.0
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(rate * seconds)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channel = try #require(buffer.floatChannelData)[0]
    for index in 0..<Int(frames) {
        channel[index] = 0.25 * Float(sin(2 * Double.pi * 440 * Double(index) / rate))
    }
    try file.write(from: buffer)
}

private final class TrimLog: Sendable {
    private let storage = OSAllocatedUnfairLock<[String]>(initialState: [])
    var events: [String] { storage.withLock { $0 } }
    func append(_ event: String) { storage.withLock { $0.append(event) } }
}

private struct TrimResolverFake: MeetingAudioChannelResolving {
    func resolve(relativeAudioDirectory: String) throws -> MeetingAudioChannels {
        MeetingAudioChannels(
            system: URL(fileURLWithPath: "/tmp/system.caf"), microphone: URL(fileURLWithPath: "/tmp/microphone.caf"))
    }
}

private struct TrimmerSpy: MeetingAudioTrimming {
    let log: TrimLog

    func stageTrim(_ files: [URL], cutoff: TimeInterval) async throws -> [URL] {
        log.append("stage \(cutoff)")
        return files
    }

    func commitTrim(originals: [URL], staged: [URL]) throws { log.append("swap") }

    func discardTrim(_ staged: [URL]) { log.append("discard") }
}

private struct TrimStoreSpy: MeetingAudioTrimStore {
    let log: TrimLog
    var failCommit = false
    var admitted = true

    func canTrimMeetingAudio(meetingID: MeetingID, relativeAudioDirectory: String) async throws -> Bool {
        log.append("admit")
        return admitted
    }

    func trimMeetingTail(meetingID: MeetingID, expectedTranscriptRevision: Int, cutoff: TimeInterval) async throws {
        if failCommit {
            throw StorageError.staleRefineDraft(meetingID: meetingID, expected: expectedTranscriptRevision, actual: 5)
        }
        log.append("commit transcript \(cutoff) r\(expectedTranscriptRevision)")
    }
}
