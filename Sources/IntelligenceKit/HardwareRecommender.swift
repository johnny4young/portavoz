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
            headline = "Apple Intelligence: resúmenes on-device, gratis y rápidos."
            reasons.append(
                "Tu Mac tiene Apple Intelligence — el resumen corre en el Neural Engine sin descargar nada.")
        } else if profile.ollamaAvailable {
            engine = .ollama
            headline = "Ollama local: resúmenes 100% en tu Mac, sin Apple Intelligence."
            reasons.append(
                "No hay Apple Intelligence, pero Ollama está corriendo — resúmenes locales sin nube.")
            if profile.memoryGB > 0 && profile.memoryGB < 16 {
                reasons.append(
                    "Con \(profile.memoryGB) GB de RAM, prefiere modelos Ollama ≤ 8B para que no se ralentice.")
            }
        } else {
            engine = .none
            headline = "Sin motor local de resúmenes."
            reasons.append(
                "Sin Apple Intelligence ni Ollama. Instala Ollama (ollama.com) para resúmenes locales, o configura BYOK en Ajustes.")
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
