import DiarizationKit
import Foundation
import ModelStoreKit

/// `portavoz-cli der --file <wav> --reference <rttm> [--threshold t]
///                   [--collar 0.25] [--models-dir <dir>]`
///
/// Diarizes the file and scores it against an RTTM reference — the M3
/// acceptance metric (DER < 15%) as a number instead of a hope.
enum DerCommand {
    // CLI de desarrollo: el parser de flags es un switch inherentemente largo.
    // swiftlint:disable:next cyclomatic_complexity
    static func run(_ arguments: [String]) async {
        var file: String?
        var reference: String?
        var threshold = PyannoteDiarizer.defaultClusteringThreshold
        var collar = DiarizationEvaluation.standardCollar
        var modelsDir: String?

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--file":
                index += 1
                if index < arguments.count { file = arguments[index] }
            case "--reference":
                index += 1
                if index < arguments.count { reference = arguments[index] }
            case "--threshold":
                index += 1
                if index < arguments.count { threshold = Float(arguments[index]) ?? threshold }
            case "--collar":
                index += 1
                if index < arguments.count { collar = Double(arguments[index]) ?? collar }
            case "--models-dir":
                index += 1
                if index < arguments.count { modelsDir = arguments[index] }
            default:
                print("Unknown option: \(arguments[index])")
                return
            }
            index += 1
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
                format: "DER %.1f%% (miss %.1f%% · falsa alarma %.1f%% · confusión %.1f%%) — collar %.2fs",
                score.der * 100, score.miss * 100, score.falseAlarm * 100,
                score.confusion * 100, collar))
            print("speakers: referencia \(refSpeakers) · hipótesis \(hypSpeakers) · mapeo \(score.mapping)")
            print(score.der < 0.15
                ? "M3: PASS ✓ (DER < 15%)"
                : "M3: FAIL ✗ (criterio: DER < 15%)")
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}
