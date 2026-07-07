import Foundation
import PortavozCore

/// What a downloadable model is for. One model never serves every task:
/// live STT wants speed, the final pass wants quality, titles want a tiny
/// LLM, summaries a bigger one.
public enum ModelTask: String, Codable, Sendable, CaseIterable {
    case liveTranscription
    case finalTranscription
    case diarization
    case summarization
    case embedding
}

/// One file inside a model distribution. CoreML models ship as `.mlmodelc`
/// bundles (directories of weights + compiled program), so a model is a
/// *set* of artifacts, each pinned individually.
public struct ModelArtifact: Codable, Sendable, Hashable {
    /// Path relative to the model's install directory (e.g.
    /// `Encoder.mlmodelc/weights/weight.bin`).
    public let path: String
    /// SHA-256 of the file contents, lowercase hex. Verified on download and
    /// on every load — a model file is code we execute.
    public let sha256: String
    public let sizeBytes: Int

    public init(path: String, sha256: String, sizeBytes: Int) {
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

/// An entry in the curated model registry. Every artifact is verified
/// against its pinned `sha256`, and `resolveBase` is pinned to an exact
/// upstream revision — never a moving branch.
public struct ModelDescriptor: Codable, Sendable, Identifiable {
    public let id: String
    /// Tasks this model may be routed to (Parakeet v3 covers live *and*
    /// final transcription until WhisperKit lands).
    public let tasks: Set<ModelTask>
    public let displayName: String
    /// Directory name on disk. Must match what the inference runtime
    /// expects (FluidAudio derives the model version from the folder name).
    public let folderName: String
    /// Base URL each artifact path is resolved against. For Hugging Face
    /// this is `…/resolve/<commit-sha>` so the download can never drift.
    public let resolveBase: URL
    /// Upstream revision the artifacts were pinned at (informational; the
    /// binding pin is `resolveBase` + per-artifact sha256).
    public let revision: String
    public let artifacts: [ModelArtifact]
    public let minimumRAMGB: Int
    public let license: String

    public init(
        id: String,
        tasks: Set<ModelTask>,
        displayName: String,
        folderName: String,
        resolveBase: URL,
        revision: String,
        artifacts: [ModelArtifact],
        minimumRAMGB: Int,
        license: String
    ) {
        self.id = id
        self.tasks = tasks
        self.displayName = displayName
        self.folderName = folderName
        self.resolveBase = resolveBase
        self.revision = revision
        self.artifacts = artifacts
        self.minimumRAMGB = minimumRAMGB
        self.license = license
    }

    public var totalSizeBytes: Int {
        artifacts.reduce(0) { $0 + $1.sizeBytes }
    }

    public func downloadURL(for artifact: ModelArtifact) -> URL {
        resolveBase.appendingPathComponent(artifact.path)
    }
}

/// The curated registry. Descriptors are code: adding or re-pinning a model
/// is a reviewed change, never a runtime fetch of "latest".
public enum ModelCatalog {
    /// Default engine per task for M2. Live and final both route to
    /// Parakeet v3; the final pass moves to Whisper large-v3-turbo when
    /// WhisperKit lands (see docs/DECISIONS.md D7).
    public static func recommended(for task: ModelTask) -> ModelDescriptor? {
        switch task {
        case .liveTranscription, .finalTranscription:
            return parakeetTdtV3
        case .diarization, .summarization, .embedding:
            return nil
        }
    }

    /// Parakeet TDT 0.6B v3 (multilingual, incl. es/en) compiled for
    /// CoreML/ANE by FluidInference. Only the int8-encoder subset FluidAudio
    /// actually loads: Preprocessor + Encoder + Decoder + JointDecisionv3 +
    /// vocab — 483 MB instead of the full 3 GB repo.
    ///
    /// Re-pinning procedure: bump the commit in `resolveBase`/`revision`,
    /// then regenerate every artifact hash from the Hugging Face tree API
    /// (LFS files publish sha256 directly; hash small files yourself).
    public static let parakeetTdtV3 = ModelDescriptor(
        id: "parakeet-tdt-0.6b-v3-coreml",
        tasks: [.liveTranscription, .finalTranscription],
        displayName: "Parakeet TDT 0.6B v3 (CoreML)",
        // FluidAudio resolves this exact folder (repo name minus "-coreml");
        // any other name makes it re-download the repo itself, UNVERIFIED,
        // into a sibling directory. Verified on disk 2026-07-06.
        folderName: "parakeet-tdt-0.6b-v3",
        resolveBase: URL(
            string:
                "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/aed02740059203c4a87495924f685de3722ae9ce"
        )!,
        revision: "aed02740059203c4a87495924f685de3722ae9ce",
        artifacts: [
            ModelArtifact(
                path: "Decoder.mlmodelc/analytics/coremldata.bin",
                sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350",
                sizeBytes: 243),
            ModelArtifact(
                path: "Decoder.mlmodelc/coremldata.bin",
                sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99",
                sizeBytes: 554),
            ModelArtifact(
                path: "Decoder.mlmodelc/metadata.json",
                sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9",
                sizeBytes: 3427),
            ModelArtifact(
                path: "Decoder.mlmodelc/model.mil",
                sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35",
                sizeBytes: 13110),
            ModelArtifact(
                path: "Decoder.mlmodelc/weights/weight.bin",
                sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41",
                sizeBytes: 23_604_992),
            ModelArtifact(
                path: "Encoder.mlmodelc/analytics/coremldata.bin",
                sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105",
                sizeBytes: 243),
            ModelArtifact(
                path: "Encoder.mlmodelc/coremldata.bin",
                sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86",
                sizeBytes: 485),
            ModelArtifact(
                path: "Encoder.mlmodelc/metadata.json",
                sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9",
                sizeBytes: 2921),
            ModelArtifact(
                path: "Encoder.mlmodelc/model.mil",
                sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808",
                sizeBytes: 959_769),
            ModelArtifact(
                path: "Encoder.mlmodelc/weights/weight.bin",
                sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421",
                sizeBytes: 445_187_200),
            ModelArtifact(
                path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin",
                sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c",
                sizeBytes: 243),
            ModelArtifact(
                path: "JointDecisionv3.mlmodelc/coremldata.bin",
                sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342",
                sizeBytes: 521),
            ModelArtifact(
                path: "JointDecisionv3.mlmodelc/metadata.json",
                sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f",
                sizeBytes: 3453),
            ModelArtifact(
                path: "JointDecisionv3.mlmodelc/model.mil",
                sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d",
                sizeBytes: 11775),
            ModelArtifact(
                path: "JointDecisionv3.mlmodelc/weights/weight.bin",
                sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e",
                sizeBytes: 12_642_764),
            ModelArtifact(
                path: "Preprocessor.mlmodelc/analytics/coremldata.bin",
                sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d",
                sizeBytes: 243),
            ModelArtifact(
                path: "Preprocessor.mlmodelc/coremldata.bin",
                sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d",
                sizeBytes: 486),
            ModelArtifact(
                path: "Preprocessor.mlmodelc/metadata.json",
                sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf",
                sizeBytes: 2841),
            ModelArtifact(
                path: "Preprocessor.mlmodelc/model.mil",
                sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93",
                sizeBytes: 28181),
            ModelArtifact(
                path: "Preprocessor.mlmodelc/weights/weight.bin",
                sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea",
                sizeBytes: 491_072),
            ModelArtifact(
                path: "parakeet_vocab.json",
                sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735",
                sizeBytes: 151_122),
        ],
        minimumRAMGB: 4,
        license: "CC-BY-4.0"
    )
}
