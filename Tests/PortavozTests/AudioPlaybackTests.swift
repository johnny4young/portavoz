import AVFoundation
import Foundation
import XCTest

@testable import AudioCaptureKit
@testable import AudioPlaybackKit

final class WaveformTests: XCTestCase {
    /// Writes a WAV whose first half is loud and second half silent, then
    /// checks the envelope reflects that shape and normalizes to 0…1.
    func testEnvelopeReflectsLoudThenSilent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let rate = 16_000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(rate)  // 1 second
        // Optional so we can nil it out — AVAudioFile flushes to disk on
        // dealloc, and generate() reads the file back in the same test.
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = i < Int(frames) / 2 ? 0.8 : 0.0
        }
        try writer!.write(from: buffer)
        writer = nil

        let buckets = Waveform.generate(micFile: url, systemFile: nil, buckets: 10)
        XCTAssertEqual(buckets.count, 10)
        XCTAssertEqual(buckets.first?.amplitude ?? 0, 1.0, accuracy: 0.01, "loud start normalizes to 1")
        XCTAssertEqual(buckets.last?.amplitude ?? 1, 0.0, accuracy: 0.01, "silent tail reads ~0")
        XCTAssertTrue(buckets.allSatisfy(\.micDominant), "only the mic channel had signal")
    }

    func testEmptyWhenNothingReadable() {
        XCTAssertTrue(Waveform.generate(micFile: nil, systemFile: nil, buckets: 100).isEmpty)
        XCTAssertTrue(
            Waveform.generate(
                micFile: URL(fileURLWithPath: "/nope.wav"), systemFile: nil, buckets: 100
            ).isEmpty)
    }

    func testEnvelopePreservesBucketBoundariesAcrossChannelsAndRemainder() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-boundaries-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false)!
        let first: [Float] = [0.1, 0.8, 0.2, 0.4, 0.3, 0.2, 0.1, 0.6, 0.2, 0.9, 0.5]
        let second: [Float] = [0.2, 0.1, 0.7, 0.2, 0.5, 0.1, 0.3, 0.2, 0.4, 0.1, 1.0]
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(first.count))!
        buffer.frameLength = AVAudioFrameCount(first.count)
        first.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: first.count)
        }
        second.withUnsafeBufferPointer {
            buffer.floatChannelData![1].update(from: $0.baseAddress!, count: second.count)
        }
        try writer!.write(from: buffer)
        writer = nil

        let buckets = Waveform.generate(micFile: url, systemFile: nil, buckets: 3)

        XCTAssertEqual(buckets.map(\.amplitude), [0.8, 0.5, 1.0])
        XCTAssertTrue(buckets.allSatisfy(\.micDominant))
    }

    func testGenerationChecksCancellationBetweenBoundedReads() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-cancel-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false)!
        let frames = AVAudioFrameCount(160_000)
        var writer: AVAudioFile? = try AVAudioFile(
            forWriting: url,
            settings: format.settings)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: Int(frames))
        try writer!.write(from: buffer)
        writer = nil

        var checks = 0
        XCTAssertThrowsError(try Waveform.generate(
            micFile: url,
            systemFile: nil,
            buckets: 100
        ) {
            checks += 1
            if checks == 4 { throw CancellationError() }
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(
            checks,
            4,
            "obsolete generation must stop at the next fixed-size file chunk")
    }

    func testCancellableGenerationRejectsAnAlreadyCancelledCaller() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Waveform.generateCancellable(
                micFile: nil,
                systemFile: nil,
                buckets: 100)
        }

        do {
            _ = try await task.value
            XCTFail("an obsolete Meeting Detail task must not start waveform IO")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    /// A loud–silent–loud shape yields one silent range in the middle, and
    /// short dips below `minLength` are ignored.
    func testSilentRangesFindsSustainedGaps() {
        func bucket(_ a: Float) -> Waveform.Bucket { .init(amplitude: a, micDominant: true) }
        // 10 buckets over 10 s (1 s each): loud 0–3, silent 3–7, loud 7–10.
        let buckets = [0.8, 0.8, 0.8, 0.0, 0.0, 0.0, 0.0, 0.8, 0.8, 0.8].map(bucket)
        let ranges = Waveform.silentRanges(buckets, duration: 10, threshold: 0.06, minLength: 1.2)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first?.lowerBound ?? -1, 3, accuracy: 0.01)
        XCTAssertEqual(ranges.first?.upperBound ?? -1, 7, accuracy: 0.01)

        // A single silent bucket (1 s < minLength) is ignored.
        let brief = [0.8, 0.0, 0.8].map(bucket)
        XCTAssertTrue(Waveform.silentRanges(brief, duration: 3, minLength: 1.2).isEmpty)
    }
}

final class AudioClipExporterTests: XCTestCase {
    private func writeWAV(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-src-\(UUID().uuidString).wav")
        let rate = 16_000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = 0.4 * Float(sin(2 * Double.pi * 330 * Double(i) / rate))
        }
        try writer!.write(from: buffer)
        writer = nil
        return url
    }

    /// A clip of a range writes a valid m4a of ~the right duration, fast.
    func testExportsRangeToM4A() async throws {
        let source = try writeWAV(seconds: 30)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-out-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: output) }

        try await AudioClipExporter.export(channelFiles: [source], range: 5...20, to: output)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let clip = AVURLAsset(url: output)
        let duration = try await clip.load(.duration).seconds
        XCTAssertEqual(duration, 15, accuracy: 0.5, "the clip must be ~15 s long")
    }

    func testRejectsInvalidRangeAndMissingAudio() async {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("x.m4a")
        do {
            try await AudioClipExporter.export(
                channelFiles: [URL(fileURLWithPath: "/nope.wav")], range: 0...1, to: out)
            XCTFail("missing audio must throw")
        } catch {}
    }
}

final class AudioTranscoderTests: XCTestCase {
    /// The exact mono Int16 CAF written by production capture transcodes to a
    /// much smaller m4a; with deleteSource the original is gone and the m4a
    /// remains.
    func testTranscodesToSmallerM4AAndRemovesSource() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-\(UUID().uuidString).caf")
        try writeCaptureCAF(to: url, seconds: 10)

        let wavBytes = AudioTranscoder.totalBytes(of: [url])
        let m4a: URL
        do {
            m4a = try await AudioTranscoder.toAAC(source: url, deleteSource: true)
        } catch where isAACEncoderUnavailable(error) {
            throw XCTSkip("The host AAC encoder is unavailable: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: m4a) }

        XCTAssertEqual(m4a.pathExtension, "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "source removed after write")
        XCTAssertLessThan(
            AudioTranscoder.totalBytes(of: [m4a]), wavBytes, "AAC must be smaller than the WAV")
    }

    func testTranscodesEveryChannelBeforeRemovingAnyOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-set-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = directory.appendingPathComponent("system.wav")
        let microphone = directory.appendingPathComponent("microphone.wav")
        try writeWAV(to: system, seconds: 2)
        try writeWAV(to: microphone, seconds: 2)

        let outputs = try await AudioTranscoder.toAAC(
            sources: [system, microphone],
            encoder: { source, output in
                try FileManager.default.copyItem(at: source, to: output)
            })

        XCTAssertEqual(outputs.map(\.lastPathComponent), ["system.m4a", "microphone.m4a"])
        XCTAssertTrue(outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: system.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphone.path))
    }

    func testLaterChannelFailureRollsBackPublishedWorkAndPreservesOriginals() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = directory.appendingPathComponent("system.wav")
        let missingMicrophone = directory.appendingPathComponent("microphone.wav")
        try writeWAV(to: system, seconds: 1)

        do {
            _ = try await AudioTranscoder.toAAC(
                sources: [system, missingMicrophone],
                encoder: { source, output in
                    guard FileManager.default.fileExists(atPath: source.path) else {
                        throw AudioTranscoder.TranscodeError.exportFailed(
                            "source audio is missing")
                    }
                    try FileManager.default.copyItem(at: source, to: output)
                })
            XCTFail("a missing later channel must fail the complete transaction")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: system.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("system.m4a").path))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
        XCTAssertFalse(leftovers.contains {
            $0.lastPathComponent.hasPrefix(".portavoz-compress-")
        })
    }

    func testTotalBytesReflectsDeletionWhenTheSameURLIsReused() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-size-\(UUID().uuidString).raw")
        try Data(repeating: 0x2A, count: 4_096).write(to: url)

        XCTAssertEqual(AudioTranscoder.totalBytes(of: [url]), 4_096)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(AudioTranscoder.totalBytes(of: [url]), 0)
    }

    func testExistingCanonicalOutputFailsWithoutReplacingEitherFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-existing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("system.wav")
        let existing = directory.appendingPathComponent("system.m4a")
        try writeWAV(to: source, seconds: 1)
        let originalSource = try Data(contentsOf: source)
        let originalOutput = Data("preserve-me".utf8)
        try originalOutput.write(to: existing)

        do {
            _ = try await AudioTranscoder.toAAC(source: source)
            XCTFail("an existing canonical output must fail closed")
        } catch AudioTranscoder.TranscodeError.outputAlreadyExists {
            // Expected: neither user-owned artifact may be replaced.
        }

        XCTAssertEqual(try Data(contentsOf: source), originalSource)
        XCTAssertEqual(try Data(contentsOf: existing), originalOutput)
    }

    private func writeWAV(to url: URL, seconds: Double) throws {
        let rate = 16_000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 1,
            interleaved: false)!
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            channel[index] = 0.3 * Float(sin(2 * Double.pi * 300 * Double(index) / rate))
        }
        try writer!.write(from: buffer)
        writer = nil
    }

    private func writeCaptureCAF(to url: URL, seconds: Double) throws {
        let rate = 48_000.0
        try autoreleasepool {
            let writer = try CaptureFileWriter(url: url, sampleRate: rate)
            let sampleCount = Int(rate * seconds)
            let samples = (0..<sampleCount).map { index in
                0.3 * Float(sin(2 * Double.pi * 300 * Double(index) / rate))
            }
            try writer.append(samples)
        }
    }

    private func isAACEncoderUnavailable(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let candidate = current {
            if candidate.code == 1_718_449_215 { return true } // 'fmt?'
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

final class MeetingPlayerTests: XCTestCase {
    func testCleanPlaybackPolicyClampsSortsAndMergesRanges() {
        XCTAssertEqual(
            CleanPlaybackPolicy.audibleRanges(
                [9...14, -2...2, 1.5...4, 20...25],
                duration: 12),
            [0...4, 9...12])
        XCTAssertEqual(CleanPlaybackPolicy.backgroundMicrophoneGain, 0)
    }

    func testCleanPlaybackPolicyRejectsNoDurationOrEmptyRanges() {
        XCTAssertTrue(
            CleanPlaybackPolicy.audibleRanges([1...2], duration: 0).isEmpty)
        XCTAssertTrue(
            CleanPlaybackPolicy.audibleRanges([], duration: 20).isEmpty)
    }

    /// Turns closer than one duck-and-recover cycle cannot be separated
    /// without overlapping ramps, so policy merges them into one range.
    func testCleanPlaybackPolicyMergesTurnsTooCloseToDuckBetween() {
        let cycle = CleanPlaybackPolicy.attack + CleanPlaybackPolicy.release
        XCTAssertFalse(
            CleanPlaybackPolicy.canDuckBetween(
                earlierEnd: 262.68, laterStart: 262.76),
            "the observed 0.08 s gap is under the \(cycle) s cycle")
        XCTAssertEqual(
            CleanPlaybackPolicy.audibleRanges(
                [262.56...262.68, 262.76...263.4],
                duration: 600),
            [262.56...263.4])
        XCTAssertEqual(
            CleanPlaybackPolicy.audibleRanges(
                [10...11, 11.5...12], duration: 600).count,
            2,
            "well-separated turns still duck between")
    }

    /// The merge boundary is decided with the same arithmetic the schedule
    /// emits, so a pair that survives as two ranges is always orderable — no
    /// rounding at the boundary can produce an overlapping schedule.
    func testCleanPlaybackSeparationBoundaryNeverProducesOverlap() {
        let attack = CleanPlaybackPolicy.attack
        let release = CleanPlaybackPolicy.release
        for step in -20...20 {
            let gap = attack + release + Double(step) * 0.000_000_001
            let ranges: [ClosedRange<TimeInterval>] = [10...11, (11 + gap)...12]
            let merged = CleanPlaybackPolicy.audibleRanges(
                ranges, duration: 600)
            let schedule = CleanPlaybackPolicy.volumeSchedule(
                audibleRanges: ranges, duration: 600)
            XCTAssertTrue(
                CleanPlaybackPolicy.isStrictlyOrdered(schedule),
                "gap \(gap) produced an overlapping schedule")
            if merged.count == 2 {
                XCTAssertTrue(CleanPlaybackPolicy.canDuckBetween(
                    earlierEnd: merged[0].upperBound,
                    laterStart: merged[1].lowerBound))
            }
        }
    }

    /// The regression that aborted the app when opening a refined meeting:
    /// two local turns 0.08 s apart produced a release ramp of [262.68,
    /// 262.80] and then an attack ramp of [262.70, 262.76] nested inside it,
    /// which makes AVFoundation raise an uncatchable Objective-C exception.
    func testCleanPlaybackScheduleStaysOrderedForNearAdjacentTurns() {
        let schedule = CleanPlaybackPolicy.volumeSchedule(
            audibleRanges: [
                262.56...262.68, 262.76...263.4,
                276.0...276.04, 276.12...277.0,
                320.4...320.6, 320.76...321.5,
            ],
            duration: 1_440.96)
        XCTAssertFalse(schedule.isEmpty)
        XCTAssertTrue(
            CleanPlaybackPolicy.isStrictlyOrdered(schedule),
            "near-adjacent turns must not produce overlapping ramps")
    }

    /// The ordering invariant has to hold for every shape the transcript can
    /// produce, not only the observed one: turns at the timeline edges, exact
    /// duplicates, inverted and out-of-order input, and dense speech.
    func testCleanPlaybackScheduleIsOrderedForAdversarialRanges() {
        let duration: TimeInterval = 120
        var dense: [ClosedRange<TimeInterval>] = []
        for index in 0..<400 {
            let start = Double(index) * 0.19
            dense.append(start...(start + 0.05))
        }
        let cases: [[ClosedRange<TimeInterval>]] = [
            [0...0.01],
            [0...duration],
            [(duration - 0.01)...duration],
            [5...6, 5...6, 5...6],
            [30...31, 10...11, 20...21],
            [-50 ... -1, 200...300, 10...11],
            [0...0.03, 0.04...0.07, 0.08...0.11],
            dense,
        ]
        for ranges in cases {
            let schedule = CleanPlaybackPolicy.volumeSchedule(
                audibleRanges: ranges,
                duration: duration)
            XCTAssertTrue(
                CleanPlaybackPolicy.isStrictlyOrdered(schedule),
                "unordered schedule for \(ranges.prefix(3))")
            XCTAssertTrue(
                schedule.allSatisfy { $0.start >= 0 && $0.end <= duration },
                "schedule left the timeline for \(ranges.prefix(3))")
        }
    }

    /// The schedule is validated in seconds but delivered as CMTime at 1/600 s.
    /// An event pair ordered by microseconds is *one* instant to AVFoundation,
    /// and an empty ramp there raises the same uncatchable exception as an
    /// empty one in seconds (D287) — so ordering is judged after quantization.
    func testCleanPlaybackOrderingIsJudgedOnTheTicksAVFoundationReceives() {
        // 1/600 s ≈ 1.667 ms. These two are ordered in seconds and identical
        // once quantized.
        XCTAssertFalse(CleanPlaybackPolicy.isStrictlyOrdered([
            .ramp(from: 0, to: 1, start: 10, end: 10.000_1),
        ]))
        XCTAssertTrue(CleanPlaybackPolicy.isStrictlyOrdered([
            .ramp(from: 0, to: 1, start: 10, end: 10.002),
        ]))

        // A turn shorter than one tick raises and lowers the microphone at the
        // same instant, so its instructions do nothing; it is dropped rather
        // than emitted. (Keeping it would still pass the ordering check —
        // that is tidiness, not the crash guard.)
        let subTick = CleanPlaybackPolicy.volumeSchedule(
            audibleRanges: [10 ... 10.000_5],
            duration: 60)
        XCTAssertTrue(subTick.isEmpty)
        XCTAssertEqual(
            CleanPlaybackPolicy.audibleRanges([10 ... 10.000_5], duration: 60)
                .count,
            0)

        // The crash guard is the representable check. A bound this large has no
        // tick, and letting it reach the schedule would make `isStrictlyOrdered`
        // refuse everything — silencing clear playback for the whole meeting
        // rather than for one impossible turn.
        XCTAssertNil(CleanPlaybackPolicy.tick(2e16))
        XCTAssertNil(CleanPlaybackPolicy.tick(.infinity))
        let unrepresentable = CleanPlaybackPolicy.volumeSchedule(
            audibleRanges: [2e16 ... 2.1e16, 10...11],
            duration: 3e16)
        XCTAssertTrue(CleanPlaybackPolicy.isStrictlyOrdered(unrepresentable))
        XCTAssertFalse(
            unrepresentable.isEmpty,
            "the representable turn survives its impossible neighbour")

        // A real turn alongside a sub-tick one keeps clear playback working.
        let mixed = CleanPlaybackPolicy.volumeSchedule(
            audibleRanges: [5 ... 5.000_5, 10...11],
            duration: 60)
        XCTAssertTrue(CleanPlaybackPolicy.isStrictlyOrdered(mixed))
        XCTAssertEqual(
            mixed,
            CleanPlaybackPolicy.volumeSchedule(
                audibleRanges: [10...11],
                duration: 60))
    }

    func testCleanPlaybackOrderingRejectsOverlappingAndEmptyRamps() {
        XCTAssertFalse(CleanPlaybackPolicy.isStrictlyOrdered([
            .ramp(from: 1, to: 0, start: 262.68, end: 262.8),
            .ramp(from: 0, to: 1, start: 262.7, end: 262.76),
        ]))
        XCTAssertFalse(CleanPlaybackPolicy.isStrictlyOrdered([
            .level(volume: 0, at: 5),
            .level(volume: 1, at: 4),
        ]))
        XCTAssertFalse(CleanPlaybackPolicy.isStrictlyOrdered([
            .ramp(from: 0, to: 1, start: 5, end: 5),
        ]))
        XCTAssertFalse(CleanPlaybackPolicy.isStrictlyOrdered([
            .level(volume: 0, at: .nan),
        ]))
        XCTAssertTrue(CleanPlaybackPolicy.isStrictlyOrdered([]))
    }

    func testCleanPlaybackScheduleDucksBetweenWellSeparatedTurns() {
        let background = CleanPlaybackPolicy.backgroundMicrophoneGain
        let attack = CleanPlaybackPolicy.attack
        let release = CleanPlaybackPolicy.release
        XCTAssertEqual(
            CleanPlaybackPolicy.volumeSchedule(
                audibleRanges: [10...11],
                duration: 60),
            [
                .level(volume: background, at: 0),
                .ramp(from: background, to: 1, start: 10 - attack, end: 10),
                .level(volume: 1, at: 11),
                .ramp(from: 1, to: background, start: 11, end: 11 + release),
            ])
        XCTAssertTrue(
            CleanPlaybackPolicy.volumeSchedule(
                audibleRanges: [], duration: 60).isEmpty)
    }

    /// The release ramp is clipped at the end of the audio rather than
    /// running past it, and a turn starting inside the attack window ramps
    /// from the timeline origin.
    func testCleanPlaybackScheduleClampsRampsToTheTimeline() {
        let background = CleanPlaybackPolicy.backgroundMicrophoneGain
        let attack = CleanPlaybackPolicy.attack
        XCTAssertEqual(
            CleanPlaybackPolicy.volumeSchedule(
                audibleRanges: [(attack / 2)...20],
                duration: 20),
            [
                .level(volume: background, at: 0),
                .ramp(from: background, to: 1, start: 0, end: attack / 2),
                .level(volume: 1, at: 20),
            ],
            "no release ramp fits past the end of the audio")
    }

    @MainActor
    func testMakeReturnsNilWhenNoChannelFileExists() async {
        let player = await MeetingPlayer.make(
            channelFiles: [URL(fileURLWithPath: "/nonexistent/system.caf")])
        XCTAssertNil(player, "a player over missing audio must not be built")
    }

    @MainActor
    func testMakeReturnsNilForEmptyList() async {
        let player = await MeetingPlayer.make(channelFiles: [])
        XCTAssertNil(player)
    }
}
