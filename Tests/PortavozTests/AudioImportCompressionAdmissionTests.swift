import AVFoundation
import ApplicationKit
import Foundation
import GRDB
import PlatformKit
import PortavozCore
import Testing
import os

@testable import AudioPlaybackKit
@testable import StorageKit

struct AudioImportCompressionAdmissionTests {
    @Test(arguments: [false, true])
    func permissionReadFailurePreservesPlaybackButProviderCancellationStopsPreparation(cancelled: Bool) async throws {
        let fixture = try await CompressionAdmissionFixture(fileExtension: "wav")
        defer { fixture.base.remove() }
        let preparation = PrepareMeetingPlayback(
            resolver: fixture.resolver, compressionAdmission: FailingCompressionAdmission(cancelled: cancelled))
        let request = PrepareMeetingPlaybackRequest(relativeAudioDirectory: fixture.input.copyDirectory, segments: [])
        if cancelled {
            await #expect(throws: CancellationError.self) { _ = try await preparation.execute(request) }
            #expect(Task.isCancelled == false)
        } else {
            let prepared = try #require(try await preparation.execute(request))
            #expect(prepared.canCompressAudio == false)
            await prepared.session.invalidate()
        }
    }

    @Test(arguments: ["wav", "aiff"])
    func failedOwnedCopySurvivesCompressionRefusalAndRetry(fileExtension: String) async throws {
        let fixture = try await CompressionAdmissionFixture(fileExtension: fileExtension)
        defer { fixture.base.remove() }
        _ = try await fixture.base.store.failProcessingJob(
            fixture.job.id, owner: fixture.owner, failure: .init(code: "import.processing.failed"))
        let compressor = CompressionEncoderSpy()
        await #expect(throws: MeetingAudioCompressionError.unavailable) {
            _ = try await fixture.compression(compressor).execute(
                CompressMeetingAudioRequest(relativeAudioDirectory: fixture.input.copyDirectory))
        }
        #expect(compressor.calls == 0)
        let verified = try await fixture.base.files.verifyOwnedAudio(fixture.retained)
        #expect(verified.digest == fixture.retained.copiedAudioDigest)
        let playback = try await PrepareMeetingPlayback(
            resolver: fixture.resolver, compressionAdmission: fixture.base.store).execute(
                PrepareMeetingPlaybackRequest(relativeAudioDirectory: fixture.input.copyDirectory, segments: []))
        let prepared = try #require(playback)
        #expect(prepared.canCompressAudio == false)
        await prepared.session.invalidate()

        _ = try await fixture.base.store.retryAudioImport(for: fixture.input.meetingID)
        let processed = try await fixture.base.worker(ImportQueueProcessor()).execute(.init())
        #expect(processed == 1)
        #expect(try await fixture.base.store.canCompressMeetingAudio(
            relativeAudioDirectory: fixture.input.copyDirectory))
        _ = try await fixture.compression(compressor).execute(
            CompressMeetingAudioRequest(relativeAudioDirectory: fixture.input.copyDirectory))
        #expect(compressor.calls == 1)
        #expect(FileManager.default.fileExists(atPath: verified.fileURL.path) == false)
        let replacement = try #require(MeetingAudioLayout.channelFile(
            named: "system", in: verified.fileURL.deletingLastPathComponent()))
        #expect(replacement.pathExtension == "m4a")
        #expect(try AVAudioFile(forReading: replacement).length == 3_200)
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
    }

    @Test(arguments: [ProcessingJobState.pending, .running, .failed, .cancelled])
    func unfinishedJobsAndTrashRestoreKeepTheCopyProtected(state: ProcessingJobState) async throws {
        let fixture = try await CompressionAdmissionFixture(fileExtension: "wav")
        defer { fixture.base.remove() }
        switch state {
        case .pending:
            _ = try await fixture.base.store.suspendProcessingJob(fixture.job.id, owner: fixture.owner)
        case .failed:
            _ = try await fixture.base.store.failProcessingJob(
                fixture.job.id, owner: fixture.owner, failure: .init(code: "import.processing.failed"))
        case .cancelled:
            _ = try await fixture.base.store.cancelAudioImport(for: fixture.input.meetingID)
        case .running: break
        case .succeeded: Issue.record("The protected-state matrix excludes success.")
        }
        #expect(try await fixture.base.store.canCompressMeetingAudio(
            relativeAudioDirectory: fixture.input.copyDirectory) == false)
        try await fixture.base.store.delete(fixture.input.meetingID)
        #expect(try await fixture.base.store.canCompressMeetingAudio(
            relativeAudioDirectory: fixture.input.copyDirectory) == false)
        try await RestoreMeeting(store: fixture.base.store, acquisition: fixture.base.files)(fixture.input.meetingID)
        #expect(try await fixture.base.store.canCompressMeetingAudio(
            relativeAudioDirectory: fixture.input.copyDirectory) == false)
        #expect(try await fixture.base.files.verifyOwnedAudio(fixture.retained).digest == fixture.retained.copiedAudioDigest)
    }

    @Test(arguments: ["missing-input", "missing-job", "missing-job-alias", "payload", "fingerprint", "wrong-kind", "invalid-success", "owner-directory"])
    func missingOrInconsistentImportAuthorityFailsClosed(damage: String) async throws {
        let fixture = try await CompressionAdmissionFixture(fileExtension: "wav")
        defer { fixture.base.remove() }
        _ = try await fixture.base.store.suspendProcessingJob(fixture.job.id, owner: fixture.owner)
        _ = try await fixture.base.worker(ImportQueueProcessor()).execute(.init())
        let directory: String
        switch damage {
        case "missing-job-alias":
            directory = fixture.input.copyDirectory.replacingOccurrences(of: "/Imports/", with: "/imports/")
        case "owner-directory":
            directory = "Audio/\(fixture.input.meetingID.rawValue.uuidString)/Imports/\(UUID().uuidString)"
        default:
            directory = fixture.input.copyDirectory
        }
        try await fixture.base.store.database.write { database in
            switch damage {
            case "missing-input": try database.execute(sql: "DELETE FROM audioImportInput")
            case "missing-job": try database.execute(sql: "DELETE FROM processingJob")
            case "missing-job-alias":
                try database.execute(sql: "DELETE FROM processingJob")
                try database.execute(sql: "UPDATE meeting SET audioDirectory = ?", arguments: [directory])
            case "payload": try database.execute(sql: "UPDATE audioImportInput SET payloadDigest = 'corrupt'")
            case "fingerprint": try database.execute(sql: "UPDATE processingJob SET inputFingerprint = 'changed'")
            case "wrong-kind": try database.execute(sql: "UPDATE processingJob SET kind = 'transcribe-firstpass'")
            case "invalid-success": try database.execute(sql: "UPDATE processingJob SET finishedAt = NULL")
            case "owner-directory":
                try database.execute(sql: "UPDATE meeting SET audioDirectory = ?", arguments: [directory])
            default: Issue.record("Unknown authority damage.")
            }
        }
        #expect(try await fixture.base.store.canCompressMeetingAudio(relativeAudioDirectory: directory) == false)
    }

    @Test func nonImportRecordingRetainsCompressionAndAliasesAreRejected() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let meeting = Meeting(title: "Ordinary recording", startedAt: Date(), audioDirectory: "Audio/ordinary")
        try await fixture.store.save(meeting)
        let directory = fixture.root.appendingPathComponent("Audio/ordinary")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try CompressionAdmissionFixture.writeAudio(to: directory.appendingPathComponent("system.wav"))
        #expect(try await fixture.store.canCompressMeetingAudio(relativeAudioDirectory: "Audio/ordinary"))
        for alias in ["Audio/./ordinary", "Audio/ordinary/", "Audio//ordinary", "Audio/other/../ordinary",
                      "/Audio/ordinary", " Audio/ordinary", "Audio/missing"] {
            #expect(try await fixture.store.canCompressMeetingAudio(relativeAudioDirectory: alias) == false)
        }
        let compressor = CompressionEncoderSpy()
        _ = try await CompressMeetingAudio(resolver: CompressionChannels(root: fixture.root), compressor: compressor,
                                          compressionAdmission: fixture.store).execute(
            CompressMeetingAudioRequest(relativeAudioDirectory: "Audio/ordinary"))
        #expect(compressor.calls == 1)
        #expect(MeetingAudioLayout.channelFile(named: "system", in: directory)?.pathExtension == "m4a")
    }

    @Test(arguments: [false, true])
    func duplicateDirectoryOwnersDenyCompression(canonicalImport: Bool) async throws {
        let fixture = try await CompressionAdmissionFixture(fileExtension: "wav")
        defer { fixture.base.remove() }
        _ = try await fixture.base.store.suspendProcessingJob(fixture.job.id, owner: fixture.owner)
        _ = try await fixture.base.worker(ImportQueueProcessor()).execute(.init())
        let directory = canonicalImport ? fixture.input.copyDirectory : "Audio/legacy"
        if canonicalImport == false {
            try await fixture.base.store.save(Meeting(title: "Legacy", startedAt: Date(), audioDirectory: directory))
        }
        #expect(try await fixture.base.store.canCompressMeetingAudio(relativeAudioDirectory: directory))
        try await fixture.base.store.save(Meeting(title: "Aliased owner", startedAt: Date(), audioDirectory: directory))
        #expect(try await fixture.base.store.canCompressMeetingAudio(relativeAudioDirectory: directory) == false)
    }
}

private struct CompressionAdmissionFixture {
    let base: ImportQueueFixture
    let source: URL
    let original: Data
    let input: AudioImportRequest
    let retained: AudioImportRequest
    let job: ProcessingJob
    let owner = "compression-fixture"
    var resolver: CompressionChannels { CompressionChannels(root: base.root) }

    init(fileExtension: String) async throws {
        let base = try ImportQueueFixture()
        let source = base.directory.appendingPathComponent("original.\(fileExtension)")
        try Self.writeAudio(to: source)
        let input = try await base.files.prepareSelection(
            source, meetingID: MeetingID(), title: "Synthetic imported audio",
            preferences: .init(transcriptLanguage: .automatic, summaryLanguage: .followSpokenLanguage,
                               summaryFallbackLanguage: .english, vocabulary: []))
        _ = try await base.store.enqueueAudioImports([input])
        let job = try #require(try await base.store.claimNextProcessingJob(
            kinds: [.audioImport], owner: "compression-fixture", leaseDuration: 120))
        let copied = try await base.files.withAcquisitionAccess { try await base.files.copySelectedAudio(input) }
        retained = try await base.store.publishAudioImportCopy(
            for: job.id, owner: "compression-fixture", relativeDirectory: copied.relativeDirectory, digest: copied.digest)
        self.base = base
        self.source = source
        original = try Data(contentsOf: source)
        self.input = input
        self.job = job
    }

    func compression(_ compressor: CompressionEncoderSpy) -> CompressMeetingAudio {
        CompressMeetingAudio(resolver: resolver, compressor: compressor, compressionAdmission: base.store)
    }

    static func writeAudio(to file: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3_200))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Float(sin(2 * Double.pi * 220 * Double(index) / 16_000) * 0.1)
        }
        let output = try AVAudioFile(forWriting: file, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: file.pathExtension == "aiff"
        ])
        try output.write(from: buffer)
    }
}

private struct CompressionChannels: MeetingAudioChannelResolving {
    let root: URL
    func resolve(relativeAudioDirectory: String) -> MeetingAudioChannels {
        let directory = root.appendingPathComponent(relativeAudioDirectory)
        return MeetingAudioChannels(system: MeetingAudioLayout.channelFile(named: "system", in: directory), microphone: nil)
    }
}

private struct FailingCompressionAdmission: MeetingAudioCompressionChecking {
    let cancelled: Bool
    func canCompressMeetingAudio(relativeAudioDirectory: String) throws -> Bool {
        if cancelled { throw CancellationError() }
        throw MeetingAudioCompressionError.unavailable
    }
}

private struct CompressionEncoderSpy: MeetingAudioCompressing {
    private let counter = OSAllocatedUnfairLock(initialState: 0)
    var calls: Int { counter.withLock { $0 } }
    func totalBytes(of files: [URL]) -> Int64 { AudioTranscoder.totalBytes(of: files) }
    func compress(_ sources: [URL]) async throws -> [URL] {
        counter.withLock { $0 += 1 }
        return try await AudioTranscoder.toAAC(sources: sources, encoder: { source, output in
            try FileManager.default.copyItem(at: source, to: output)
        })
    }
}
