import Foundation

/// Exact compatibility identity for persisted semantic vectors.
///
/// The model identity is not enough: changing Portavoz's pooling pipeline or
/// binary vector representation also creates a different vector space. The
/// stable SHA-256 fingerprint is safe to persist and compare without exposing
/// transcript content.
public struct SemanticEmbeddingProfile: Codable, Equatable, Hashable, Sendable {
    public let modelIdentifier: String
    public let modelRevision: Int
    public let vectorDimension: Int
    public let pipelineIdentifier: String
    public let pipelineRevision: Int
    public let vectorSchemaVersion: Int

    public init(
        modelIdentifier: String,
        modelRevision: Int,
        vectorDimension: Int,
        pipelineIdentifier: String,
        pipelineRevision: Int,
        vectorSchemaVersion: Int
    ) {
        self.modelIdentifier = modelIdentifier
        self.modelRevision = modelRevision
        self.vectorDimension = vectorDimension
        self.pipelineIdentifier = pipelineIdentifier
        self.pipelineRevision = pipelineRevision
        self.vectorSchemaVersion = vectorSchemaVersion
    }

    public var isValid: Bool {
        !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && modelRevision >= 0
            && vectorDimension > 0
            && !pipelineIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pipelineRevision > 0
            && vectorSchemaVersion > 0
    }

    public var fingerprint: String {
        OperationFingerprint.make(
            version: "semantic-embedding-profile-v1",
            components: [
                modelIdentifier,
                String(modelRevision),
                String(vectorDimension),
                pipelineIdentifier,
                String(pipelineRevision),
                String(vectorSchemaVersion)
            ])
    }
}
