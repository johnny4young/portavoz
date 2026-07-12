import AppKit
import IntegrationsKit
import IntelligenceKit
import PortavozCore
import StorageKit
import SwiftUI

/// The ⌘K ask-your-week palette (design system spec 6a-1): a floating
/// command palette over ANY view — instant FTS while typing, a full local
/// RAG answer on Enter, citation chips that jump to the meeting and seek
/// the player. Same engine as AskView (`AskPipeline` + `RAGAnswerer`);
/// this is a new surface, not a new motor. State is discarded on close.
@MainActor
@Observable
final class CommandPaletteController {
    private(set) var query = ""
    private(set) var hits: [SearchHit] = []
    private(set) var answer: PaletteAnswer?
    private(set) var answering = false
    private let panel = CommandPalettePanelController()
    /// Registered by ContentView (the only place with `openWindow`); lets
    /// a citation reopen the library window when it was closed.
    var openMainWindow: (() -> Void)?

    struct PaletteAnswer {
        let question: String
        let text: String
        let passages: [RAGPassage]
    }

    func toggle(services: AppServices) {
        if panel.isVisible {
            hide()
        } else {
            show(services: services)
        }
    }

    func show(services: AppServices) {
        reset()
        panel.show(controller: self, services: services)
    }

    func hide() {
        panel.close()
        reset()
    }

    private func reset() {
        query = ""
        hits = []
        answer = nil
        answering = false
    }

    /// Instant lane: FTS5 titles + snippets while the user types (<25 ms).
    func updateQuery(_ text: String, services: AppServices) {
        query = text
        answer = nil
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            hits = []
            return
        }
        Task { [weak self] in
            let found = (try? await services.store.search(trimmed)) ?? []
            guard let self, self.query == text else { return }  // stale keystroke
            self.hits = Array(found.prefix(6))
        }
    }

    /// Enter: the full RAG answer, in the question's language, with receipts.
    func ask(services: AppServices) {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !answering else { return }
        answering = true
        Task { [weak self] in
            defer { self?.answering = false }
            do {
                let passages = try await AskPipeline.retrieve(
                    question: question, store: services.store)
                guard let self else { return }
                guard !passages.isEmpty else {
                    self.answer = PaletteAnswer(
                        question: question,
                        text: L10n.text("Nothing related in your meetings yet."),
                        passages: [])
                    return
                }
                var text: String?
                if #available(macOS 26.0, *),
                    FoundationModelSummaryProvider.unavailabilityReason() == nil {
                    text = try? await RAGAnswerer().answer(
                        question: question, passages: passages)
                }
                self.answer = PaletteAnswer(
                    question: question,
                    text: text ?? L10n.text("Closest passages from your meetings:"),
                    passages: passages)
            } catch {
                self?.answer = PaletteAnswer(
                    question: question,
                    text: L10n.format("Search failed: %@", error.localizedDescription),
                    passages: [])
            }
        }
    }

    /// A citation: open the meeting and seek the player to that moment.
    func navigate(to meetingID: MeetingID, at seconds: TimeInterval, services: AppServices) {
        hide()
        services.pendingSeek = seconds
        services.pendingRoute = .meeting(meetingID)
        openMainWindow?()
    }

    func copyAnswer() {
        guard let answer else { return }
        let markdown = AskMarkdown.format(
            question: answer.question, answer: answer.text, passages: answer.passages)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }
}

/// Spotlight-style floating panel: 620 pt, radius 16, material, key (it
/// hosts a text field) but non-activating; closes when it loses key —
/// state is discarded with it (spec).
@MainActor
private final class CommandPalettePanelController {
    private var panel: NSPanel?

    var isVisible: Bool { panel != nil }

    func show(controller: CommandPaletteController, services: AppServices) {
        guard panel == nil else { return }
        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.onResignKey = { [weak controller] in controller?.hide() }
        panel.contentView = NSHostingView(
            rootView: CommandPaletteView(controller: controller)
                .portavozLocalized()
                .environment(services)
                .tint(.indigo))
        // Spotlight position: horizontally centered, upper third.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - 310, y: frame.minY + frame.height * 0.62))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
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
    @Environment(AppServices.self) private var services
    let controller: CommandPaletteController
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            if controller.answering {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching your meetings…").foregroundStyle(.secondary)
                }
                .padding(12)
            } else if let answer = controller.answer {
                Divider()
                answerView(answer)
            } else if !controller.hits.isEmpty {
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
                .foregroundStyle(Color.accentColor)
            TextField("Ask your week…", text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onChange(of: text) { _, value in
                    controller.updateQuery(value, services: services)
                }
                .onSubmit { controller.ask(services: services) }
            if controller.answer != nil {
                Button {
                    controller.copyAnswer()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("c", modifiers: .command)
                .help(L10n.text("Copy answer with citations (Markdown)"))
            }
        }
        .padding(14)
    }

    private var hitsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(controller.hits, id: \.segmentID) { hit in
                Button {
                    controller.navigate(
                        to: hit.meetingID, at: hit.startTime, services: services)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hit.snippet).lineLimit(1)
                        Text("\(hit.meetingTitle) · \(AskMarkdown.clock(hit.startTime))")
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
            }
            Text("Press Enter for a full answer with receipts.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        .padding(.vertical, 4)
    }

    private func answerView(_ answer: CommandPaletteController.PaletteAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(answer.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !answer.passages.isEmpty {
                FlowCitations(passages: answer.passages) { passage in
                    controller.navigate(
                        to: passage.meetingID, at: passage.timestamp, services: services)
                }
            }
        }
        .padding(14)
    }
}

/// Citation chips: `↗ {title} · {mm:ss}` — the capsule language of the DS.
private struct FlowCitations: View {
    let passages: [RAGPassage]
    let onTap: (RAGPassage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(passages.enumerated()), id: \.offset) { _, passage in
                Button {
                    onTap(passage)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                        Text("\(passage.meetingTitle) · \(AskMarkdown.clock(passage.timestamp))")
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(passage.text)
            }
        }
    }
}
