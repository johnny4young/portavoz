import ApplicationKit
import Foundation
import PortavozCore

/// `portavoz-cli issues --meeting <uuid> (--github <owner/repo> | --linear-team <id>)
///                      [--db <path>]`
///
/// Publishes the PENDING action items of the meeting's latest summary as
/// tracker issues. Explicit off-device action (D8). Tokens come from the
/// Keychain (`secrets set-github-token` / `set-linear-token`) or the
/// PORTAVOZ_GITHUB_TOKEN / PORTAVOZ_LINEAR_TOKEN environment variables.
enum IssuesCommand {
    private struct Options {
        var meetingRaw: String?
        var githubRepo: String?
        var linearTeam: String?
        var dbPath: String?

        static func parse(_ arguments: [String]) -> Self? {
            var options = Self()
            var index = 0
            while index < arguments.count {
                let option = arguments[index]
                guard options.accepts(option) else {
                    print("Unknown option: \(option)")
                    return nil
                }
                let value = arguments.indices.contains(index + 1)
                    ? arguments[index + 1]
                    : nil
                options.set(value, for: option)
                index += 2
            }
            return options
        }

        var meetingID: MeetingID? {
            meetingRaw
                .flatMap(UUID.init(uuidString:))
                .map(MeetingID.init(rawValue:))
        }

        var destination: CLIIssueDestination? {
            if let githubRepo {
                return .github(repository: githubRepo)
            }
            if let linearTeam {
                return .linear(teamID: linearTeam)
            }
            return nil
        }

        private func accepts(_ option: String) -> Bool {
            switch option {
            case "--meeting", "--github", "--linear-team", "--db":
                true
            default:
                false
            }
        }

        private mutating func set(_ value: String?, for option: String) {
            switch option {
            case "--meeting":
                meetingRaw = value
            case "--github":
                githubRepo = value
            case "--linear-team":
                linearTeam = value
            case "--db":
                dbPath = value
            default:
                break
            }
        }
    }

    static func run(
        _ arguments: [String],
        platform: CLIPlatformDependencies
    ) async {
        guard let options = Options.parse(arguments) else { return }
        guard let meetingID = options.meetingID,
              let destination = options.destination
        else {
            print("Usage: portavoz-cli issues --meeting <uuid> (--github <owner/repo> | --linear-team <id>)")
            return
        }

        do {
            let application = try CLIComposition.open(
                dbPath: options.dbPath,
                platform: platform)
            let workflow = application.publishMeetingActionItems(
                destination: destination)
            let result = try await workflow.execute(.init(meetingID: meetingID) { progress in
                if case .publishing(let count) = progress {
                    print("⚠️ Publishing \(count) action item(s) OUTSIDE the device.")
                }
            })
            present(result)
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }

    private static func present(_ result: PublishMeetingActionItemsResult) {
        switch result {
        case .noPendingItems:
            print("There are no pending action items in the latest summary.")
        case .published(let items):
            for item in items {
                print("  ✓ \(item.text) → \(item.url.absoluteString)")
            }
        }
    }
}
