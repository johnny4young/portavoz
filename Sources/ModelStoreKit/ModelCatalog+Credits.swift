import Foundation

/// Attribution for one curated model: the original work, its creator and license,
/// and the pinned repository Portavoz downloads its build from.
public struct ModelCredit: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let creator: String
    public let license: String
    public let source: URL
}

extension ModelDescriptor {
    /// The repository page behind `resolveBase`, without the pinned file path.
    public var sourcePage: URL {
        let base = resolveBase.absoluteString
        guard let range = base.range(of: "/resolve/") else { return resolveBase }
        return URL(string: String(base[..<range.lowerBound])) ?? resolveBase
    }

    func credit(_ name: String, by creator: String) -> ModelCredit {
        ModelCredit(id: id, name: name, creator: creator, license: license, source: sourcePage)
    }
}

extension ModelCatalog {
    /// Every model the app can download, credited to the original authors.
    public static var credits: [ModelCredit] {
        [
            parakeetTdtV3.credit("Parakeet TDT 0.6B v3", by: "NVIDIA"),
            parakeetUltra.credit(
                "Parakeet Ultra, a post-training of Parakeet TDT 0.6B v3", by: "moondream, from NVIDIA"),
            whisperLargeV3Turbo.credit("Whisper large-v3-turbo", by: "OpenAI"),
            whisperLargeV3_626MB.credit("Whisper large-v3", by: "OpenAI"),
            whisperTokenizer.credit("Whisper large-v3 tokenizer", by: "OpenAI"),
            speakerDiarization.credit(
                "pyannote speaker-diarization-community-1 and WeSpeaker", by: "pyannote.audio and WeSpeaker"),
            sileroVAD.credit("Silero VAD v6.2.1", by: "Silero team"),
            mlxQwen3.credit("Qwen3 4B Instruct 2507", by: "Qwen team, Alibaba Cloud"),
            mlxQwen35.credit("Qwen3.5 4B", by: "Qwen team, Alibaba Cloud")
        ]
    }
}
