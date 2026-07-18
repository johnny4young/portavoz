import ApplicationKit
import Foundation

/// `portavoz-cli voice <enroll --file <wav>|status|delete> [--models-dir <dir>]`
///
/// Enrollment stores only a 256-dim voice embedding, AES-GCM-encrypted
/// with a Keychain key — biometric data per D8: on-device, never synced,
/// deletable in one action. The source audio is not kept.
enum VoiceCommand {
    // CLI de desarrollo: el parser de flags es un switch inherentemente largo.
    // swiftlint:disable:next cyclomatic_complexity
    static func run(
        _ arguments: [String],
        platform: CLIPlatformDependencies
    ) async {
        var arguments = arguments
        guard let action = arguments.first else {
            printUsage()
            return
        }
        arguments.removeFirst()

        var file: String?
        var modelsDir: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--file":
                index += 1
                if index < arguments.count { file = arguments[index] }
            case "--models-dir":
                index += 1
                if index < arguments.count { modelsDir = arguments[index] }
            default:
                print("Unknown option: \(arguments[index])")
                return
            }
            index += 1
        }

        let workflow = platform.voiceIdentity(modelsDirectory: modelsDir)
        do {
            switch action {
            case "enroll":
                guard let file else {
                    print("Usage: portavoz-cli voice enroll --file <wav-solo-tu-voz>")
                    print("Tip: record it with `portavoz-cli record --seconds 15` while speaking alone.")
                    return
                }
                let url = URL(fileURLWithPath: file)
                guard case .enrolled(let voiceprint) = try await workflow.execute(
                    .enroll(fileURL: url))
                else { return }
                print("Voice enrolled ✓ (embedding de \(voiceprint.embedding.count) dims, encrypted on disk, key in Keychain).")
                print("Desde ahora tus intervenciones en el canal system se etiquetan como \"Me\".")

            case "status":
                guard case .status(let voiceprint) = try await workflow.execute(.status)
                else { return }
                if let voiceprint {
                    print("Voice enrolled on \(voiceprint.createdAt.formatted(date: .abbreviated, time: .shortened)) (\(voiceprint.embedding.count) dims).")
                } else {
                    print("No hay voz enrolada.")
                }

            case "delete":
                _ = try await workflow.execute(.delete)
                print("Voiceprint y llave eliminados.")

            default:
                printUsage()
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }

    static func printUsage() {
        print(
            """
            Usage:
              portavoz-cli voice enroll --file <wav> [--models-dir <dir>]
              portavoz-cli voice status
              portavoz-cli voice delete
            """
        )
    }
}
