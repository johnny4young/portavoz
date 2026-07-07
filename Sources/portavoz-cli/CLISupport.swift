import Foundation
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
            fatalError("catalog has no transcription model")
        }
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
        return try await ParakeetEngine.load(fromVerifiedDirectory: directory)
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
