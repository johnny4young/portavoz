import AVFoundation
import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit
import Testing

struct ImportedAudioReuseTests {
    // These are the formats explicitly accepted by Library's audio selection.
    @Test(arguments: [AudioChannel.system, .microphone], ["m4a", "wav", "mp3", "aac", "aiff", "aif", "caf", "m4b"])
    func selectedFormatsRemainResolvableAndPortable(channel: AudioChannel, fileExtension: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("\(channel.rawValue).\(fileExtension)".utf8)
        let file = directory.appendingPathComponent("\(channel.rawValue).\(fileExtension)")
        try bytes.write(to: file)
        #expect(MeetingAudioLayout.channelFile(named: channel.rawValue, in: directory) == file)
        let exported = try #require(ExportMeetingBundleAttachment(
            channel: channel, fileExtension: fileExtension.uppercased(), data: bytes))
        let imported = try ImportedMeetingBundleAttachment(
            name: channel.rawValue, fileExtension: " \(exported.fileExtension) ", data: exported.data)
        #expect(imported.channel == channel)
        #expect(imported.fileExtension == fileExtension)
        #expect(imported.data == bytes)
    }

    @Test func existingFormatsRetainPriorityOverImportedFormats() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for fileExtension in ["aiff", "wav", "caf", "m4a"] {
            try Data(fileExtension.utf8).write(to: directory.appendingPathComponent("system.\(fileExtension)"))
        }
        for expected in ["m4a", "caf", "wav", "aiff"] {
            let resolved = try #require(MeetingAudioLayout.channelFile(named: "system", in: directory))
            #expect(resolved.pathExtension == expected)
            try FileManager.default.removeItem(at: resolved)
        }
    }

    @Test func partialAndUnsupportedFilesStayInvisible() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["system.partial.caf", "system.partial.mp3", "system.aiff.partial", "system.txt"] {
            try Data("unfinished".utf8).write(to: directory.appendingPathComponent(name))
        }
        #expect(MeetingAudioLayout.channelFile(named: "system", in: directory) == nil)
    }

    @Test func nativeAIFFImportAndBundleRoundTripPreservePlayableBytes() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("Selected audio.aiff")
        try writeAIFF(to: source)
        let original = try Data(contentsOf: source)
        let input = try await fixture.files.prepareSelection(
            source, meetingID: MeetingID(), title: "Imported AIFF",
            preferences: .init(transcriptLanguage: .automatic, summaryLanguage: .followSpokenLanguage,
                               summaryFallbackLanguage: .english, vocabulary: []))
        _ = try await fixture.store.enqueueAudioImports([input])
        let processed = try await fixture.worker(ImportQueueProcessor()).execute(.init())
        #expect(processed == 1)
        let loaded = try await fixture.store.detail(input.meetingID)
        let detail = try #require(loaded)
        #expect(detail.meeting.lifecycleState == .ready)
        let directory = fixture.root.appendingPathComponent(input.copyDirectory)
        let copied = try #require(MeetingAudioLayout.channelFile(named: "system", in: directory))
        #expect(try AVAudioFile(forReading: copied).length == 3_200)
        let exported = try #require(ExportMeetingBundleAttachment(
            channel: .system, fileExtension: copied.pathExtension, data: Data(contentsOf: copied)))
        let bundle = MeetingBundle(meeting: detail.meeting, speakers: detail.speakers, segments: detail.segments,
                                   audioFiles: [.init(name: exported.channel.rawValue,
                                                      fileExtension: exported.fileExtension, data: exported.data)])
        let remapped = try MeetingBundle.decode(bundle.encoded()).remappedForImport()
        #expect(remapped.meeting.id != input.meetingID)
        #expect(remapped.meeting.audioDirectory == nil)
        let attachment = try #require(remapped.audioFiles?.first)
        let imported = try ImportedMeetingBundleAttachment(
            name: attachment.name, fileExtension: attachment.fileExtension, data: attachment.data)
        let restoredDirectory = fixture.root.appendingPathComponent("Audio/\(remapped.meeting.id.rawValue.uuidString)")
        try FileManager.default.createDirectory(at: restoredDirectory, withIntermediateDirectories: true)
        try imported.data.write(to: restoredDirectory.appendingPathComponent(
            "\(imported.channel.rawValue).\(imported.fileExtension)"))
        let restored = try #require(MeetingAudioLayout.channelFile(named: "system", in: restoredDirectory))
        #expect(try AVAudioFile(forReading: restored).length == 3_200)
        #expect(try Data(contentsOf: restored) == original)
        #expect(try Data(contentsOf: source) == original)
        #expect(remapped.segments.map(\.text) == detail.segments.map(\.text))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeAIFF(to file: URL) throws {
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
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true
        ])
        try output.write(from: buffer)
    }
}
