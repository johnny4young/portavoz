import Foundation
import IntegrationsKit
import IntelligenceKit
import PortavozCore
import StorageKit

/// `portavoz-cli ask "what did we agree about the budget?" [--db <path>]`
///
/// Local RAG (M8): embeds anything new, retrieves hybrid (FTS + cosine),
/// and answers on-device citing meeting + timestamp. Nothing leaves the
/// machine.
enum AskCommand {
    static func run(_ arguments: [String]) async {
        var positional: [String] = []
        var dbPath: String?
        var limit = 6

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--db":
                index += 1
                if index < arguments.count { dbPath = arguments[index] }
            case "--limit":
                index += 1
                if index < arguments.count { limit = Int(arguments[index]) ?? limit }
            default:
                positional.append(arguments[index])
            }
            index += 1
        }

        let question = positional.joined(separator: " ")
        guard !question.isEmpty else {
            print("Usage: portavoz-cli ask \"<pregunta>\" [--db <path>] [--limit n]")
            return
        }

        do {
            let store = try MeetingsCommand.openStore(dbPath: dbPath)
            let passages = try await AskPipeline.retrieve(
                question: question, store: store, limit: limit)
            guard !passages.isEmpty else {
                print("No encuentro nada relacionado en tus reuniones.")
                return
            }

            if #available(macOS 26.0, *),
                FoundationModelSummaryProvider.unavailabilityReason() == nil {
                let answer = try await RAGAnswerer().answer(question: question, passages: passages)
                print(answer)
            } else {
                print("(Apple Intelligence unavailable — this is the most relevant context I found:)")
            }
            print("\nfuentes:")
            for (index, passage) in passages.enumerated() {
                print("  [\(index + 1)] \(passage.meetingTitle) · \(CLISupport.timestamp(passage.timestamp)) · \(passage.text.prefix(90))")
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}
