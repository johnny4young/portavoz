import Foundation
import ModelStoreKit
import TranscriptionKit

/// Shared bits for the hand-rolled argument parsing: no dependency on
/// swift-argument-parser while the CLI is still a dev harness.
enum CLISupport {
    static func modelStore(fromModelsDir path: String?) -> ModelStore {
        if let path {
            return ModelStore(rootDirectory: URL(fileURLWithPath: path, isDirectory: true))
        }
        return ModelStore()
    }

    /// Downloads/verifies the recommended model (printing progress) and
    /// loads the engine.
    static func loadEngine(store: ModelStore) async throws -> ParakeetEngine {
        guard let descriptor = ModelCatalog.recommended(for: .liveTranscription) else {
            throw ModelStore.ModelStoreError.notInstalled(
                missing: ["no recommended live-transcription model"],
                corrupted: [])
        }
        let directory = try await ensureModel(descriptor, store: store)
        return try await ParakeetEngine.load(fromVerifiedDirectory: directory)
    }

    static func loadNemotronResearchEngine(
        store: ModelStore
    ) async throws -> NemotronLatin1120Engine {
        let descriptor = ModelCatalog.nemotronLatin1120
        let directory = try await ensureModel(descriptor, store: store)
        return try await NemotronLatin1120Engine.load(
            fromVerifiedDirectory: directory)
    }

    private static func ensureModel(
        _ descriptor: ModelDescriptor,
        store: ModelStore
    ) async throws -> URL {
        let report = await store.verify(descriptor)
        if !report.isComplete {
            let megabytes = descriptor.totalSizeBytes / 1_000_000
            print("Downloading \(descriptor.displayName) (\(megabytes) MB, sha256-verified)…")
        }
        let directory = try await store.ensureAvailable(descriptor) { progress in
            guard progress.totalBytes > 0 else { return }
            let percent = Int(progress.fraction * 100)
            print("\r  \(percent)% \(progress.currentPath)", terminator: percent == 100 ? "\n" : "")
            fflush(stdout)
        }
        print("Loading models (first load compiles for the ANE; can take ~a minute)…")
        return directory
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[rank]
    }
}

/// Shared resource bounds for the original hand-written CLI commands. Newer
/// evidence commands already own equivalent typed option structs; these values
/// keep legacy commands from turning malformed terminal input into traps or
/// unbounded work.
enum CLIOptionBounds {
    static let durationSeconds = 1...86_400
    static let askLimit = 1...50
    static let benchmarkMeetings = 1...100_000
    static let segmentsPerMeeting = 1...10_000
    static let maximumFTSSegments = 1_000_000
    static let processID = 1...Int(Int32.max)
    static let diarizationCollar: ClosedRange<Double> = 0...60

    static func acceptsDiarizationThreshold(_ value: Float) -> Bool {
        value > 0 && value < 1
    }

    static func ftsSegmentCount(meetings: Int, segmentsPerMeeting: Int) -> Int? {
        let product = meetings.multipliedReportingOverflow(by: segmentsPerMeeting)
        guard !product.overflow, product.partialValue <= maximumFTSSegments else {
            return nil
        }
        return product.partialValue
    }
}

enum CLIArgumentError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case missingValue(option: String)
    case invalidValue(option: String, value: String, expected: String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            "missing value after \(option)"
        case .invalidValue(let option, let value, let expected):
            "\(option) expects \(expected); got \(value)"
        }
    }

    var description: String { errorDescription ?? "invalid CLI argument" }
}

/// Strict numeric option reader for the legacy development commands. It moves
/// `index` to the consumed value and refuses a missing value, another option,
/// malformed text, non-finite floating point, or a value outside its bound.
enum CLIOptionValue {
    static func string(
        _ arguments: [String],
        index: inout Int,
        option: String
    ) throws -> String {
        let raw = try rawValue(arguments, index: &index, option: option)
        guard !raw.isEmpty else {
            throw CLIArgumentError.invalidValue(
                option: option,
                value: raw,
                expected: "a non-empty value")
        }
        return raw
    }

    static func integer(
        _ arguments: [String],
        index: inout Int,
        option: String,
        range: ClosedRange<Int>
    ) throws -> Int {
        let raw = try rawValue(arguments, index: &index, option: option)
        guard let value = Int(raw), range.contains(value) else {
            throw CLIArgumentError.invalidValue(
                option: option,
                value: raw,
                expected: "an integer from \(range.lowerBound) through \(range.upperBound)")
        }
        return value
    }

    static func finiteFloat(
        _ arguments: [String],
        index: inout Int,
        option: String,
        expected: String,
        accepting: (Float) -> Bool
    ) throws -> Float {
        let raw = try rawValue(arguments, index: &index, option: option)
        guard let value = Float(raw), value.isFinite, accepting(value) else {
            throw CLIArgumentError.invalidValue(
                option: option,
                value: raw,
                expected: expected)
        }
        return value
    }

    static func finiteDouble(
        _ arguments: [String],
        index: inout Int,
        option: String,
        range: ClosedRange<Double>
    ) throws -> Double {
        let raw = try rawValue(arguments, index: &index, option: option)
        guard let value = Double(raw), value.isFinite, range.contains(value) else {
            throw CLIArgumentError.invalidValue(
                option: option,
                value: raw,
                expected: "a finite number from \(range.lowerBound) through \(range.upperBound)")
        }
        return value
    }

    private static func rawValue(
        _ arguments: [String],
        index: inout Int,
        option: String
    ) throws -> String {
        let valueIndex = index + 1
        guard arguments.indices.contains(valueIndex),
            !arguments[valueIndex].hasPrefix("--")
        else {
            throw CLIArgumentError.missingValue(option: option)
        }
        index = valueIndex
        return arguments[valueIndex]
    }
}
