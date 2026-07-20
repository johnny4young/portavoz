import AppKit
import ApplicationKit
import PortavozCore
import SwiftUI

/// The ⌘K ask-your-week palette: AppKit owns only panel, navigation, and
/// clipboard concerns. Query/answer state belongs to CommandPaletteModel and
/// all business coordination enters through the shared Ask application flow.
@MainActor
final class CommandPaletteController {
    let model: CommandPaletteModel
    private let panel = CommandPalettePanelController()

    /// Registered by ContentView (the only place with `openWindow`); lets a
    /// citation reopen the library window when it was closed.
    var openMainWindow: (() -> Void)?
    /// Composition-owned navigation request. The controller never reaches a
    /// Store or mutates SwiftUI route state directly.
    var onOpenCitation: ((AskCitation) -> Void)?

    init(model: CommandPaletteModel) {
        self.model = model
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        model.reset()
        panel.show(controller: self, model: model)
    }

    func hide() {
        panel.close()
        model.reset()
    }

    /// A citation: open the meeting and seek the player to that moment.
    func navigate(to citation: AskCitation) {
        hide()
        onOpenCitation?(citation)
        openMainWindow?()
    }

    func navigate(to hit: AskSearchResult) {
        navigate(to: AskCitation(
            segmentID: hit.segmentID,
            meetingID: hit.meetingID,
            meetingTitle: hit.meetingTitle,
            timestamp: hit.timestamp,
            text: hit.snippet))
    }

    func copyAnswer() {
        guard let markdown = model.markdownAnswer() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }
}

/// Spotlight-style floating panel: 620 pt, radius 16, material, and key so its
/// text field remains a real keyboard destination. Closing it also
/// discards/cancels state.
@MainActor
private final class CommandPalettePanelController {
    private var panel: PalettePanel?

    var isVisible: Bool { panel != nil }

    func show(
        controller: CommandPaletteController,
        model: CommandPaletteModel
    ) {
        guard panel == nil else { return }
        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 76),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.identifier = NSUserInterfaceItemIdentifier("command-palette-window")
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.onResignKey = { [weak controller] in controller?.hide() }
        panel.contentView = NSHostingView(
            rootView: CommandPaletteView(
                controller: controller,
                model: model)
                .portavozLocalized()
                .tint(PVDesign.accent))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - 310,
                y: frame.minY + frame.height * 0.62))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.onResignKey = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class PalettePanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

private struct CommandPaletteView: View {
    let controller: CommandPaletteController
    let model: CommandPaletteModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            if model.state.isAnswering {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching your meetings…").foregroundStyle(.secondary)
                }
                .padding(12)
                .accessibilityIdentifier("palette-progress")
            } else if let answer = model.state.answer {
                Divider()
                answerView(answer)
            } else if !model.state.hits.isEmpty {
                Divider()
                hitsList
            }
        }
        .frame(width: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onExitCommand { controller.hide() }
        .onAppear { focused = true }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(PVDesign.accent)
            TextField("Ask your week…", text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onChange(of: text) { _, value in
                    model.updateQuery(value)
                }
                .onSubmit { model.submit() }
                .accessibilityIdentifier("palette-query-field")
            if model.state.answer != nil {
                Button {
                    controller.copyAnswer()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("c", modifiers: .command)
                .help(L10n.text("Copy answer with citations (Markdown)"))
                .accessibilityIdentifier("palette-copy-answer")
            }
        }
        .padding(14)
    }

    private var hitsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.state.hits.enumerated()), id: \.element.segmentID) { index, hit in
                Button {
                    controller.navigate(to: hit)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hit.snippet).lineLimit(1)
                        Text("\(hit.meetingTitle) · \(AskMarkdown.clock(hit.timestamp))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .accessibilityIdentifier("palette-hit-\(index)")
            }
            Text("Press Enter for a full answer with receipts.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        .padding(.vertical, 4)
    }

    private func answerView(_ answer: CommandPaletteModel.PaletteAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(answer.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("palette-answer")
            if !answer.citations.isEmpty {
                FlowCitations(citations: answer.citations) { citation in
                    controller.navigate(to: citation)
                }
            }
        }
        .padding(14)
    }
}

/// Citation chips: `↗ {title} · {mm:ss}` — the capsule language of the DS.
private struct FlowCitations: View {
    let citations: [AskCitation]
    let onTap: (AskCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(citations.enumerated()), id: \.offset) { index, citation in
                Button {
                    onTap(citation)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                        Text("\(citation.meetingTitle) · \(AskMarkdown.clock(citation.timestamp))")
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(PVDesign.accent.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(citation.text)
                .accessibilityIdentifier("palette-citation-\(index)")
            }
        }
    }
}
