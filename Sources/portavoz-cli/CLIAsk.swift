import ApplicationKit
import Foundation

/// `portavoz-cli ask "what did we agree about the budget?" [--db <path>]`
///
/// Local RAG (M8): the same AskMeetings workflow used by the macOS surfaces
/// retrieves hybrid evidence and optionally answers on device.
enum AskCommand {
    static func run(
        _ arguments: [String],
        platform: CLIPlatformDependencies
    ) async {
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
            let application = try CLIComposition.open(
                dbPath: dbPath,
                platform: platform)
            let result = try await application.ask.answer(
                question,
                limit: limit)
            guard !result.citations.isEmpty else {
                print("No encuentro nada relacionado en tus reuniones.")
                return
            }

            if let answer = result.generatedText {
                print(answer)
            } else {
                print("(Apple Intelligence unavailable — this is the most relevant context I found:)")
            }
            print("\nfuentes:")
            for (index, citation) in result.citations.enumerated() {
                print("  [\(index + 1)] \(citation.meetingTitle) · \(CLISupport.timestamp(citation.timestamp)) · \(citation.text.prefix(90))")
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}
