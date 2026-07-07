import Foundation
import NaturalLanguage

/// On-device sentence embeddings via Apple's contextual embedding model
/// (NaturalLanguage). One Latin-script model covers Spanish AND English
/// in a shared vector space — exactly what a bilingual meeting library
/// needs. Vectors are mean-pooled token embeddings, L2-normalized so
/// cosine similarity is a plain dot product.
///
/// Zero third-party downloads: the OS fetches its own assets on first
/// use (`prepare()`), like keyboard dictation models do.
public actor SentenceEmbedder {
    public enum EmbedderError: Error, LocalizedError {
        case unsupported
        case assetsUnavailable

        public var errorDescription: String? {
            switch self {
            case .unsupported:
                return "this OS has no Latin-script contextual embedding model"
            case .assetsUnavailable:
                return "the embedding assets are not installed yet (network needed once)"
            }
        }
    }

    private let embedding: NLContextualEmbedding
    private var loaded = false

    public init() throws {
        guard let embedding = NLContextualEmbedding(script: .latin) else {
            throw EmbedderError.unsupported
        }
        self.embedding = embedding
    }

    /// Vector dimensionality of the underlying model.
    public var dimension: Int { embedding.dimension }

    /// Requests OS assets if missing, then loads the model.
    public func prepare() async throws {
        if !embedding.hasAvailableAssets {
            let result = try await embedding.requestAssets()
            guard result == .available else { throw EmbedderError.assetsUnavailable }
        }
        if !loaded {
            try embedding.load()
            loaded = true
        }
    }

    /// Embeds a batch of sentences (mean-pooled, L2-normalized).
    public func embed(_ texts: [String]) throws -> [[Float]] {
        try texts.map { text in
            let result = try embedding.embeddingResult(for: text, language: nil)
            var sum = [Double](repeating: 0, count: embedding.dimension)
            var count = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                for index in 0..<min(vector.count, sum.count) {
                    sum[index] += vector[index]
                }
                count += 1
                return true
            }
            guard count > 0 else {
                return [Float](repeating: 0, count: embedding.dimension)
            }
            var mean = sum.map { Float($0 / Double(count)) }
            let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
            if norm > 0 {
                for index in 0..<mean.count { mean[index] /= norm }
            }
            return mean
        }
    }
}
