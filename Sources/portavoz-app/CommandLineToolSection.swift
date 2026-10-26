import SwiftUI

/// Settings › Integrations: put the bundled `portavoz-cli` on the shell path
/// and copy what Claude Code or another MCP client needs to reach this Mac.
struct CommandLineToolSection: View {
    @State private var model = CommandLineToolModel.forCurrentLaunch()
    @State private var confirmingInstall = false
    @State private var copied: String?

    var body: some View {
        // Modifiers on a Form section reach every row, so each row carries its own.
        Section("Command-line tool & MCP") {
            Text(L10n.text(Self.explanationKey))
                .font(.caption)
                .foregroundStyle(.secondary)
                .onAppear { model.refresh() }
            if model.toolAvailable {
                installRow
                commandRows
            } else {
                Label("This build doesn't include the command-line tool.", systemImage: PVSymbol.warning)
                    .accessibilityIdentifier("settings-cli-unavailable")
            }
            if let failure = model.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings-cli-error")
            }
        }
    }

    @ViewBuilder private var installRow: some View {
        HStack {
            Text(statusText)
                .accessibilityIdentifier("settings-cli-status")
            Spacer()
            switch model.state {
            case .installed:
                Button("Remove", role: .destructive) { model.remove() }
                    .accessibilityIdentifier("settings-cli-remove")
            case .notInstalled, .linkedElsewhere:
                Button(model.state == .notInstalled ? "Install…" : "Replace link…") { confirmingInstall = true }
                    .accessibilityIdentifier("settings-cli-install")
                    .confirmationDialog(
                        "Install the command-line tool?", isPresented: $confirmingInstall, titleVisibility: .visible
                    ) {
                        Button("Install") { model.install() }
                            .accessibilityIdentifier("settings-cli-install-confirm")
                    } message: {
                        Text(L10n.text(Self.confirmationKey))
                    }
            case .blocked:
                EmptyView()
            }
        }
        if model.state == .installed {
            copyRow(
                L10n.text("If your terminal can't find portavoz-cli, add ~/.local/bin to your PATH."),
                value: CommandLineToolModel.pathExport, identifier: "settings-cli-copy-path")
        }
    }

    @ViewBuilder private var commandRows: some View {
        copyRow(
            L10n.text("Connect Claude Code"), value: model.claudeCommand, identifier: "settings-cli-copy-claude")
        copyRow(
            L10n.text("Other MCP clients (JSON)"), value: model.mcpConfiguration, identifier: "settings-cli-copy-json")
    }

    private func copyRow(_ title: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Button(copied == identifier ? L10n.text("Copied") : L10n.text("Copy")) {
                    if TextInserter.copy(value) { copied = identifier }
                }
                .accessibilityIdentifier(identifier)
            }
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(6)
        }
    }

    private static let explanationKey = "Local AI tools such as Claude Code can read your meetings "
        + "through Portavoz's MCP server. It runs only on this Mac."
    private static let confirmationKey = "Portavoz will create a link at ~/.local/bin/portavoz-cli "
        + "to the tool inside this app. Your shell settings aren't changed."

    private var statusText: String {
        switch model.state {
        case .installed: L10n.text("Installed at ~/.local/bin/portavoz-cli.")
        case .notInstalled: L10n.text("Not on your shell path yet.")
        case .linkedElsewhere: L10n.text("~/.local/bin/portavoz-cli points to another copy.")
        case .blocked: L10n.text("A file Portavoz didn't create is already at ~/.local/bin/portavoz-cli.")
        }
    }
}
