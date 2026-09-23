import Foundation

extension ModelCatalog {
    /// Only the unified 256 ms Silero CoreML bundle used by FluidAudio 0.15.8.
    /// Callers load it from a verified ModelStore installation, never through
    /// FluidAudio's downloading ModelHub initializer.
    public static let sileroVAD = ModelDescriptor(
        id: "silero-vad-v6.2.1-coreml",
        tasks: [.voiceActivity],
        displayName: "Silero VAD v6.2.1 (CoreML)",
        folderName: "silero-vad-coreml",
        resolveBase: URL(
            string:
                "https://huggingface.co/FluidInference/silero-vad-coreml/resolve/b419383c55c110e2c9271fa6ee0ea83d03c70d96"
        )!,
        revision: "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
        artifacts: [
            ModelArtifact(
                path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/analytics/coremldata.bin",
                sha256: "8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909",
                sizeBytes: 243),
            ModelArtifact(
                path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/coremldata.bin",
                sha256: "7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41",
                sizeBytes: 625),
            ModelArtifact(
                path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/metadata.json",
                sha256: "2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6",
                sizeBytes: 3_335),
            ModelArtifact(
                path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/model.mil",
                sha256: "c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270",
                sizeBytes: 176_918),
            ModelArtifact(
                path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/weights/weight.bin",
                sha256: "53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063",
                sizeBytes: 882_304)
        ],
        minimumRAMGB: 2,
        license: "MIT"
    )
}
