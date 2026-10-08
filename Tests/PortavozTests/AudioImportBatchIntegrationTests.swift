import AVFoundation
import ApplicationKit
import Foundation
import PortavozCore
import XCTest
@testable import portavoz_app

final class AudioImportBatchIntegrationTests: XCTestCase {
    func testNativeBatchPublishesEveryPageWithoutDiarizerAssets() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let processor = try XCTUnwrap(AudioImportUITestFixture.makeIfRequested(arguments: [
            "-use-temp-store", "-audio-import-ui-fixture", "-audio-import-diarizer-unavailable"
        ]))
        let sources = try makeAudioSelection(in: fixture.directory)
        let originals = try sources.map { try Data(contentsOf: $0) }
        var inputs: [AudioImportRequest] = []
        for (index, source) in sources.enumerated() {
            inputs.append(try await fixture.files.prepareSelection(
                source, meetingID: MeetingID(), title: "Synthetic audio \(index)",
                preferences: .init(transcriptLanguage: .automatic,
                                   summaryLanguage: .followSpokenLanguage,
                                   summaryFallbackLanguage: .english, vocabulary: [])))
        }
        _ = try await fixture.store.enqueueAudioImports(inputs)
        let worker = ProcessAudioImports(store: fixture.store, files: fixture.files,
                                        makeProcessor: { processor }, summaries: processor)
        let processed = try await worker.execute(.init())
        XCTAssertEqual(processed, 21)
        let first = try await fixture.store.audioImportQueuePage()
        let last = try await fixture.store.audioImportQueuePage(offset: 20)
        XCTAssertEqual(first.total, 21)
        XCTAssertEqual(first.unfinished, 0)
        XCTAssertEqual(first.entries.count, 20)
        XCTAssertEqual(last.entries.count, 1)
        XCTAssertFalse(last.hasNext)
        XCTAssertEqual(Set((first.entries + last.entries).map(\.id)), Set(inputs.map(\.meetingID)))
        for (index, input) in inputs.enumerated() {
            let loaded = try await fixture.store.detail(input.meetingID)
            let detail = try XCTUnwrap(loaded)
            XCTAssertEqual(detail.meeting.lifecycleState, .ready)
            XCTAssertEqual(detail.segments.map(\.text), ["No envíes 2. Don’t send 2."])
            XCTAssertTrue(detail.speakers.isEmpty)
            let job = try XCTUnwrap((first.entries + last.entries).first { $0.id == input.meetingID })
            XCTAssertEqual(job.job.state, .succeeded)
            let copy = fixture.root.appendingPathComponent(input.copyDirectory + "/system.wav")
            XCTAssertEqual(try Data(contentsOf: copy), originals[index])
            XCTAssertEqual(try Data(contentsOf: sources[index]), originals[index])
        }
    }

    private func makeAudioSelection(in directory: URL) throws -> [URL] {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        return try (0..<21).map { index in
            // Distinct PCM makes swapped copies observable; the first is silent.
            for sample in 0..<1_600 {
                samples[sample] = Float(index) / 64 * (sample.isMultiple(of: 2) ? 1 : -1)
            }
            let url = directory.appendingPathComponent("Audio \(index).wav")
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        }
    }
}
