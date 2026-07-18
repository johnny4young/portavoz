import ApplicationKit
import Foundation
import PortavozCore

/// `portavoz-cli export --meeting <uuid> [--format md|pdf] [--out <path>]
///                      [--gist [--public]] [--db <path>]`
///
/// Markdown prints to stdout unless --out is given; PDF requires --out.
/// --gist publishes OFF-device (explicit opt-in, D8) using the token from
/// the Keychain (`secrets set-github-token`) or PORTAVOZ_GITHUB_TOKEN.
enum ExportCommand {
    // CLI de desarrollo: el parser de flags es un switch inherentemente largo.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func run(
        _ arguments: [String],
        platform: CLIPlatformDependencies
    ) async {
        var meetingRaw: String?
        var format = "md"
        var out: String?
        var gist = false
        var isPublic = false
        var dbPath: String?

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--meeting":
                index += 1
                if index < arguments.count { meetingRaw = arguments[index] }
            case "--format":
                index += 1
                if index < arguments.count { format = arguments[index] }
            case "--out":
                index += 1
                if index < arguments.count { out = arguments[index] }
            case "--gist":
                gist = true
            case "--public":
                isPublic = true
            case "--db":
                index += 1
                if index < arguments.count { dbPath = arguments[index] }
            default:
                print("Unknown option: \(arguments[index])")
                return
            }
            index += 1
        }

        guard let meetingRaw, let uuid = UUID(uuidString: meetingRaw) else {
            print("Usage: portavoz-cli export --meeting <uuid> [--format md|pdf] [--out <path>] [--gist [--public]]")
            return
        }

        do {
            let application = try CLIComposition.open(
                dbPath: dbPath,
                platform: platform)
            let meetingID = MeetingID(rawValue: uuid)

            let documentFormat: MeetingDocumentFormat
            switch gist ? "md" : format {
            case "md":
                documentFormat = .markdown
            case "pdf":
                documentFormat = .pdf
            default:
                print("error: unknown format \(format) (md|pdf)")
                return
            }

            let workflow = application.exportMeetingDocument(
                publishGist: gist,
                isPublic: isPublic)
            let publishedVisibility = isPublic ? "PUBLIC" : "secret"
            let result = try await workflow.execute(.init(
                meetingID: meetingID,
                format: documentFormat,
                outputURL: out.map { URL(fileURLWithPath: $0) }
            ) { progress in
                if case .publishing = progress {
                    print(
                        "⚠️ Publishing the transcript OUTSIDE the device as a "
                            + "\(publishedVisibility) gist…")
                }
            })
            switch result {
            case .markdown(let markdown):
                print(markdown)
            case .written(_, let bytes):
                if documentFormat == .pdf {
                    print("OK → \(out ?? "") (\(bytes / 1024) KB)")
                } else {
                    print("OK → \(out ?? "")")
                }
            case .published(let url):
                print(url.absoluteString)
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}

/// `portavoz-cli secrets <set-github-token <token>|clear-github-token>`
enum SecretsCommand {
    static func run(
        _ arguments: [String],
        platform: CLIPlatformDependencies
    ) async {
        switch arguments.first {
        case "set-github-token":
            guard arguments.count > 1 else {
                print("Usage: portavoz-cli secrets set-github-token <token>")
                return
            }
            do {
                try await platform.secrets.set(arguments[1], for: .gitHubToken)
                print("Token guardado en el Keychain (solo este dispositivo).")
            } catch {
                print("error: \(error.localizedDescription)")
            }
        case "clear-github-token":
            do {
                try await platform.secrets.delete(.gitHubToken)
                print("Token eliminado del Keychain.")
            } catch {
                print("error: \(error.localizedDescription)")
            }
        case "set-linear-token":
            guard arguments.count > 1 else {
                print("Usage: portavoz-cli secrets set-linear-token <token>")
                return
            }
            do {
                try await platform.secrets.set(arguments[1], for: .linearToken)
                print("Token de Linear guardado en el Keychain (solo este dispositivo).")
            } catch {
                print("error: \(error.localizedDescription)")
            }
        case "clear-linear-token":
            do {
                try await platform.secrets.delete(.linearToken)
                print("Token de Linear eliminado del Keychain.")
            } catch {
                print("error: \(error.localizedDescription)")
            }
        default:
            // One-line usage text.
            // swiftlint:disable:next line_length
            print("Usage: portavoz-cli secrets <set-github-token|clear-github-token|set-linear-token|clear-linear-token> [token]")
        }
    }
}
