import AVFoundation
import CryptoKit
import Foundation

/// Selected public cells only. The corpus CLI separately admits the entire matrix.
struct DictationModelFixture {
    static let sourceDigest = "92de308a11ea180e10f0120b41cf2c24e713b1f4e15dc26b50b55312ef3022e3"
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Source: Decodable {
        struct Family: Decodable {
            let id: String
            let group: String
            let cohort: String
            let shape: String
            let split: String
            let acceptedTexts: [String]
            let critical: Bool
        }
        struct Profile: Decodable { let id: String }
        let families: [Family]
        let profiles: [Profile]
    }

    struct Manifest: Decodable {
        struct Entry: Decodable {
            let caseID: String
            let audioSHA256: String
            let frames: Int
            let sampleRate: Int
            let channels: Int
            let sampleWidth: Int
        }
        let kind: String
        let schemaVersion: Int
        let corpusSHA256: String
        let recipeSHA256: String
        let entries: [Entry]
    }

    let audioRoot: URL
    let manifest: Manifest
    let manifestDigest: String
    let source: Source
    let selectedIDs: [String]

    init(audioRoot: URL, selectedIDs: [String]) throws {
        let sourceData = try Self.boundedRegularData(
            Self.root.appendingPathComponent("Fixtures/DictationValidation/public-synthetic-v1.json"),
            limit: 2_000_000)
        guard Self.digest(sourceData) == Self.sourceDigest else { throw DictationModelProbe.Failure.invalidInput }
        let source = try JSONDecoder().decode(Source.self, from: sourceData)
        let manifestData = try Self.boundedRegularData(audioRoot.appendingPathComponent("manifest.json"), limit: 2_000_000)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let canonical = Set(source.families.flatMap { family in source.profiles.map { family.id + "." + $0.id } })
        guard !selectedIDs.isEmpty, selectedIDs.count <= canonical.count,
              Set(selectedIDs).count == selectedIDs.count, Set(selectedIDs).isSubset(of: canonical),
              manifest.kind == "dictation-audio-manifest", manifest.schemaVersion == 1,
              manifest.corpusSHA256 == Self.sourceDigest, manifest.recipeSHA256.count == 64,
              manifest.entries.count == canonical.count,
              Set(manifest.entries.map(\.caseID)) == canonical
        else { throw DictationModelProbe.Failure.invalidInput }
        self.audioRoot = audioRoot
        self.manifest = manifest
        self.manifestDigest = Self.digest(manifestData)
        self.source = source
        self.selectedIDs = selectedIDs
    }

    struct Sequence {
        let family: Source.Family
        let entry: Manifest.Entry
        let samples: [Float]
        let references: [String]
    }

    /// Repeat source PCM and ground truth together; never relabel a short run as long.
    func sequence(_ id: String, repetitions: Int) throws -> Sequence {
        guard (1...12).contains(repetitions) else { throw DictationModelProbe.Failure.invalidInput }
        let (family, entry, source) = try cell(id)
        guard source.count <= 1_920_000 / repetitions else { throw DictationModelProbe.Failure.invalidInput }
        if repetitions == 1 {
            return Sequence(family: family, entry: entry, samples: source, references: family.acceptedTexts)
        }
        var samples: [Float] = []
        samples.reserveCapacity(source.count * repetitions)
        for _ in 0..<repetitions { samples.append(contentsOf: source) }
        let references = family.acceptedTexts.map {
            Array(repeating: $0, count: repetitions).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        return Sequence(family: family, entry: entry, samples: samples, references: references)
    }

    func cell(_ id: String) throws -> (Source.Family, Manifest.Entry, [Float]) {
        guard selectedIDs.contains(id),
              let family = source.families.first(where: { id.hasPrefix($0.id + ".") }),
              let entry = manifest.entries.first(where: { $0.caseID == id }),
              entry.frames > 0, entry.frames <= 1_920_000,
              entry.sampleRate == 16_000, entry.channels == 1, entry.sampleWidth == 2
        else { throw DictationModelProbe.Failure.invalidInput }
        let url = audioRoot.appendingPathComponent(id + ".wav")
        guard Self.digest(try Self.boundedRegularData(url, limit: 4_000_128)) == entry.audioSHA256 else {
            throw DictationModelProbe.Failure.invalidInput
        }
        let file = try AVAudioFile(forReading: url)
        guard file.fileFormat.commonFormat == .pcmFormatInt16,
              file.length == entry.frames, file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(entry.frames))
        else { throw DictationModelProbe.Failure.invalidInput }
        try file.read(into: buffer)
        guard buffer.frameLength == entry.frames, let samples = buffer.floatChannelData?[0],
              Self.digest(try Self.boundedRegularData(url, limit: 4_000_128)) == entry.audioSHA256
        else { throw DictationModelProbe.Failure.invalidInput }
        return (family, entry, Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func boundedRegularData(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= limit else {
            throw DictationModelProbe.Failure.invalidInput
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == size else { throw DictationModelProbe.Failure.invalidInput }
        return data
    }
}
