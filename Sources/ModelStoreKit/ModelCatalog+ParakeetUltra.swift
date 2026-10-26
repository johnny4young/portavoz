import Foundation

extension ModelCatalog {
    /// Opt-in dictation checkpoint with the v3 component contract. Never a
    /// recommended default: only an explicit Settings choice installs it.
    public static let parakeetUltra = ModelDescriptor(
        id: "parakeet-ultra-coreml",
        tasks: [.liveTranscription],
        displayName: "Parakeet Ultra (CoreML)",
        folderName: "parakeet-ultra",
        resolveBase: URL(
            string:
                "https://huggingface.co/FluidInference/parakeet-ultra-coreml/resolve/95eaa59a39d4394f047a4dc5cce480388a60d1b6"
        )!,
        revision: "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
        artifacts: [
            ModelArtifact(
                path: "Decoder.mlmodelc/analytics/coremldata.bin",
                sha256: "fe92b6cfaa012abd5248c0bc877832f19807015abffc60d87b8ccc8ccb48b3b5",
                sizeBytes: 243),
            ModelArtifact(
                path: "Decoder.mlmodelc/coremldata.bin",
                sha256: "3b06e66768f0df7e21795f50e2b29300e33eeb1a2579dc42c695279c2d308497",
                sizeBytes: 560),
            ModelArtifact(
                path: "Decoder.mlmodelc/model.mil",
                sha256: "956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955",
                sizeBytes: 13_110),
            ModelArtifact(
                path: "Decoder.mlmodelc/weights/weight.bin",
                sha256: "02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4",
                sizeBytes: 23_604_992),
            ModelArtifact(
                path: "Encoder.mlmodelc/analytics/coremldata.bin",
                sha256: "d87101d824d6723cf95304da33755c3c60e762663b9ef2b0c4bd0aa166a09a0d",
                sizeBytes: 243),
            ModelArtifact(
                path: "Encoder.mlmodelc/coremldata.bin",
                sha256: "397a84a4062f563cbc5f56077c674f09a61d85be5090f61d2f1932afb92ac0fe",
                sizeBytes: 514),
            ModelArtifact(
                path: "Encoder.mlmodelc/model.mil",
                sha256: "f5d601568a4171d99a314c0fe3f6bc67715da2623732a3fb566e050ea83e5848",
                sizeBytes: 1_002_653),
            ModelArtifact(
                path: "Encoder.mlmodelc/weights/weight.bin",
                sha256: "315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b",
                sizeBytes: 594_211_328),
            ModelArtifact(
                path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin",
                sha256: "68d38ca646aebafa7a9329e2efda50f5767c49e89fdb5f77f212072bb66f97c4",
                sizeBytes: 243),
            ModelArtifact(
                path: "JointDecisionv3.mlmodelc/coremldata.bin",
                sha256: "5e3af5a4ce686f6c237cadbd9284e10d333bc0e1546633cd0e430e6194044bc4",
                sizeBytes: 592),
            ModelArtifact(
                path: "JointDecisionv3.mlmodelc/model.mil",
                sha256: "791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0",
                sizeBytes: 11_777),
            ModelArtifact(
                path: "JointDecisionv3.mlmodelc/weights/weight.bin",
                sha256: "3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25",
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
                sizeBytes: 2_841),
            ModelArtifact(
                path: "Preprocessor.mlmodelc/model.mil",
                sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93",
                sizeBytes: 28_181),
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
}
