import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit

/// `portavoz-cli issues --meeting <uuid> (--github <owner/repo> | --linear-team <id>)
///                      [--db <path>]`
///
/// Publishes the PENDING action items of the meeting's latest summary as
/// tracker issues. Explicit off-device action (D8). Tokens come from the
/// Keychain (`secrets set-github-token` / `set-linear-token`) or the
/// PORTAVOZ_GITHUB_TOKEN / PORTAVOZ_LINEAR_TOKEN environment variables.
enum IssuesCommand {
    // CLI de desarrollo: el parser de flags es un switch inherentemente largo.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func run(_ arguments: [String]) async {
        var meetingRaw: String?
        var githubRepo: String?
        var linearTeam: String?
        var dbPath: String?

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--meeting":
                index += 1
                if index < arguments.count { meetingRaw = arguments[index] }
            case "--github":
                index += 1
                if index < arguments.count { githubRepo = arguments[index] }
            case "--linear-team":
                index += 1
                if index < arguments.count { linearTeam = arguments[index] }
            case "--db":
                index += 1
                if index < arguments.count { dbPath = arguments[index] }
            default:
                print("Unknown option: \(arguments[index])")
                return
            }
            index += 1
        }

        guard let meetingRaw, let uuid = UUID(uuidString: meetingRaw),
            githubRepo != nil || linearTeam != nil
        else {
            print("Usage: portavoz-cli issues --meeting <uuid> (--github <owner/repo> | --linear-team <id>)")
            return
        }

        do {
            let store = try MeetingsCommand.openStore(dbPath: dbPath)
            let meetingID = MeetingID(rawValue: uuid)
            guard let detail = try await store.detail(meetingID),
                let (summary, _) = try await store.summary(meetingID)
            else {
                print("error: the meeting does not exist or has no summary")
                return
            }
            let pending = summary.actionItems.filter { !$0.isDone }
            guard !pending.isEmpty else {
                print("There are no pending action items in the latest summary.")
                return
            }
            let namesByID = Dictionary(
                uniqueKeysWithValues: detail.speakers.map {
                    ($0.id, $0.displayName ?? $0.label)
                })

            print("⚠️ Publishing \(pending.count) action item(s) OUTSIDE the device.")
            for item in pending {
                let owner = item.ownerSpeakerID.flatMap { namesByID[$0] }
                let url: URL
                if let githubRepo {
                    guard
                        let token = (try? SecretStore.get(service: SecretStore.gitHubTokenService))
                            ?? ProcessInfo.processInfo.environment["PORTAVOZ_GITHUB_TOKEN"]
                    else {
                        print("error: sin token de GitHub — `portavoz-cli secrets set-github-token <t>`")
                        return
                    }
                    url = try await GitHubIssuesExporter(
                        repository: githubRepo,
                        token: token,
                        gateway: URLSessionDataEgressGateway(receiptRecorder: store)
                    ).publish(
                        item,
                        meetingID: meetingID,
                        meetingTitle: detail.meeting.title,
                        ownerName: owner)
                } else {
                    guard
                        let token = (try? SecretStore.get(service: SecretStore.linearTokenService))
                            ?? ProcessInfo.processInfo.environment["PORTAVOZ_LINEAR_TOKEN"]
                    else {
                        print("error: sin token de Linear — `portavoz-cli secrets set-linear-token <t>`")
                        return
                    }
                    url = try await LinearExporter(
                        teamID: linearTeam!,
                        token: token,
                        gateway: URLSessionDataEgressGateway(receiptRecorder: store)
                    ).publish(
                        item,
                        meetingID: meetingID,
                        meetingTitle: detail.meeting.title,
                        ownerName: owner)
                }
                print("  ✓ \(item.text) → \(url.absoluteString)")
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}
