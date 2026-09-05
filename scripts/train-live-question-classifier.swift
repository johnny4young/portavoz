#!/usr/bin/env swift

import CreateML
import CryptoKit
import Foundation

private let expectedCorpusSHA256 =
    "d7d15611f91148ee4e4dd10cb3ea214b747009b82b2e82647bb7a8ab970dbe3d"

private struct Corpus: Decodable {
    let schemaVersion: Int
    let kind: String
    let generation: String
    let contentSource: String
    let license: String
    let labels: [String: [String]]
}

private enum TrainingError: Error, LocalizedError {
    case invalidArguments
    case invalidCorpus
    case outputExists

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "usage: xcrun swift scripts/train-live-question-classifier.swift CORPUS OUTPUT.mlmodel"
        case .invalidCorpus:
            "the LIVE-1 training corpus is missing, stale, overlapping, or malformed"
        case .outputExists:
            "the output model already exists"
        }
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func train() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else { throw TrainingError.invalidArguments }
    let corpusURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    let outputURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    guard !FileManager.default.fileExists(atPath: outputURL.path)
    else { throw TrainingError.outputExists }

    let data = try Data(contentsOf: corpusURL, options: .mappedIfSafe)
    guard sha256(data) == expectedCorpusSHA256,
          let corpus = try? JSONDecoder().decode(Corpus.self, from: data),
          corpus.schemaVersion == 1,
          corpus.kind == "live-question-training-corpus",
          corpus.generation == "public-synthetic-bilingual-v1",
          corpus.contentSource == "public-synthetic-only",
          corpus.license == "CC0-1.0",
          Set(corpus.labels.keys) == ["question", "nonQuestion", "abstain"],
          corpus.labels.values.allSatisfy({ $0.count >= 40 }),
          Set(corpus.labels.values.flatMap { $0 }).count
            == corpus.labels.values.reduce(0, { $0 + $1.count })
    else { throw TrainingError.invalidCorpus }

    let parameters = MLTextClassifier.ModelParameters(
        validation: .none,
        algorithm: .maxEnt(revision: 1),
        language: nil)
    let classifier = try MLTextClassifier(
        trainingData: corpus.labels,
        parameters: parameters)
    try classifier.write(
        to: outputURL,
        metadata: MLModelMetadata(
            author: "Portavoz",
            shortDescription: "Bilingual live-meeting question admission classifier.",
            license: "CC0-1.0 training corpus; generated model distributed under MIT.",
            version: "1.0.0",
            additional: [
                "corpusGeneration": corpus.generation,
                "corpusSHA256": expectedCorpusSHA256,
                "featurePolicy": "deterministic-name-punctuation-confidence-v1",
            ]))
    print("trainingMetrics=\(classifier.trainingMetrics)")
    print("model=\(outputURL.path)")
}

do {
    try train()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
