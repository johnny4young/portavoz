import AppKit
import SwiftUI
import TranscriptionKit

/// The floating dictation strip: same non-activating panel recipe as the
/// recording HUD — always on top, never steals focus, so the keystrokes
/// keep landing in the app the user is dictating INTO.
@MainActor
final class DictationPanelController {
    private var panel: NSPanel?

    func show(controller: DictationController) {
        guard panel == nil else { return }
        let panel = DictationPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(
            rootView: DictationStripView(controller: controller).portavozLocalized())
        // Bottom-center of the main screen, above the Dock — near where
        // the eye already is while typing.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 260, y: frame.minY + 48))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class DictationPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct DictationStripView: View {
    let controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.mic")
                    .foregroundStyle(isFailed ? Color.orange : Color.indigo)
                    .symbolEffect(.pulse, isActive: controller.phase == .listening)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    controller.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Cancel dictation"))
            }
            Text(transcript.isEmpty ? L10n.text("Listening…") : transcript)
                .font(.body)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
        }
        .padding(12)
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var isFailed: Bool {
        if case .failed = controller.phase { return true }
        return false
    }

    private var title: String {
        switch controller.phase {
        case .listening:
            return L10n.text("Dictating — ⌥⌘D inserts into the front app")
        case .failed(let message):
            return message
        case .idle:
            return ""
        }
    }

    private var transcript: String {
        DictationAssembler.text(
            confirmed: controller.confirmedText, partial: controller.partialText)
    }
}
