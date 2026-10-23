import Foundation
import PortavozCLIKit

/// One executable serves the app and, when started through the bundled
/// `portavoz-cli` link, the command-line tool and its MCP server, so the tool
/// ships without a second copy of every framework.
@main
@MainActor
enum PortavozLauncher {
    static func main() {
        guard CommandLineInvocation.runsCommandLineTool(CommandLine.arguments) else {
            PortavozApp.main()
            return
        }
        Task {
            await PortavozCLI.main()
            exit(0)
        }
        dispatchMain()
    }
}

enum CommandLineInvocation {
    static let toolName = "portavoz-cli"

    /// The name the process was started by, not the resolved executable.
    static func runsCommandLineTool(_ arguments: [String]) -> Bool {
        guard let first = arguments.first, !first.isEmpty else { return false }
        return URL(fileURLWithPath: first).lastPathComponent == toolName
    }
}
