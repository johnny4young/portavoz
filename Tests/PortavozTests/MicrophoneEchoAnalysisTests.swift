import AVFoundation
import PortavozCore
import XCTest

@testable import AudioCaptureKit

final class MicrophoneEchoAnalysisTests: XCTestCase {
    private static let sampleRate = 48_000
    private static let seconds = 40
    /// Remote speech plays in 3 s spurts; the user speaks alone at 12-14 s
    /// (a remote pause) and over the remote side at 21-23 s.
    private static let remotePauses: [Range<Double>] = [11.5..<15, 27..<29]
    private static let userTurns: [Range<Double>] = [12..<14, 21..<23]

    func testSpeakerEchoIsSeparatedFromTheUsersOwnVoice() throws {
        let remote = Self.speech(seed: 1, active: { t in
            !Self.remotePauses.contains { $0.contains(t) } && t < 36
        })
        let user = Self.speech(seed: 2, active: { t in Self.userTurns.contains { $0.contains(t) } })
        let delay = Self.sampleRate * 80 / 1_000
        let reflection = Self.sampleRate * 20 / 1_000
        let microphone = remote.indices.map { index -> Float in
            let direct = index >= delay ? remote[index - delay] : 0
            let late = index >= delay + reflection ? remote[index - delay - reflection] : 0
            // Small speakers compress loud passages: the echo is not linear.
            return 0.2 * tanh(3 * direct) + 0.05 * late + 1.5 * user[index]
        }
        let urls = try write(microphone: microphone, system: remote)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let profile = try XCTUnwrap(
            MicrophoneEchoAnalysis.profile(microphone: urls[0], system: urls[1]))

        XCTAssertGreaterThanOrEqual(try XCTUnwrap(profile.echoAttenuationDB(from: 4, to: 10)), 10)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(profile.echoAttenuationDB(from: 30, to: 35)), 10)
        XCTAssertLessThan(try XCTUnwrap(profile.echoAttenuationDB(from: 12.2, to: 13.8)), 3)
        XCTAssertLessThan(try XCTUnwrap(profile.echoAttenuationDB(from: 21.2, to: 22.8)), 6)
    }

    func testHeadphonesProduceNoProfile() throws {
        let remote = Self.speech(seed: 1, active: { $0 < 36 })
        let user = Self.speech(seed: 2, active: { t in Self.userTurns.contains { $0.contains(t) } })
        let urls = try write(microphone: user, system: remote)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertNil(try MicrophoneEchoAnalysis.profile(microphone: urls[0], system: urls[1]))
    }

    func testSilentRemoteSideProducesNoProfile() throws {
        let user = Self.speech(seed: 2, active: { _ in true })
        let urls = try write(
            microphone: user,
            system: Array(repeating: 0, count: user.count))
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertNil(try MicrophoneEchoAnalysis.profile(microphone: urls[0], system: urls[1]))
    }

    /// Noise shaped into 200 ms syllables, with a quiet noise floor between.
    private static func speech(seed: UInt64, active: (Double) -> Bool) -> [Float] {
        var generator = SplitMix(state: seed)
        var lowPassed: Float = 0
        return (0..<(sampleRate * seconds)).map { index in
            let time = Double(index) / Double(sampleRate)
            let noise = Float(generator.unit())
            lowPassed = 0.7 * lowPassed + 0.3 * noise
            guard active(time) else { return 0.0005 * noise }
            let syllable = Float(max(0, sin(Double.pi * time / 0.2)))
            return 0.3 * syllable * lowPassed
        }
    }

    private func write(microphone: [Float], system: [Float]) throws -> [URL] {
        try [microphone, system].map { samples in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("echo-\(UUID().uuidString).caf")
            let format = try XCTUnwrap(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(Self.sampleRate),
                channels: 1,
                interleaved: false))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData?[0].update(from: $0.baseAddress!, count: samples.count)
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        }
    }
}

private struct SplitMix {
    var state: UInt64

    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / Double(1 << 53) * 2 - 1
    }
}
