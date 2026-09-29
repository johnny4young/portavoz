import Foundation
import XCTest

final class DictationModelFixtureTests: XCTestCase {
    func testSelectedPCMIsVerifiedAtTheNativeConsumerAndCannotBeReplacedByFloatAudio() throws {
        let root = try makeFixture(floatPCM: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try DictationModelFixture(audioRoot: root, selectedIDs: ["en-payment-negation.clean"])
        XCTAssertThrowsError(try fixture.cell("en-payment-negation.clean"))
    }

    func testNativeFixtureRejectsMutationAndNoncanonicalSelection() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "en-payment-negation.clean"
        let fixture = try DictationModelFixture(audioRoot: root, selectedIDs: [id])
        let (_, entry, samples) = try fixture.cell(id)
        XCTAssertEqual(entry.frames, 2)
        XCTAssertEqual(samples, [0, 0])
        for selected in [[String](), [id, id], ["../../private"], [id + ".unknown"]] {
            XCTAssertThrowsError(try DictationModelFixture(audioRoot: root, selectedIDs: selected))
        }
        let audio = root.appendingPathComponent(id + ".wav")
        try Data("not audio".utf8).write(to: audio)
        XCTAssertThrowsError(try fixture.cell(id))
    }

    func testNativeFixtureRejectsSymlinkEvenWhenTargetBytesMatch() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "en-payment-negation.clean"
        let audio = root.appendingPathComponent(id + ".wav")
        let target = root.appendingPathComponent("original.wav")
        try FileManager.default.moveItem(at: audio, to: target)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: target)
        let fixture = try DictationModelFixture(audioRoot: root, selectedIDs: [id])
        XCTAssertThrowsError(try fixture.cell(id))
    }

    func testNativeRepeatedSequencePreservesPCMOrderAndRepeatsGroundTruthTogether() throws {
        let root = try makeFixture(samples: [8192, -16384, 0])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "en-payment-negation.clean"
        let fixture = try DictationModelFixture(audioRoot: root, selectedIDs: [id])
        let original = try fixture.sequence(id, repetitions: 1)
        let repeated = try fixture.sequence(id, repetitions: 3)
        XCTAssertEqual(repeated.samples, [0.25, -0.5, 0, 0.25, -0.5, 0, 0.25, -0.5, 0])
        XCTAssertEqual(repeated.entry.audioSHA256, original.entry.audioSHA256)
        XCTAssertEqual(repeated.references, original.references.map { [$0, $0, $0].joined(separator: " ") })
        for invalid in [Int.min, -1, 0, 13, Int.max] {
            XCTAssertThrowsError(try fixture.sequence(id, repetitions: invalid))
        }
    }

    func testRepeatedNonSpeechKeepsAnEmptyReferenceRatherThanInventingWords() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "non-speech-silence.clean"
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("en-payment-negation.clean.wav"),
            to: root.appendingPathComponent(id + ".wav"))
        let fixture = try DictationModelFixture(audioRoot: root, selectedIDs: [id])
        let sequence = try fixture.sequence(id, repetitions: 12)
        XCTAssertEqual(sequence.samples.count, 24)
        XCTAssertEqual(sequence.references, [""])
    }

    func testNativeRepeatedSequenceEnforcesBoundOnResultNotOnlySourceCell() throws {
        for frames in [160_000, 160_001] {
            let root = try makeFixture(samples: [Int16](repeating: 0, count: frames))
            defer { try? FileManager.default.removeItem(at: root) }
            let id = "en-payment-negation.clean"
            let fixture = try DictationModelFixture(audioRoot: root, selectedIDs: [id])
            if frames == 160_000 {
                XCTAssertEqual(try fixture.sequence(id, repetitions: 12).samples.count, 1_920_000)
            } else {
                XCTAssertThrowsError(try fixture.sequence(id, repetitions: 12))
            }
        }
    }

    private func makeFixture(floatPCM: Bool = false, samples: [Int16] = [0, 0]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            let sampleWidth = floatPCM ? 4 : 2
            let pcmBytes = sampleWidth * samples.count
            var data = Data("RIFF".utf8)
            append(36 + pcmBytes, bytes: 4, to: &data)
            data.append(Data("WAVEfmt ".utf8))
            append(16, bytes: 4, to: &data)
            append(floatPCM ? 3 : 1, bytes: 2, to: &data)
            append(1, bytes: 2, to: &data)
            append(16_000, bytes: 4, to: &data)
            append(16_000 * sampleWidth, bytes: 4, to: &data)
            append(sampleWidth, bytes: 2, to: &data)
            append(floatPCM ? 32 : 16, bytes: 2, to: &data)
            data.append(Data("data".utf8))
            append(pcmBytes, bytes: 4, to: &data)
            if floatPCM {
                data.append(Data(repeating: 0, count: pcmBytes))
            } else {
                for sample in samples { append(Int(UInt16(bitPattern: sample)), bytes: 2, to: &data) }
            }
            try data.write(to: root.appendingPathComponent("en-payment-negation.clean.wav"))
            let sourceURL = DictationModelFixture.root
                .appendingPathComponent("Fixtures/DictationValidation/public-synthetic-v1.json")
            let source = try JSONDecoder().decode(DictationModelFixture.Source.self, from: Data(contentsOf: sourceURL))
            let entries: [[String: Any]] = source.families.flatMap { family in
                source.profiles.map { profile in
                    ["caseID": family.id + "." + profile.id, "audioSHA256": DictationModelFixture.digest(data),
                     "frames": samples.count, "sampleRate": 16_000, "channels": 1, "sampleWidth": 2]
                }
            }
            let manifest: [String: Any] = [
                "kind": "dictation-audio-manifest", "schemaVersion": 1,
                "corpusSHA256": DictationModelFixture.sourceDigest, "recipeSHA256": String(repeating: "a", count: 64),
                "entries": entries]
            try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func append(_ value: Int, bytes: Int, to data: inout Data) {
        for offset in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
    }
}
