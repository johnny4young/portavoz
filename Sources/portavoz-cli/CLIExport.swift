import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit

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
            let store = application.store
            let meetingID = MeetingID(rawValue: uuid)
            guard let detail = try await store.detail(meetingID) else {
                print("error: no such meeting")
                return
            }
            let summary = try await store.summary(meetingID)
            let markdown = MeetingExporter.markdown(
                meeting: detail.meeting,
                speakers: detail.speakers,
                segments: detail.segments,
                summary: summary?.draft,
                summaryVersion: summary?.version
            )

            if gist {
                guard let token = await application.platform.credential(
                    for: .gitHubToken,
                    environmentVariable: "PORTAVOZ_GITHUB_TOKEN")
                else {
                    // One-line error message.
                    // swiftlint:disable:next line_length
                    print("error: no GitHub token — run `portavoz-cli secrets set-github-token <token>` (or set PORTAVOZ_GITHUB_TOKEN)")
                    return
                }
                print("⚠️ Publishing the transcript OUTSIDE the device as a \(isPublic ? "PUBLIC" : "secret") gist…")
                let publisher = GistPublisher(
                    token: token,
                    gateway: URLSessionDataEgressGateway(receiptRecorder: store))
                let url = try await publisher.publish(
                    meetingID: meetingID,
                    markdown: markdown,
                    filename: "\(slug(detail.meeting.title)).md",
                    description: detail.meeting.title,
                    isPublic: isPublic
                )
                print(url.absoluteString)
                return
            }

            switch format {
            case "md":
                if let out {
                    try Data(markdown.utf8).write(to: URL(fileURLWithPath: out))
                    print("OK → \(out)")
                } else {
                    print(markdown)
                }
            case "pdf":
                guard let out else {
                    print("error: --format pdf requires --out <path>")
                    return
                }
                let data = try MeetingExporter.pdf(fromMarkdown: markdown)
                try data.write(to: URL(fileURLWithPath: out))
                print("OK → \(out) (\(data.count / 1024) KB)")
            default:
                print("error: unknown format \(format) (md|pdf)")
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }

    static func slug(_ title: String) -> String {
        let allowed = title.lowercased().map { char -> Character in
            char.isLetter || char.isNumber ? char : "-"
        }
        return String(allowed).split(separator: "-").joined(separator: "-")
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
