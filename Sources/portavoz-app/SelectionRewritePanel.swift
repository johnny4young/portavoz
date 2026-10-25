import AppKit
import PortavozCore
import SwiftUI

/// Same non-activating recipe as the dictation strip: the edited app keeps focus,
/// so the selection and the paste stay where the user left them.
@MainActor
final class SelectionRewritePanelController {
    private var panel: NSPanel?

    /// The controller re-shows on every phase change; AppKit owns the one height.
    func show(controller: SelectionRewriteController) {
        let size = NSSize(width: 520, height: SelectionRewriteView.height(for: controller.phase))
        if let panel {
            resize(panel, to: size)
            panel.orderFrontRegardless()
            return
        }
        let panel = SelectionRewritePanelWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.setAccessibilityIdentifier("rewrite-panel")
        panel.level = UITestWindowPlacement.floatingPanelLevel()
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: SelectionRewriteView(controller: controller).portavozLocalized())
        hosting.sizingOptions = []
        panel.contentView = hosting
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 48))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Grows upward from the bottom edge and stays on screen.
    private func resize(_ panel: NSPanel, to size: NSSize) {
        guard panel.contentRect(forFrameRect: panel.frame).size != size else { return }
        let origin = panel.frame.origin
        panel.setContentSize(size)
        guard let visible = panel.screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: origin.x, y: max(visible.minY, min(origin.y, visible.maxY - panel.frame.height))))
    }
}

private final class SelectionRewritePanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct SelectionRewriteView: View {
    let controller: SelectionRewriteController

    static func height(for phase: SelectionRewriteController.Phase) -> CGFloat {
        switch phase {
        case .preview: 300
        case .choosing, .rewriting, .listening: 190
        default: 96
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: PVSymbol.generate)
                    .foregroundStyle(PVDesign.accent)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("rewrite-state")
                if [.rewriting, .replacing, .capturing].contains(controller.phase) {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button {
                    controller.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(controller.phase == .replacing)
                .accessibilityLabel(L10n.text("Cancel rewrite"))
                .accessibilityIdentifier("rewrite-cancel")
            }
            content
        }
        .padding(12)
        .frame(width: 520, height: Self.height(for: controller.phase), alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .choosing, .rewriting:
            Text(verbatim: controller.original)
                .font(.callout)
                .lineLimit(3)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("rewrite-original")
            if let notice = controller.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("rewrite-notice")
            }
            if let instruction = controller.spokenInstruction {
                Text(verbatim: "“\(instruction)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("rewrite-instruction")
            }
            choices
        case .listening:
            Text(verbatim: controller.original)
                .font(.callout)
                .lineLimit(3)
                .foregroundStyle(.secondary)
            HStack {
                Text("Say how to rewrite it, then press Done or your dictation shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("rewrite-say-how-hint")
                Spacer()
                Button("Done") { controller.finishSayingHow() }
                    .accessibilityIdentifier("rewrite-say-how-done")
            }
        case .preview(let text):
            ScrollView {
                Text(verbatim: text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("rewrite-preview")
            }
            .frame(maxHeight: 170)
            HStack {
                Button("Choose another") { controller.chooseAgain() }
                    .accessibilityIdentifier("rewrite-choose-again")
                copyButton
                Spacer()
                Button("Replace") { controller.replace() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("rewrite-replace")
            }
            Text("Return replaces the selection. Escape closes without changing it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed:
            if controller.result != nil { copyButton }
        default:
            EmptyView()
        }
    }

    private var choices: some View {
        HStack {
            Button("Polish") { controller.choose(nil) }
                .accessibilityIdentifier("rewrite-choice-polish")
            Menu {
                ForEach(controller.recipes) { recipe in
                    Button(DictationTextModePicker.name(of: recipe)) { controller.choose(recipe) }
                        .accessibilityIdentifier("rewrite-choice-\(recipe.id)")
                }
            } label: {
                Text("Recipe")
            }
            .fixedSize()
            .accessibilityIdentifier("rewrite-recipes")
            Button {
                controller.sayHow()
            } label: {
                Label("Say how", systemImage: PVSymbol.dictation)
            }
            .help(Text("Or hold your dictation shortcut and say how to rewrite it."))
            .accessibilityIdentifier("rewrite-say-how")
            Spacer()
        }
        .disabled(controller.phase == .rewriting)
    }

    private var copyButton: some View {
        Button(controller.copied ? L10n.text("Copied") : L10n.text("Copy")) { controller.copyResult() }
            .accessibilityIdentifier("rewrite-copy")
    }

    private var title: String {
        switch controller.phase {
        case .idle: ""
        case .capturing: L10n.text("Reading the selection…")
        case .choosing:
            controller.applicationName.map { L10n.format("Rewrite your selection in %@", $0) }
                ?? L10n.text("Rewrite your selection")
        case .listening: L10n.text("Listening…")
        case .rewriting: L10n.text("Rewriting…")
        case .preview: L10n.text("Preview")
        case .replacing: L10n.text("Replacing…")
        case .replaced:
            controller.applicationName.map { L10n.format("Replaced in %@.", $0) } ?? L10n.text("Replaced.")
        case .failed(let message): message
        }
    }
}
