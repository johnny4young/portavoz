import Foundation

public extension ModelCatalog {
    /// Evaluation-only challenger for live-summary refinement. It is pinned
    /// and may be installed only by the explicit `--mlx-smoke qwen35-0.8b`
    /// command; Settings, normal routing, and `recommended(for:)` never select
    /// it. Promotion requires Portavoz quality, latency, memory, and energy
    /// evidence rather than upstream benchmark claims.
    static let mlxQwen35Point8BChallenger = ModelDescriptor(
        id: "qwen3.5-0.8b-mlx-4bit-challenger",
        tasks: [.summarization],
        displayName: "Qwen3.5 0.8B challenger (MLX)",
        folderName: "qwen3.5-0.8b-mlx-4bit-challenger",
        resolveBase: URL(
            string:
                "https://huggingface.co/mlx-community/Qwen3.5-0.8B-MLX-4bit/resolve/5d894f8cc4ef3e6c88537bf3746ed262f549da6a"
        )!,
        revision: "5d894f8cc4ef3e6c88537bf3746ed262f549da6a",
        artifacts: [
            artifact(
                "chat_template.jinja",
                "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80", 7755),
            artifact(
                "config.json",
                "ba7770da23eae5ebd6827571f086e331956b33f4442a9e876fb4aa10969a6772", 3112),
            artifact(
                "model.safetensors",
                "f5a0d9dd3efa73510542a8023d610ff26be2b4b020d181cfc4bedaa1fcc5dd9e", 625229487),
            artifact(
                "model.safetensors.index.json",
                "6e48f2fa5d6f033a6d77bf833abfa9698ca24d1715ecea4c67447bcfaee44650", 71473),
            artifact(
                "preprocessor_config.json",
                "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516", 390),
            artifact(
                "processor_config.json",
                "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b", 1300),
            artifact(
                "tokenizer.json",
                "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4", 19989343),
            artifact(
                "tokenizer_config.json",
                "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182", 1139),
            artifact(
                "video_preprocessor_config.json",
                "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13", 385),
            artifact(
                "vocab.json",
                "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003", 6722759)
        ],
        minimumRAMGB: 8,
        license: "Apache-2.0")

    /// Evaluation-only middle challenger. Like the 0.8B candidate, this exact
    /// conversion is inert until a deliberate CLI benchmark installs it and
    /// cannot silently replace the verified 4B serving descriptor.
    static let mlxQwen35TwoBChallenger = ModelDescriptor(
        id: "qwen3.5-2b-mlx-4bit-challenger",
        tasks: [.summarization],
        displayName: "Qwen3.5 2B challenger (MLX)",
        folderName: "qwen3.5-2b-mlx-4bit-challenger",
        resolveBase: URL(
            string:
                "https://huggingface.co/mlx-community/Qwen3.5-2B-MLX-4bit/resolve/93760be4f1f69842a46bc13dbdc0f19e291392a3"
        )!,
        revision: "93760be4f1f69842a46bc13dbdc0f19e291392a3",
        artifacts: [
            artifact(
                "chat_template.jinja",
                "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80", 7755),
            artifact(
                "config.json",
                "beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949", 3113),
            artifact(
                "model.safetensors",
                "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5", 1722271785),
            artifact(
                "model.safetensors.index.json",
                "8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d", 81722),
            artifact(
                "preprocessor_config.json",
                "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516", 390),
            artifact(
                "processor_config.json",
                "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b", 1300),
            artifact(
                "tokenizer.json",
                "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4", 19989343),
            artifact(
                "tokenizer_config.json",
                "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182", 1139),
            artifact(
                "video_preprocessor_config.json",
                "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13", 385),
            artifact(
                "vocab.json",
                "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003", 6722759)
        ],
        minimumRAMGB: 8,
        license: "Apache-2.0")

    private static func artifact(
        _ path: String,
        _ sha256: String,
        _ sizeBytes: Int
    ) -> ModelArtifact {
        ModelArtifact(path: path, sha256: sha256, sizeBytes: sizeBytes)
    }
}
