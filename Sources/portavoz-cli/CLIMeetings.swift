import Foundation
import PortavozCore
import StorageKit

/// `portavoz-cli meetings <list|show <id>|search <query>> [--db <path>]`
/// Browses the local library (SQLite + FTS5).
enum MeetingsCommand {
    // CLI de desarrollo: el parser de flags es un switch inherentemente largo.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func run(_ arguments: [String]) async {
        var arguments = arguments
        guard let action = arguments.first else {
            printUsage()
            return
        }
        arguments.removeFirst()

        var positional: [String] = []
        var dbPath: String?
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--db", index + 1 < arguments.count {
                dbPath = arguments[index + 1]
                index += 1
            } else {
                positional.append(arguments[index])
            }
            index += 1
        }

        if action == "refine" {
            guard let raw = positional.first else {
                print("Usage: portavoz-cli meetings refine <meeting-uuid> [--file <wav>] [--threshold 0.45]")
                return
            }
            await RefineCommand.run(meetingRaw: raw, Array(arguments.dropFirst()))
            return
        }

        do {
            let store = try openStore(dbPath: dbPath)
            switch action {
            case "list":
                let meetings = try await store.meetings()
                if meetings.isEmpty {
                    print("No meetings yet. Save one with: portavoz-cli summarize --file x.wav --save")
                    return
                }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                for meeting in meetings {
                    let language = meeting.language.map { " · \($0)" } ?? ""
                    print("\(meeting.id.rawValue.uuidString)  \(formatter.string(from: meeting.startedAt))\(language)  \(meeting.title)")
                }

            case "show":
                guard let raw = positional.first, let uuid = UUID(uuidString: raw) else {
                    print("Usage: portavoz-cli meetings show <meeting-uuid> [--db <path>]")
                    return
                }
                guard let detail = try await store.detail(MeetingID(rawValue: uuid)) else {
                    print("No such meeting.")
                    return
                }
                print("\(detail.meeting.title)")
                print("speakers: \(detail.speakers.map(\.label).joined(separator: ", "))")
                let labelsByID = Dictionary(
                    uniqueKeysWithValues: detail.speakers.map { ($0.id, $0.label) })
                print("")
                for segment in detail.segments {
                    let label = segment.speakerID.flatMap { labelsByID[$0] } ?? "?"
                    print("[\(CLISupport.timestamp(segment.startTime))] \(label): \(segment.text)")
                }
                if let (summary, version) = try await store.summary(detail.meeting.id) {
                    print("\n— summary v\(version) (\(summary.language)) —\n")
                    print(summary.markdown)
                }

            case "search":
                guard !positional.isEmpty else {
                    print("Usage: portavoz-cli meetings search <query> [--db <path>]")
                    return
                }
                let hits = try await store.search(positional.joined(separator: " "))
                if hits.isEmpty {
                    print("No matches.")
                    return
                }
                for hit in hits {
                    print("[\(CLISupport.timestamp(hit.startTime))] \(hit.meetingTitle): \(hit.snippet)")
                    print("    meeting \(hit.meetingID.rawValue.uuidString)")
                }

            default:
                printUsage()
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }

    static func openStore(dbPath: String?) throws -> MeetingStore {
        if let dbPath {
            return try MeetingStore(databaseURL: URL(fileURLWithPath: dbPath))
        }
        return try MeetingStore(databaseURL: MeetingStore.defaultDatabaseURL)
    }

    static func printUsage() {
        print(
            """
            Usage:
              portavoz-cli meetings list [--db <path>]
              portavoz-cli meetings show <meeting-uuid> [--db <path>]
              portavoz-cli meetings search <query> [--db <path>]
            """
        )
    }
}
