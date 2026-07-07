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
    static func run(_ arguments: [String]) async {
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
            let store = try MeetingsCommand.openStore(dbPath: dbPath)
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
                guard
                    let token = (try? SecretStore.get(service: SecretStore.gitHubTokenService))
                        ?? ProcessInfo.processInfo.environment["PORTAVOZ_GITHUB_TOKEN"]
                else {
                    print("error: no GitHub token — run `portavoz-cli secrets set-github-token <token>` (or set PORTAVOZ_GITHUB_TOKEN)")
                    return
                }
                print("⚠️ Publicando el transcript FUERA del dispositivo como gist \(isPublic ? "PÚBLICO" : "secreto")…")
                let publisher = GistPublisher(token: token)
                let url = try await publisher.publish(
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
    static func run(_ arguments: [String]) {
        switch arguments.first {
        case "set-github-token":
            guard arguments.count > 1 else {
                print("Usage: portavoz-cli secrets set-github-token <token>")
                return
            }
            do {
                try SecretStore.set(arguments[1], service: SecretStore.gitHubTokenService)
                print("Token guardado en el Keychain (solo este dispositivo).")
            } catch {
                print("error: \(error.localizedDescription)")
            }
        case "clear-github-token":
            do {
                try SecretStore.delete(service: SecretStore.gitHubTokenService)
                print("Token eliminado del Keychain.")
            } catch {
                print("error: \(error.localizedDescription)")
            }
        default:
            print("Usage: portavoz-cli secrets <set-github-token <token>|clear-github-token>")
        }
    }
}
