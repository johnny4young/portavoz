import DiarizationKit
import Foundation
import ModelStoreKit

/// `portavoz-cli der --file <wav> --reference <rttm> [--threshold t]
///                   [--collar 0.25] [--models-dir <dir>]`
///
/// Diarizes the file and scores it against an RTTM reference — the M3
/// acceptance metric (DER < 15%) as a number instead of a hope.
enum DerCommand {
    // The development CLI keeps parsing and execution together for a single
    // fail-closed command boundary.
    // swiftlint:disable:next function_body_length
    static func run(_ arguments: [String]) async {
        var file: String?
        var reference: String?
        var threshold = PyannoteDiarizer.defaultClusteringThreshold
        var collar = DiarizationEvaluation.standardCollar
        var modelsDir: String?

        do {
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--file":
                    file = try CLIOptionValue.string(
                        arguments, index: &index, option: "--file")
                case "--reference":
                    reference = try CLIOptionValue.string(
                        arguments, index: &index, option: "--reference")
                case "--threshold":
                    threshold = try CLIOptionValue.finiteFloat(
                        arguments,
                        index: &index,
                        option: "--threshold",
                        expected: "a finite number greater than 0 and less than 1",
                        accepting: CLIOptionBounds.acceptsDiarizationThreshold)
                case "--collar":
                    collar = try CLIOptionValue.finiteDouble(
                        arguments,
                        index: &index,
                        option: "--collar",
                        range: CLIOptionBounds.diarizationCollar)
                case "--models-dir":
                    modelsDir = try CLIOptionValue.string(
                        arguments, index: &index, option: "--models-dir")
                default:
                    print("Unknown option: \(arguments[index])")
                    return
                }
                index += 1
            }
        } catch {
            print("error: \(error.localizedDescription)")
            return
        }

        guard let file, let reference else {
            print("Usage: portavoz-cli der --file <wav> --reference <rttm> [--threshold t] [--collar s]")
            return
        }

        do {
            let referenceTurns = DiarizationEvaluation.parseRTTM(
                try String(contentsOfFile: reference, encoding: .utf8))
            guard !referenceTurns.isEmpty else {
                print("error: no SPEAKER records in \(reference)")
                return
            }

            let store = CLISupport.modelStore(fromModelsDir: modelsDir)
            // Evaluation is voiceprint-free on purpose: the metric scores
            // anonymous clustering, not the user's enrolled identity.
            let diarizer = try await PyannoteDiarizer.loadRecommended(
                store: store, clusteringThreshold: threshold)
            let hypothesis = try await diarizer.diarizeFile(at: URL(fileURLWithPath: file))

            let score = DiarizationEvaluation.score(
                reference: referenceTurns, hypothesis: hypothesis, collar: collar)

            let refSpeakers = Set(referenceTurns.map(\.voiceLabel)).count
            let hypSpeakers = Set(hypothesis.map(\.voiceLabel)).count
            print(String(
                format: "DER %.1f%% (miss %.1f%% · false alarm %.1f%% · confusion %.1f%%) — collar %.2fs",
                score.der * 100, score.miss * 100, score.falseAlarm * 100,
                score.confusion * 100, collar))
            print("speakers: reference \(refSpeakers) · hypothesis \(hypSpeakers) · mapping \(score.mapping)")
            print(score.der < 0.15
                ? "M3: PASS ✓ (DER < 15%)"
                : "M3: FAIL ✗ (criterio: DER < 15%)")
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}
