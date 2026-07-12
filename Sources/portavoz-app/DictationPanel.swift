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
        Group {
            if case .inserted(let words) = controller.phase {
                insertedView(words)
            } else {
                dictatingView
            }
        }
        .padding(12)
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The active strip: what you're saying, and — the 4b signature — WHERE
    /// it will land, so you never dictate blind.
    private var dictatingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.mic")
                    .foregroundStyle(isFailed ? Color.orange : PVDesign.accent)
                    .symbolEffect(.pulse, isActive: controller.phase == .listening)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let target = controller.targetApp, controller.phase == .listening {
                    targetChip(target)
                }
                Spacer()
                if controller.phase == .listening {
                    meter
                }
                Button {
                    controller.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Cancel dictation"))
            }
            if controller.confirmedText.isEmpty && controller.partialText.isEmpty {
                Text("Listening…")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Confirmed words are settled; the tail is still volatile, so
                // it reads gray — it firms up as the engine commits it.
                (Text(controller.confirmedText)
                    .foregroundStyle(.primary)
                    + Text(controller.partialText.isEmpty ? "" : " ")
                    + Text(controller.partialText)
                    .foregroundStyle(.tertiary))
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The brief confirmation after insertion: N words → the target app,
    /// and the honest reassurance that nothing was stored.
    private func insertedView(_ words: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(insertedTitle(words))
                    .font(.callout.weight(.medium))
                Text("Nothing was saved in Portavoz — dictation never leaves a trace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func insertedTitle(_ words: Int) -> String {
        if let target = controller.targetApp {
            return L10n.format("%d words inserted into %@.", words, target)
        }
        return L10n.format("%d words inserted.", words)
    }

    /// The destination chip: `✎ Notes` — the app the words will land in.
    private func targetChip(_ app: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "pencil").font(.caption2)
            Text(app).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(PVDesign.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(PVDesign.accent.opacity(0.14), in: Capsule())
    }

    /// Same dB mapping as the recording HUD's meter: −60 dB → 0, 0 dB → 1.
    private var meter: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            GeometryReader { geometry in
                Capsule()
                    .fill(PVDesign.accent)
                    .frame(width: geometry.size.width * meterFraction)
            }
        }
        .frame(width: 70, height: 4)
    }

    private var meterFraction: CGFloat {
        let level = controller.micLevel
        guard level > 0.0001 else { return 0 }
        let decibels = 20 * log10(level)
        return CGFloat(max(0, min(1, (Double(decibels) + 60) / 60)))
    }

    private var isFailed: Bool {
        if case .failed = controller.phase { return true }
        return false
    }

    private var title: String {
        switch controller.phase {
        case .listening:
            return L10n.text("Dictating")
        case .failed(let message):
            return message
        case .idle, .inserted:
            return ""
        }
    }
}
