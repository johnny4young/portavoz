import FluidAudio
import Foundation
import PortavozCore
import XCTest

@testable import ModelStoreKit
@testable import TranscriptionKit

// MARK: - Catalog

final class ModelCatalogTests: XCTestCase {
    func testParakeetDescriptorIsWellFormed() {
        let model = ModelCatalog.parakeetTdtV3
        XCTAssertEqual(model.artifacts.count, 21)
        // Must be the folder FluidAudio's loader resolves (repo minus
        // "-coreml") or it silently re-downloads the model unverified.
        XCTAssertEqual(model.folderName, "parakeet-tdt-0.6b-v3")
        XCTAssertTrue(model.tasks.contains(.liveTranscription))
        XCTAssertTrue(model.tasks.contains(.finalTranscription))

        for artifact in model.artifacts {
            XCTAssertEqual(artifact.sha256.count, 64, "sha256 must be 64 hex chars: \(artifact.path)")
            XCTAssertTrue(
                artifact.sha256.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) },
                "sha256 must be lowercase hex: \(artifact.path)")
            XCTAssertGreaterThan(artifact.sizeBytes, 0)
            XCTAssertFalse(artifact.path.hasPrefix("/"), "artifact paths are relative")
        }

        // The exact file set FluidAudio's v3 int8 loader requires.
        let bundles = Set(model.artifacts.map { $0.path.components(separatedBy: "/").first! })
        XCTAssertEqual(
            bundles,
            [
                "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                "JointDecisionv3.mlmodelc", "parakeet_vocab.json",
            ])

        // int8 subset only: ~483 MB, not the full 3 GB repo.
        XCTAssertGreaterThan(model.totalSizeBytes, 450_000_000)
        XCTAssertLessThan(model.totalSizeBytes, 550_000_000)
    }

    func testDownloadURLsArePinnedToARevision() {
        let model = ModelCatalog.parakeetTdtV3
        XCTAssertFalse(model.revision.isEmpty)
        XCTAssertFalse(model.resolveBase.absoluteString.contains("/main"))
        XCTAssertTrue(model.resolveBase.absoluteString.contains(model.revision))

        let url = model.downloadURL(for: model.artifacts[0]).absoluteString
        XCTAssertTrue(url.hasPrefix(model.resolveBase.absoluteString))
        XCTAssertTrue(url.hasSuffix(model.artifacts[0].path))
    }

    func testRecommendedRouting() {
        XCTAssertEqual(ModelCatalog.recommended(for: .liveTranscription)?.id, "parakeet-tdt-0.6b-v3-coreml")
        // D7: the final pass routes to Whisper, never one global model.
        XCTAssertEqual(ModelCatalog.recommended(for: .finalTranscription)?.id, "whisper-large-v3-turbo")
        XCTAssertNil(ModelCatalog.recommended(for: .summarization))
    }

    func testWhisperDescriptorsAreWellFormed() {
        let model = ModelCatalog.whisperLargeV3Turbo
        XCTAssertEqual(model.artifacts.count, 24)
        XCTAssertTrue(model.resolveBase.absoluteString.contains(model.revision))
        XCTAssertGreaterThan(model.totalSizeBytes, 1_500_000_000)
        let bundles = Set(model.artifacts.map { $0.path.components(separatedBy: "/").first! })
        XCTAssertEqual(
            bundles,
            [
                "AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc",
                "TextDecoderContextPrefill.mlmodelc", "config.json", "generation_config.json",
            ])

        let tokenizer = ModelCatalog.whisperTokenizer
        // WhisperKit's loader looks for tokenizer.json at the folder top
        // level — that file missing means silent network fallback.
        XCTAssertTrue(tokenizer.artifacts.contains { $0.path == "tokenizer.json" })
        XCTAssertEqual(tokenizer.artifacts.count, 3)
        for artifact in model.artifacts + tokenizer.artifacts {
            XCTAssertEqual(artifact.sha256.count, 64)
        }
    }

    func testWhisperSegmentTextCleaning() {
        XCTAssertEqual(
            WhisperEngine.cleanSegmentText("<|0.00|> Hola a todos.<|4.20|>"),
            "Hola a todos.")
        XCTAssertEqual(WhisperEngine.cleanSegmentText("  sin tokens  "), "sin tokens")
        XCTAssertEqual(WhisperEngine.cleanSegmentText("<|es|><|transcribe|>"), "")
    }
}

// MARK: - Store

final class ModelStoreTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    func testSHA256MatchesKnownVector() throws {
        let file = workspace.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(
            try ModelStore.sha256(of: file),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// End-to-end offline: "downloads" from file:// URLs, verifies, installs.
    func testEnsureAvailableDownloadsAndVerifies() async throws {
        let (descriptor, _) = try makeFixtureModel()
        let store = ModelStore(rootDirectory: workspace.appendingPathComponent("store"))

        let directory = try await store.ensureAvailable(descriptor)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("bundle.mlmodelc/weights/weight.bin").path))

        let report = await store.verify(descriptor)
        XCTAssertTrue(report.isComplete)
    }

    func testVerifyDetectsMissingAndCorrupted() async throws {
        let (descriptor, _) = try makeFixtureModel()
        let store = ModelStore(rootDirectory: workspace.appendingPathComponent("store"))
        let directory = try await store.ensureAvailable(descriptor)

        // Corrupt one file, delete another.
        try Data("tampered".utf8).write(
            to: directory.appendingPathComponent("bundle.mlmodelc/weights/weight.bin"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("vocab.json"))

        let report = await store.verify(descriptor)
        XCTAssertEqual(report.corrupted, ["bundle.mlmodelc/weights/weight.bin"])
        XCTAssertEqual(report.missing, ["vocab.json"])
        XCTAssertFalse(report.isComplete)

        // A second ensureAvailable heals both.
        _ = try await store.ensureAvailable(descriptor)
        let healed = await store.verify(descriptor)
        XCTAssertTrue(healed.isComplete)
    }

    func testChecksumMismatchRejectsDownload() async throws {
        let (descriptor, source) = try makeFixtureModel()
        // Attacker swaps the upstream file after we pinned its hash — same
        // byte count on purpose, so only the sha256 check can catch it.
        let original = try Data(contentsOf: source.appendingPathComponent("vocab.json"))
        try Data(repeating: UInt8(ascii: "x"), count: original.count).write(
            to: source.appendingPathComponent("vocab.json"))

        let store = ModelStore(rootDirectory: workspace.appendingPathComponent("store"))
        do {
            _ = try await store.ensureAvailable(descriptor)
            XCTFail("expected checksumMismatch")
        } catch let error as ModelStore.ModelStoreError {
            guard case .checksumMismatch(let path, _, _) = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
            XCTAssertEqual(path, "vocab.json")
        }

        // The rejected file must not be installed.
        let installed = await store.directory(for: descriptor)
            .appendingPathComponent("vocab.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
    }

    /// Two-artifact fixture "repo" served over file:// URLs.
    private func makeFixtureModel() throws -> (ModelDescriptor, sourceDirectory: URL) {
        let source = workspace.appendingPathComponent("upstream", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("bundle.mlmodelc/weights"),
            withIntermediateDirectories: true)

        let weight = Data((0..<4096).map { UInt8($0 % 251) })
        let vocab = Data(#"{"0": "▁hola"}"#.utf8)
        try weight.write(to: source.appendingPathComponent("bundle.mlmodelc/weights/weight.bin"))
        try vocab.write(to: source.appendingPathComponent("vocab.json"))

        let descriptor = ModelDescriptor(
            id: "fixture",
            tasks: [.liveTranscription],
            displayName: "Fixture",
            folderName: "fixture-model",
            resolveBase: source,
            revision: "test",
            artifacts: [
                ModelArtifact(
                    path: "bundle.mlmodelc/weights/weight.bin",
                    sha256: try ModelStore.sha256(
                        of: source.appendingPathComponent("bundle.mlmodelc/weights/weight.bin")),
                    sizeBytes: weight.count),
                ModelArtifact(
                    path: "vocab.json",
                    sha256: try ModelStore.sha256(of: source.appendingPathComponent("vocab.json")),
                    sizeBytes: vocab.count),
            ],
            minimumRAMGB: 1,
            license: "MIT"
        )
        return (descriptor, source)
    }
}

// MARK: - Scheduler

final class TranscriptionSchedulerTests: XCTestCase {
    /// D7: a live job must complete while a batch job is still holding the
    /// batch slot. If live were queued behind batch this test would hang.
    func testLiveNeverWaitsForBatch() async throws {
        let scheduler = TranscriptionScheduler()
        let gate = Gate()

        let batch = Task {
            try await scheduler.batch {
                await gate.wait()
                return "batch"
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)  // let batch take the slot

        let live = await scheduler.live { "live" }
        XCTAssertEqual(live, "live")

        await gate.open()
        let batchResult = try await batch.value
        XCTAssertEqual(batchResult, "batch")
    }

    func testBatchSlotIsSerialFIFO() async throws {
        let scheduler = TranscriptionScheduler()
        let gate = Gate()
        let log = Recorder()

        let first = Task {
            try await scheduler.batch {
                await gate.wait()
                await log.add("first-end")
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let second = Task {
            try await scheduler.batch {
                await log.add("second-start")
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        // Second must still be queued: the slot is held by first.
        let before = await log.events
        XCTAssertTrue(before.isEmpty)

        await gate.open()
        _ = try await first.value
        _ = try await second.value

        let events = await log.events
        XCTAssertEqual(events, ["first-end", "second-start"])
    }
}

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor Recorder {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

// MARK: - Segment mapping

final class ParakeetSegmentMapperTests: XCTestCase {
    private let meeting = MeetingID()

    func testLiveUpdateBecomesSegmentWithAbsoluteTimes() {
        let segment = ParakeetSegmentMapper.segment(
            text: " hola mundo ",
            isConfirmed: true,
            confidence: 0.93,
            tokenTimings: [
                timing("▁hola", 120.0, 120.4),
                timing("▁mundo", 120.5, 121.0),
            ],
            meetingID: meeting,
            channel: .system,
            language: "es",
            fallbackTime: 0
        )
        XCTAssertNotNil(segment)
        XCTAssertEqual(segment?.text, "hola mundo")
        XCTAssertEqual(segment?.startTime, 120.0)
        XCTAssertEqual(segment?.endTime, 121.0)
        XCTAssertEqual(segment?.isFinal, true)
        XCTAssertEqual(segment?.channel, .system)
        XCTAssertEqual(segment?.language, "es")
        XCTAssertEqual(segment!.confidence!, 0.93, accuracy: 0.0001)
    }

    func testEmptyUpdateIsDropped() {
        let segment = ParakeetSegmentMapper.segment(
            text: "   ",
            isConfirmed: false,
            confidence: 0.5,
            tokenTimings: [],
            meetingID: meeting,
            channel: .microphone,
            language: nil,
            fallbackTime: 10
        )
        XCTAssertNil(segment)
    }

    /// Sliding windows re-decode the left context on every update; tokens
    /// at or before the last emitted edge must be cut, keeping the fresh tail.
    func testOverlappingReDecodedTokensAreCut() {
        let segment = ParakeetSegmentMapper.segment(
            text: "texto viejo repetido y algo nuevo",
            isConfirmed: true,
            confidence: 0.9,
            tokenTimings: [
                timing("▁texto", 10.0, 10.3),
                timing("▁viejo", 10.4, 10.8),
                timing("▁nuevo", 12.1, 12.6),
            ],
            meetingID: meeting,
            channel: .microphone,
            language: nil,
            fallbackTime: 11.0  // everything before this was already emitted
        )
        XCTAssertEqual(segment?.text, "nuevo")
        XCTAssertEqual(segment?.startTime, 12.1)
        XCTAssertEqual(segment?.endTime, 12.6)
    }

    func testPureReDecodeUpdateIsDropped() {
        let segment = ParakeetSegmentMapper.segment(
            text: "todo esto ya se había emitido",
            isConfirmed: true,
            confidence: 0.95,
            tokenTimings: [timing("▁ya", 5.0, 5.4), timing("▁emitido", 5.5, 6.0)],
            meetingID: meeting,
            channel: .microphone,
            language: nil,
            fallbackTime: 6.0
        )
        XCTAssertNil(segment)
    }

    func testMissingTimingsFallBackToPreviousEdge() {
        let segment = ParakeetSegmentMapper.segment(
            text: "sin timings",
            isConfirmed: false,
            confidence: 0.7,
            tokenTimings: [],
            meetingID: meeting,
            channel: .microphone,
            language: nil,
            fallbackTime: 42.5
        )
        XCTAssertEqual(segment?.startTime, 42.5)
        XCTAssertEqual(segment?.endTime, 42.5)
        XCTAssertEqual(segment?.isFinal, false)
    }

    func testBatchSplitsAtPauses() {
        let timings = [
            timing("▁primera", 0.0, 0.5),
            timing("▁frase", 0.6, 1.0),
            // 2.5 s pause — new segment
            timing("▁segunda", 3.5, 4.0),
            timing("▁frase", 4.1, 4.5),
        ]
        let segments = ParakeetSegmentMapper.segments(
            fromBatchText: "primera frase segunda frase",
            tokenTimings: timings,
            audioDuration: 5.0,
            confidence: 0.9,
            meetingID: meeting,
            channel: .system,
            language: nil
        )
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "primera frase")
        XCTAssertEqual(segments[1].text, "segunda frase")
        XCTAssertEqual(segments[0].endTime, 1.0)
        XCTAssertEqual(segments[1].startTime, 3.5)
        XCTAssertTrue(segments.allSatisfy(\.isFinal))
    }

    /// TDT timings carry no real gaps (token end = next token start), so
    /// sentence punctuation must cut even with zero pause between tokens.
    func testBatchSplitsAfterSentencePunctuation() {
        let timings = [
            timing("▁hola", 0.0, 0.5),
            timing("▁mundo.", 0.5, 1.0),
            timing("▁sigo", 1.0, 1.5),
            timing("▁hablando", 1.5, 2.0),
        ]
        let segments = ParakeetSegmentMapper.segments(
            fromBatchText: "hola mundo. sigo hablando",
            tokenTimings: timings,
            audioDuration: 2.0,
            confidence: 0.9,
            meetingID: meeting,
            channel: .system,
            language: nil
        )
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "hola mundo.")
        XCTAssertEqual(segments[1].text, "sigo hablando")
        XCTAssertEqual(segments[1].startTime, 1.0)
    }

    func testBatchWithoutTimingsYieldsSingleSegment() {
        let segments = ParakeetSegmentMapper.segments(
            fromBatchText: "todo el archivo",
            tokenTimings: [],
            audioDuration: 93.0,
            confidence: 0.88,
            meetingID: meeting,
            channel: .system,
            language: "es"
        )
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].startTime, 0)
        XCTAssertEqual(segments[0].endTime, 93.0)
        XCTAssertEqual(segments[0].text, "todo el archivo")
    }

    func testLongSegmentsSplitAtMaxDuration() {
        // 40 s of continuous tokens, one per second: must split before 30 s.
        let timings = (0..<40).map { second in
            timing("▁t\(second)", TimeInterval(second), TimeInterval(second) + 0.9)
        }
        let segments = ParakeetSegmentMapper.segments(
            fromBatchText: "x",
            tokenTimings: timings,
            audioDuration: 40,
            confidence: 0.9,
            meetingID: meeting,
            channel: .system,
            language: nil
        )
        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.endTime - segment.startTime, 31)
        }
    }

    private func timing(_ token: String, _ start: TimeInterval, _ end: TimeInterval) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: 0.9)
    }
}

final class VocabularyPromptTests: XCTestCase {
    func testFormatsTermsAsGlossarySentence() {
        XCTAssertEqual(
            VocabularyPrompt.text(["LVGT", "Portavoz", "Vishakha"]),
            "Glossary: LVGT, Portavoz, Vishakha.")
    }

    func testEmptyAndBlankTermsYieldNoPrompt() {
        XCTAssertNil(VocabularyPrompt.text([]))
        XCTAssertNil(VocabularyPrompt.text(["  ", ""]))
    }

    func testParseSplitsAndTrimsCommaList() {
        XCTAssertEqual(
            VocabularyPrompt.parse(" LVGT , Portavoz,,  Vishakha "),
            ["LVGT", "Portavoz", "Vishakha"])
        XCTAssertEqual(VocabularyPrompt.parse(""), [])
    }
}
