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

// swiftlint:disable line_length
// Datos sha256 pineados del catálogo de modelos: envolver el hex de cada
// artefacto en varias líneas no aporta legibilidad y dificulta el diff al
// re-pinnear. Se silencia line_length solo para este bloque de datos.
/// The curated registry. Descriptors are code: adding or re-pinning a model
/// is a reviewed change, never a runtime fetch of "latest".
public enum ModelCatalog {
    /// Default engine per task (D7: routing por tarea, jamás un modelo
    /// global): live STT = Parakeet v3; final quality pass = Whisper
    /// large-v3-turbo; diarization = pyannote community-1 + WeSpeaker.
    public static func recommended(for task: ModelTask) -> ModelDescriptor? {
        switch task {
        case .liveTranscription:
            return parakeetTdtV3
        case .finalTranscription:
            return whisperLargeV3Turbo
        case .diarization:
            return speakerDiarization
        case .summarization, .embedding:
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
                sizeBytes: 151_122)
        ],
        minimumRAMGB: 4,
        license: "CC-BY-4.0"
    )

    /// pyannote community-1 segmentation + WeSpeaker v2 embeddings compiled
    /// for CoreML by FluidInference — the M3 diarization pair (~14 MB).
    /// Loaded via `DiarizerModels.load(localSegmentationModel:local…)`, which
    /// never downloads, so the folder name carries no resolver magic here.
    public static let speakerDiarization = ModelDescriptor(
        id: "speaker-diarization-coreml",
        tasks: [.diarization],
        displayName: "pyannote + WeSpeaker (CoreML)",
        folderName: "speaker-diarization-coreml",
        resolveBase: URL(
            string:
                "https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/1ed7a662fdc7109e36d822db793ee6eebdaf8594"
        )!,
        revision: "1ed7a662fdc7109e36d822db793ee6eebdaf8594",
        artifacts: [
            ModelArtifact(
                path: "pyannote_segmentation.mlmodelc/analytics/coremldata.bin",
                sha256: "b379db0541b35344a34bb7540783ae704c11599bbed5aa8bbbda11c20ad215ee",
                sizeBytes: 243),
            ModelArtifact(
                path: "pyannote_segmentation.mlmodelc/coremldata.bin",
                sha256: "4a450ea1b053b9eb7eef0cab6971018076600840c7e246d064e7c5387f456c98",
                sizeBytes: 316),
            ModelArtifact(
                path: "pyannote_segmentation.mlmodelc/metadata.json",
                sha256: "44e1fa36d6abafacf688beccad99f7569394248d8bb41545829997c67668c08c",
                sizeBytes: 1763),
            ModelArtifact(
                path: "pyannote_segmentation.mlmodelc/model.mil",
                sha256: "97f2dec6f83e80bf4247b98e13c2dde19f92c05820ef08068bbf554488d70bdd",
                sizeBytes: 29_490),
            ModelArtifact(
                path: "pyannote_segmentation.mlmodelc/weights/weight.bin",
                sha256: "0266f4ad4d843ecf31ef9220ad6b80616b3ec64a4404b64f3ea0371554e236ec",
                sizeBytes: 5_734_720),
            ModelArtifact(
                path: "wespeaker_v2.mlmodelc/analytics/coremldata.bin",
                sha256: "d2b1fcde6121aea3ff0e14c1dc50d09dacb0314a2e89156353c31804230a422f",
                sizeBytes: 243),
            ModelArtifact(
                path: "wespeaker_v2.mlmodelc/coremldata.bin",
                sha256: "6feb2472a71fa9d8a84020c85206138a4f6261c565c9884bf518d59dd5838da7",
                sizeBytes: 359),
            ModelArtifact(
                path: "wespeaker_v2.mlmodelc/metadata.json",
                sha256: "ddc4858b4051254098015cd0b97080149839d697faf7b036f933190e70b26758",
                sizeBytes: 2738),
            ModelArtifact(
                path: "wespeaker_v2.mlmodelc/model.mil",
                sha256: "2850f775d6ba659f01f616fed77ce6a45a25de3eb7e4bf3a4b07b658be4e13dd",
                sizeBytes: 706_900),
            ModelArtifact(
                path: "wespeaker_v2.mlmodelc/weights/weight.bin",
                sha256: "34004f6798d35cad7071e2fdc67e63faaa782f53697e1cb49bcb452cf81ae151",
                sizeBytes: 7_243_904)
        ],
        minimumRAMGB: 2,
        license: "CC-BY-4.0"
    )

    /// Whisper large-v3-turbo compiled for CoreML by Argmax — the quality
    /// re-pass engine (D7: final transcription). 1.6 GB; heavy on purpose:
    /// it replaces the live transcript once the meeting is over.
    public static let whisperLargeV3Turbo = ModelDescriptor(
        id: "whisper-large-v3-turbo",
        tasks: [.finalTranscription],
        displayName: "Whisper large-v3-turbo (CoreML)",
        folderName: "whisper-large-v3-turbo",
        resolveBase: URL(
            string:
                "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/97a5bf9bbc74c7d9c12c755d04dea59e672e3808/openai_whisper-large-v3-v20240930_turbo"
        )!,
        revision: "97a5bf9bbc74c7d9c12c755d04dea59e672e3808",
        artifacts: [
            ModelArtifact(path: "AudioEncoder.mlmodelc/analytics/coremldata.bin", sha256: "b58d36a7f4a729570b46b424ed8d847baefa07580e6cb9d47773ae738f8b845a", sizeBytes: 243),
            ModelArtifact(path: "AudioEncoder.mlmodelc/coremldata.bin", sha256: "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3", sizeBytes: 348),
            ModelArtifact(path: "AudioEncoder.mlmodelc/metadata.json", sha256: "3f8920fecd553c40dfc978e1b2664cefbac80d97937c2c160e079b37cfa95e13", sizeBytes: 1824),
            ModelArtifact(path: "AudioEncoder.mlmodelc/model.mil", sha256: "9aac7799f12bc5fc414cb0bd6b60536d4fb7723d8bb0d879e3c0ceb220b224aa", sizeBytes: 7175750),
            ModelArtifact(path: "AudioEncoder.mlmodelc/model.mlmodel", sha256: "c5eb570c19871d7b0c59e0a84718cc9c8cde77a94273886de87e866961262e2c", sizeBytes: 441653),
            ModelArtifact(path: "AudioEncoder.mlmodelc/weights/weight.bin", sha256: "98daf651a919978e28fe185daf55ce2f70085a8e59fa07fe8a4d08c87d368ae4", sizeBytes: 1273974400),
            ModelArtifact(path: "MelSpectrogram.mlmodelc/analytics/coremldata.bin", sha256: "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce", sizeBytes: 243),
            ModelArtifact(path: "MelSpectrogram.mlmodelc/coremldata.bin", sha256: "98efa1e351b759e078c4044668926d32bee886caf7596ae897e08e21da45565a", sizeBytes: 329),
            ModelArtifact(path: "MelSpectrogram.mlmodelc/metadata.json", sha256: "2bc552e09a6f124d9e6c178dd1a6979e010206acb26308b2224887c9dcbeb35f", sizeBytes: 1850),
            ModelArtifact(path: "MelSpectrogram.mlmodelc/model.mil", sha256: "c270b95b5f81d7f7d0b8a3e8f991d4e5812a37cad29349868a35b91f3a6a4463", sizeBytes: 10143),
            ModelArtifact(path: "MelSpectrogram.mlmodelc/weights/weight.bin", sha256: "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49", sizeBytes: 373376),
            ModelArtifact(path: "TextDecoder.mlmodelc/analytics/coremldata.bin", sha256: "47703aed03fbfa5128e118cfe6519024006f953a53e921d66003f1412c27996c", sizeBytes: 243),
            ModelArtifact(path: "TextDecoder.mlmodelc/coremldata.bin", sha256: "605dad4099a82cf2c7afe93e6d8e322f1c16d4160ab27bd017ec2517b81c1bdd", sizeBytes: 633),
            ModelArtifact(path: "TextDecoder.mlmodelc/metadata.json", sha256: "de6afb1e8fa1d01568b8d96283ca17af19f6124f151d0fdbdbd5917edc7b4836", sizeBytes: 4756),
            ModelArtifact(path: "TextDecoder.mlmodelc/model.mil", sha256: "1a1c2ec962fc7c9d2de9e2e4cf2d3827c8671f86a918b5698c00bf62c322ed3f", sizeBytes: 132680),
            ModelArtifact(path: "TextDecoder.mlmodelc/model.mlmodel", sha256: "03b79e4355e814c56239ea809e5d8f6432d70d74256bc9d70c27184fe9fcec48", sizeBytes: 113164),
            ModelArtifact(path: "TextDecoder.mlmodelc/weights/weight.bin", sha256: "47b2703aa37448e09cf2f06e45984fabd5ded4c34ba3400cec38a5294af39dc1", sizeBytes: 343933748),
            ModelArtifact(path: "TextDecoderContextPrefill.mlmodelc/analytics/coremldata.bin", sha256: "97639d36c7b137ea51c3c39b175911788f4d4a601ab03cd67a4b14164c3145e1", sizeBytes: 243),
            ModelArtifact(path: "TextDecoderContextPrefill.mlmodelc/coremldata.bin", sha256: "2c159f5c862ec187092ea58e755d8c0b298952e22f3d75da023d7693c1c7389e", sizeBytes: 380),
            ModelArtifact(path: "TextDecoderContextPrefill.mlmodelc/metadata.json", sha256: "eb88dc350fa6748a8bc3fa5fb10958152c138752ebbbac1824d2f99b4c9fc068", sizeBytes: 2240),
            ModelArtifact(path: "TextDecoderContextPrefill.mlmodelc/model.mil", sha256: "990ff5052fd817e28ba7c34d9d06d324c69c7c0630b6eaac9cfdf08329dbcb34", sizeBytes: 4092),
            ModelArtifact(path: "TextDecoderContextPrefill.mlmodelc/weights/weight.bin", sha256: "1310070082639173e9d81508c5f220692d489e85655aa6883cc1c7506da7fcfd", sizeBytes: 12288192),
            ModelArtifact(path: "config.json", sha256: "f01d83dd891791d6f12421c05d3ed8ebbe70866f10d6c9a7a7e80b558ce5a0f1", sizeBytes: 1149),
            ModelArtifact(path: "generation_config.json", sha256: "7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6", sizeBytes: 2767)
        ],
        minimumRAMGB: 8,
        license: "MIT"
    )

    /// Whisper large-v3 compact (626 MB, Argmax CoreML) — the low-disk
    /// alternative to turbo for the D7 quality re-pass (M12). Mixed-bit
    /// quantized; recommended multilingual small-footprint variant. Same
    /// tokenizer as turbo. Artifacts sha256-pinned like every model (D7).
    public static let whisperLargeV3_626MB = ModelDescriptor(
        id: "whisper-large-v3-626mb",
        tasks: [.finalTranscription],
        displayName: "Whisper large-v3 compacto (626 MB)",
        folderName: "whisper-large-v3-626mb",
        resolveBase: URL(
            string:
                "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/97a5bf9bbc74c7d9c12c755d04dea59e672e3808/openai_whisper-large-v3-v20240930_626MB"
        )!,
        revision: "97a5bf9bbc74c7d9c12c755d04dea59e672e3808",
        artifacts: [
            ModelArtifact(path: "AudioEncoder.mlmodelc/analytics/coremldata.bin", sha256: "56793886ab1adb9ca8a4e335efbe8af6640f40d958ab2d29c3ad2d7d6f712e95", sizeBytes: 243),
            ModelArtifact(path: "AudioEncoder.mlmodelc/coremldata.bin", sha256: "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3", sizeBytes: 348),
            ModelArtifact(path: "AudioEncoder.mlmodelc/metadata.json", sha256: "a87a3375afe79e88e27af30247e234e706b98679dedfd1b021a74f7ee108c669", sizeBytes: 1922),
            ModelArtifact(path: "AudioEncoder.mlmodelc/model.mil", sha256: "3cec2580fb07b12a88087f0e1586c6ba2982980eb36499561e1ffca2b0950442", sizeBytes: 934263),
            ModelArtifact(path: "AudioEncoder.mlmodelc/weights/weight.bin", sha256: "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1", sizeBytes: 421968768),
            ModelArtifact(path: "MelSpectrogram.mlmodelc/analytics/coremldata.bin", sha256: "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce", sizeBytes: 243),
            ModelArtifact(path: "MelSpectrogram.mlmodelc/coremldata.bin", sha256: "2bfc12cffc2e45e039c7a18f384f09adffb72c182fcd93f9413d405d1a6c1130", sizeBytes: 329),
            ModelArtifact(path: "MelSpectrogram.mlmodelc/metadata.json", sha256: "2bc552e09a6f124d9e6c178dd1a6979e010206acb26308b2224887c9dcbeb35f", sizeBytes: 1850),
            ModelArtifact(path: "MelSpectrogram.mlmodelc/model.mil", sha256: "c270b95b5f81d7f7d0b8a3e8f991d4e5812a37cad29349868a35b91f3a6a4463", sizeBytes: 10143),
            ModelArtifact(path: "MelSpectrogram.mlmodelc/weights/weight.bin", sha256: "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49", sizeBytes: 373376),
            ModelArtifact(path: "TextDecoder.mlmodelc/analytics/coremldata.bin", sha256: "3913b8c9716b284a917cf3744f4d415f2a05e2b910594a14c6cc10092284d3f8", sizeBytes: 243),
            ModelArtifact(path: "TextDecoder.mlmodelc/coremldata.bin", sha256: "3faabaf66930e66956d8291d0ff485fb382496e30a91a7185548b9b898ce90a9", sizeBytes: 633),
            ModelArtifact(path: "TextDecoder.mlmodelc/metadata.json", sha256: "994f6030d7b1a8be999940444c3cf5d6a57d40ddd4423cf1d1fc93520aa1b052", sizeBytes: 4924),
            ModelArtifact(path: "TextDecoder.mlmodelc/model.mil", sha256: "dbe833be9e64348c95b7fa598d0ae4309a91aedce4e82fa500a714b0e4b5d754", sizeBytes: 217177),
            ModelArtifact(path: "TextDecoder.mlmodelc/weights/weight.bin", sha256: "d69700903d518ada33170ab77faaaf464496fb9ff65752c6d5a6109aa2fb02db", sizeBytes: 203199860),
            ModelArtifact(path: "config.json", sha256: "f01d83dd891791d6f12421c05d3ed8ebbe70866f10d6c9a7a7e80b558ce5a0f1", sizeBytes: 1149),
            ModelArtifact(path: "generation_config.json", sha256: "7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6", sizeBytes: 2767)
        ],
        minimumRAMGB: 6,
        license: "MIT"
    )

    /// Whisper's tokenizer files, staged so WhisperKit never reaches the
    /// network for them (its loader prefers a local tokenizer.json).
    public static let whisperTokenizer = ModelDescriptor(
        id: "whisper-large-v3-tokenizer",
        tasks: [.finalTranscription],
        displayName: "Whisper large-v3 tokenizer",
        folderName: "whisper-large-v3-tokenizer",
        resolveBase: URL(
            string:
                "https://huggingface.co/openai/whisper-large-v3/resolve/06f233fe06e710322aca913c1bc4249a0d71fce1"
        )!,
        revision: "06f233fe06e710322aca913c1bc4249a0d71fce1",
        artifacts: [
            ModelArtifact(path: "special_tokens_map.json", sha256: "1c70773c078cb2ca96e0fcff113102f1d3e2b1504272c3bb63b035d4a6700d87", sizeBytes: 2072),
            ModelArtifact(path: "tokenizer.json", sha256: "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca", sizeBytes: 2480617),
            ModelArtifact(path: "tokenizer_config.json", sha256: "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389", sizeBytes: 282843)
        ],
        minimumRAMGB: 1,
        license: "Apache-2.0"
    )
}
// swiftlint:enable line_length
