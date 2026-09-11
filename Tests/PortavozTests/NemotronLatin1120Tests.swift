import FluidAudio
import Foundation
import PortavozCore
import XCTest

@testable import ModelStoreKit
@testable import TranscriptionKit
@testable import portavoz_cli

final class NemotronLatin1120Tests: XCTestCase {
    private let meetingID = MeetingID()

    func testResearchDescriptorIsPinnedLeanAndNonServing() throws {
        let descriptor = ModelCatalog.nemotronLatin1120
        XCTAssertEqual(descriptor.artifacts.count, 10)
        XCTAssertEqual(descriptor.tasks, [.liveTranscription])
        XCTAssertEqual(descriptor.license, "OpenMDW-1.1")
        XCTAssertFalse(descriptor.resolveBase.absoluteString.contains("/main"))
        XCTAssertTrue(descriptor.resolveBase.absoluteString.contains(descriptor.revision))
        XCTAssertNotEqual(
            ModelCatalog.recommended(for: .liveTranscription)?.id,
            descriptor.id)

        let roots = Set(descriptor.artifacts.compactMap {
            $0.path.split(separator: "/").first.map(String.init)
        })
        XCTAssertEqual(
            roots,
            ["encoder.mlmodelc", "decoder_joint.mlmodelc", "metadata.json", "tokenizer.json"])
        XCTAssertGreaterThan(descriptor.totalSizeBytes, 580_000_000)
        XCTAssertLessThan(descriptor.totalSizeBytes, 600_000_000)
        XCTAssertEqual(Set(descriptor.artifacts.map(\.path)).count, descriptor.artifacts.count)
        for artifact in descriptor.artifacts {
            XCTAssertGreaterThan(artifact.sizeBytes, 0)
            XCTAssertFalse(artifact.path.hasPrefix("/"))
            XCTAssertEqual(artifact.sha256.count, 64)
            XCTAssertTrue(artifact.sha256.allSatisfy {
                $0.isHexDigit && (!$0.isLetter || $0.isLowercase)
            })
        }
    }

    func testBenchmarkEngineChoiceIsExplicit() {
        XCTAssertEqual(
            BenchLiveEngineChoice(rawValue: "nemotron-latin-1120"),
            .nemotronLatin1120)
        XCTAssertNil(BenchLiveEngineChoice(rawValue: "nemotron"))
        XCTAssertEqual(
            BenchLiveEngineChoice.usage,
            "parakeet|speech|nemotron-latin-1120")
    }

    func testHintsRequireExplicitEnglishOrSpanishBeforeLoadingModels() throws {
        XCTAssertEqual(
            try NemotronLatin1120Engine.validate(
                hints: TranscriptionHints(language: "EN_us")),
            "en")
        XCTAssertEqual(
            try NemotronLatin1120Engine.validate(
                hints: TranscriptionHints(language: "es-CO")),
            "es")

        XCTAssertThrowsError(try NemotronLatin1120Engine.validate(
            hints: TranscriptionHints())) { error in
            XCTAssertEqual(error as? NemotronLatin1120Error, .languageRequired)
        }
        XCTAssertThrowsError(try NemotronLatin1120Engine.validate(
            hints: TranscriptionHints(language: "fr"))) { error in
            XCTAssertEqual(error as? NemotronLatin1120Error, .unsupportedLanguage("fr"))
        }
        XCTAssertThrowsError(try NemotronLatin1120Engine.validate(
            hints: TranscriptionHints(language: "es", vocabulary: ["Portavoz"]))) { error in
            XCTAssertEqual(error as? NemotronLatin1120Error, .vocabularyUnsupported)
        }
    }

    func testTimingCursorPreservesTokensWithSharedTimestamps() throws {
        let timings = [
            timing("▁hola", 1, 1.2, confidence: 0.8),
            timing("▁mundo", 1, 1.2, confidence: 1.2)
        ]
        let segment = try XCTUnwrap(NemotronSegmentMapper.segment(
            timings: timings,
            emittedCount: 1,
            meetingID: meetingID,
            channel: .system,
            language: "es"))
        XCTAssertEqual(segment.text, "mundo")
        XCTAssertEqual(segment.startTime, 1)
        XCTAssertEqual(segment.endTime, 1.2)
        XCTAssertEqual(segment.confidence, 1)
        XCTAssertTrue(segment.isFinal)
    }

    func testTimingCursorRegressionFailsClosed() {
        XCTAssertThrowsError(try NemotronSegmentMapper.segment(
            timings: [timing("▁hola", 0, 0.2)],
            emittedCount: 2,
            meetingID: meetingID,
            channel: .microphone,
            language: "es")) { error in
            XCTAssertEqual(
                error as? NemotronLatin1120Error,
                .timingCursorRegressed(emitted: 2, available: 1))
        }
    }

    func testInvalidModelTimingFailsClosed() {
        XCTAssertThrowsError(try NemotronSegmentMapper.segment(
            timings: [timing("▁hola", .nan, 0.2)],
            emittedCount: 0,
            meetingID: meetingID,
            channel: .microphone,
            language: "es")) { error in
            XCTAssertEqual(
                error as? NemotronLatin1120Error,
                .invalidTokenTiming(index: 0))
        }
    }

    func testNonMonotonicModelTimingFailsClosed() {
        XCTAssertThrowsError(try NemotronSegmentMapper.segment(
            timings: [
                timing("▁hola", 1, 1.2),
                timing("▁atrás", 0.8, 1.1)
            ],
            emittedCount: 0,
            meetingID: meetingID,
            channel: .microphone,
            language: "es")) { error in
            XCTAssertEqual(
                error as? NemotronLatin1120Error,
                .invalidTokenTiming(index: 1))
        }
    }

    func testExactModelLayoutRejectsAnUnpinnedOptionalBundle() throws {
        let directory = try makeModelLayout()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNoThrow(try NemotronModelLayout.validate(directory: directory))

        let unpinned = directory.appendingPathComponent(
            "decoder_joint_argmax.mlmodelc/model.mil")
        try FileManager.default.createDirectory(
            at: unpinned.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("unpinned".utf8).write(to: unpinned)
        XCTAssertThrowsError(try NemotronModelLayout.validate(directory: directory)) { error in
            XCTAssertEqual(
                error as? NemotronLatin1120Error,
                .invalidModelLayout("decoder_joint_argmax.mlmodelc"))
        }
    }

    func testExactModelLayoutRejectsAMissingPinnedFile() throws {
        let directory = try makeModelLayout()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("tokenizer.json"))
        XCTAssertThrowsError(try NemotronModelLayout.validate(directory: directory)) { error in
            XCTAssertEqual(
                error as? NemotronLatin1120Error,
                .invalidModelLayout("tokenizer.json"))
        }
    }

    func testExactModelLayoutRejectsASymlinkedPinnedFile() throws {
        let directory = try makeModelLayout()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = directory.appendingPathComponent("tokenizer.json")
        try FileManager.default.removeItem(at: tokenizer)
        try FileManager.default.createSymbolicLink(
            at: tokenizer,
            withDestinationURL: directory.appendingPathComponent("metadata.json"))
        XCTAssertThrowsError(try NemotronModelLayout.validate(directory: directory)) { error in
            XCTAssertEqual(
                error as? NemotronLatin1120Error,
                .invalidModelLayout("tokenizer.json"))
        }
    }

    func testFinalTextWithoutTimingsUsesBoundedAudioDuration() throws {
        let segment = try XCTUnwrap(NemotronSegmentMapper.finalSegment(
            text: " texto final ",
            timings: [],
            emittedCount: 0,
            audioDuration: .infinity,
            meetingID: meetingID,
            channel: .room,
            language: "es"))
        XCTAssertEqual(segment.text, "texto final")
        XCTAssertEqual(segment.startTime, 0)
        XCTAssertEqual(segment.endTime, 0)
        XCTAssertNil(segment.confidence)
    }

    func testFinishDoesNotDuplicateAlreadyEmittedTimings() throws {
        let timings = [timing("▁hola", 0, 0.2)]
        let segment = try NemotronSegmentMapper.finalSegment(
            text: "hola",
            timings: timings,
            emittedCount: timings.count,
            audioDuration: 1,
            meetingID: meetingID,
            channel: .microphone,
            language: "es")
        XCTAssertNil(segment)
    }

    private func timing(
        _ token: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        confidence: Float = 0.9
    ) -> TokenTiming {
        TokenTiming(
            token: token,
            tokenId: 0,
            startTime: start,
            endTime: end,
            confidence: confidence)
    }

    private func makeModelLayout() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-nemotron-layout-\(UUID().uuidString)")
        do {
            for artifact in ModelCatalog.nemotronLatin1120.artifacts {
                let file = directory.appendingPathComponent(artifact.path)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: file)
            }
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
