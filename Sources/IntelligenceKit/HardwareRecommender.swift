import Foundation

/// "Recomendado para tu Mac" (D25/M12): reads a machine's facts and picks
/// the summary engine that fits, with plain-language reasons. Pure — the
/// facts are injected, so the logic is unit-tested; the app gathers the
/// real profile.
public struct HardwareProfile: Sendable, Equatable {
    public var memoryGB: Int
    public var appleIntelligence: Bool
    public var ollamaAvailable: Bool
    public var freeDiskGB: Int

    public init(memoryGB: Int, appleIntelligence: Bool, ollamaAvailable: Bool, freeDiskGB: Int) {
        self.memoryGB = memoryGB
        self.appleIntelligence = appleIntelligence
        self.ollamaAvailable = ollamaAvailable
        self.freeDiskGB = freeDiskGB
    }
}

public enum RecommendedEngine: String, Sendable {
    case apple
    case ollama
    /// The embedded MLX model (D25 last mile): no installs, ~2.3 GB download.
    case mlx
    /// Neither local engine is available — the app should point the user at
    /// installing Ollama or configuring BYOK.
    case none
}

public struct EngineAdvice: Sendable, Equatable {
    public var engine: RecommendedEngine
    public var headline: String
    public var reasons: [String]
    /// Prefer the smaller Whisper (626 MB) over turbo (1.6 GB) for refine.
    public var whisperLowDisk: Bool
}

public enum HardwareRecommender {
    public static func advise(_ profile: HardwareProfile) -> EngineAdvice {
        var reasons: [String] = []
        let engine: RecommendedEngine
        let headline: String

        if profile.appleIntelligence {
            engine = .apple
            headline = "Apple Intelligence: on-device summaries, free and fast."
            reasons.append(
                "Your Mac has Apple Intelligence — the summary runs on the Neural Engine without downloading anything.")
        } else if profile.ollamaAvailable {
            engine = .ollama
            headline = "Local Ollama: summaries 100% on your Mac, without Apple Intelligence."
            reasons.append(
                "Apple Intelligence is unavailable, but Ollama is running — local summaries with no cloud.")
            if profile.memoryGB > 0 && profile.memoryGB < 16 {
                reasons.append(
                    "Con \(profile.memoryGB) GB de RAM, prefiere modelos Ollama ≤ 8B para que no se ralentice.")
            }
        } else if profile.memoryGB >= 8, profile.freeDiskGB >= 4 || profile.freeDiskGB == 0 {
            engine = .mlx
            headline = "Built-in local model: summaries without installing anything."
            reasons.append(
                // One-line UI text.
                // swiftlint:disable:next line_length
                "No Apple Intelligence or Ollama, but your Mac can run the embedded model (one 2.3 GB download, verified, 100% on-device).")
        } else {
            engine = .none
            headline = "No local summary engine."
            reasons.append(
                // One-line UI text.
                // swiftlint:disable:next line_length
                "No Apple Intelligence or Ollama, and the embedded model needs 8 GB of RAM and 4 GB of disk. Install Ollama (ollama.com) or configure BYOK in Settings.")
        }

        let lowDisk = profile.freeDiskGB > 0 && profile.freeDiskGB < 8
        if lowDisk {
            reasons.append(
                "Poco disco libre (\(profile.freeDiskGB) GB): para el refine conviene la variante Whisper de 626 MB en vez de la de 1.6 GB.")
        }

        return EngineAdvice(
            engine: engine, headline: headline, reasons: reasons, whisperLowDisk: lowDisk)
    }
}
