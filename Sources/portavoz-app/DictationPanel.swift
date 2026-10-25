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
        let size = DictationPanelLayout.size(for: controller)
        if let panel {
            resize(panel, to: size)
            // A new dictation reuses a notice's panel; it still opens at its own caret.
            if controller.phase == .preparing { place(panel, size: size, near: controller.panelAnchor) }
            panel.orderFrontRegardless()
            return
        }
        let panel = DictationPanelWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.setAccessibilityIdentifier("dictation-panel")
        panel.level = UITestWindowPlacement.floatingPanelLevel()
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(
            rootView: DictationStripView(controller: controller) { [weak self] in
                self?.relayout(for: controller)
            }.portavozLocalized())
        place(panel, size: size, near: controller.panelAnchor)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Beside the caret (or pointer) when known; otherwise bottom-center above the Dock.
    private func place(_ panel: NSPanel, size: NSSize, near anchor: DictationPanelAnchor?) {
        if let anchor,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.point) }) ?? NSScreen.main {
            panel.setFrameOrigin(DictationPanelAnchor.origin(for: size, near: anchor, in: screen.visibleFrame))
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 48))
        }
    }

    /// Follows a layout change without ever reopening a closed panel.
    private func relayout(for controller: DictationController) {
        guard let panel else { return }
        resize(panel, to: DictationPanelLayout.size(for: controller))
    }

    private func resize(_ panel: NSPanel, to size: NSSize) {
        guard panel.contentRect(forFrameRect: panel.frame).size != size else { return }
        let origin = panel.frame.origin
        // Keep the horizontal center when the compact indicator grows into the full panel.
        let midX = panel.frame.midX
        panel.setContentSize(size)
        guard let visible = panel.screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: max(visible.minX, min(midX - panel.frame.width / 2, visible.maxX - panel.frame.width)),
            y: max(visible.minY, min(origin.y, visible.maxY - panel.frame.height))))
    }
}

/// One height authority for AppKit and SwiftUI: a conflicting intrinsic size
/// otherwise moves the panel again after every explicit re-show.
private enum DictationPanelLayout {
    @MainActor
    static func size(for controller: DictationController) -> NSSize {
        DictationCompactIndicator.applies(to: controller)
            ? DictationCompactIndicator.size
            : NSSize(width: 520, height: height(for: controller.phase) + (controller.isPolishing ? 28 : 0))
    }

    static func height(for phase: DictationController.Phase) -> CGFloat {
        switch phase {
        case .recovery, .dispatched, .noSpeech: 288
        default: 96
        }
    }
}

private final class DictationPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct DictationStripView: View {
    let controller: DictationController
    /// Lets the panel follow phases that change without an explicit re-show, such as a failure.
    let relayout: () -> Void

    var body: some View {
        Group {
            if DictationCompactIndicator.applies(to: controller) {
                DictationCompactStripView(controller: controller)
            } else {
                fullStrip
            }
        }
        .onChange(of: DictationPanelLayout.size(for: controller)) { relayout() }
    }

    private var fullStrip: some View {
        Group {
            if case .recovery(let failure) = controller.phase {
                DictationRecoveryView(controller: controller, failure: failure)
            } else if case .verified(let words) = controller.phase {
                verifiedDeliveryView(words)
            } else if controller.phase == .noSpeech {
                DictationNoSpeechView(controller: controller)
            } else if case .dispatched = controller.phase {
                DictationUnverifiedDeliveryView(controller: controller)
            } else {
                dictatingView
            }
        }
        .padding(12)
        .frame(width: 520, height: DictationPanelLayout.size(for: controller).height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The active strip: what you're saying, and — the 4b signature — WHERE
    /// it will land, so you never dictate blind.
    private var dictatingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if showsModelLoading {
                    // Audio is kept (D561), but no words can appear yet.
                    Image(systemName: "hourglass")
                        .foregroundStyle(.orange)
                        .symbolEffect(.pulse)
                        .accessibilityLabel(L10n.text("Loading the speech model"))
                        .accessibilityIdentifier("dictation-panel-loading")
                } else {
                    Image(systemName: "waveform.badge.mic")
                        .foregroundStyle(isFailed ? Color.orange : PVDesign.accent)
                        .symbolEffect(.pulse, isActive: controller.phase == .listening)
                }
                Text(title)
                    .accessibilityIdentifier("dictation-panel-state")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let target = controller.targetApp, controller.isActive {
                    targetChip(target)
                }
                if controller.isActive, controller.phase != .delivering {
                    DictationTextModePicker(
                        identifier: "dictation-panel-text-mode", label: Text("Text mode"), selection: Binding(
                        get: { controller.textMode }, set: { controller.selectTextMode($0) }))
                        .labelsHidden()
                        .controlSize(.mini)
                        .frame(width: 80)
                        .disabled(!controller.canChangeTextMode)
                }
                Spacer()
                if controller.phase == .listening {
                    DictationWaveform(level: controller.micLevel, isActive: true, dimmed: showsModelLoading)
                        .frame(width: 70, height: 18)
                        .accessibilityIdentifier("dictation-panel-meter")
                }
                Button {
                    controller.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                // A posted paste cannot be recalled; cancelling would only hide its outcome.
                .disabled(controller.phase == .delivering)
                .accessibilityLabel(L10n.text("Cancel dictation"))
                .accessibilityIdentifier("dictation-panel-cancel")
            }
            if let notice = controller.microphoneNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dictation-panel-microphone-notice")
            }
            if controller.isPolishing {
                HStack {
                    Text("Your words are being polished. Esc pastes them without polish.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("dictation-panel-polish-hint")
                    Spacer()
                    Button("Paste without polish") { controller.skipPolish() }
                        .controlSize(.small)
                        .accessibilityIdentifier("dictation-panel-skip-polish")
                }
            }
            if isFailed {
                EmptyView()
            } else if controller.confirmedText.isEmpty && controller.partialText.isEmpty {
                Text(emptyCaptionHint)
                    .accessibilityIdentifier("dictation-panel-hint")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Confirmed words are settled; the tail is still volatile, so
                // it reads gray — it firms up as the engine commits it.
                let visible = DictationPanelTranscript.visible(
                    confirmed: controller.confirmedText, partial: controller.partialText)
                let confirmed = Text(visible.confirmed).foregroundStyle(.primary)
                let partial = Text(visible.partial).foregroundStyle(.tertiary)
                Text("\(confirmed)\(partial)")
                    .accessibilityIdentifier("dictation-panel-transcript")
                    // The strip elides earlier words visually; VoiceOver keeps the whole dictation.
                    .accessibilityLabel(DictationAssembler.text(
                        confirmed: controller.confirmedText, partial: controller.partialText))
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The brief confirmation after insertion: N words → the target app,
    /// and whether the dictation history kept it.
    private func verifiedDeliveryView(_ words: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: PVSymbol.success)
                .foregroundStyle(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(insertedTitle(words))
                    .accessibilityIdentifier("dictation-panel-delivery-status")
                    .font(.callout.weight(.medium))
                Text(controller.deliveryPrivacyLine)
                    .accessibilityIdentifier("dictation-panel-delivery-detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let notice = controller.polishNotice {
                    Text(notice)
                        .accessibilityIdentifier("dictation-panel-polish-notice")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
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
            Text(app)
                .font(.caption2.weight(.semibold))
                .accessibilityIdentifier("dictation-panel-target")
        }
        .foregroundStyle(PVDesign.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(PVDesign.accent.opacity(0.14), in: Capsule())
    }

    private var showsModelLoading: Bool { controller.phase == .listening && controller.isLoadingModel }

    private var isFailed: Bool {
        if case .failed = controller.phase { return true }
        return false
    }

    private var emptyCaptionHint: String {
        if controller.phase == .preparing { return L10n.text("Preparing microphone…") }
        return showsModelLoading
            ? L10n.text("Keep talking. Your words appear once the model is ready.")
            : L10n.text("Listening…")
    }

    private var title: String {
        switch controller.phase {
        case .preparing:
            return L10n.text("Preparing dictation…")
        case .listening:
            return showsModelLoading ? L10n.text("Loading speech model…") : L10n.text("Dictating")
        case .delivering:
            return controller.isPolishing ? L10n.text("Polishing…") : L10n.text("Inserting…")
        case .failed(let message):
            return message
        case .idle, .verified, .dispatched, .noSpeech, .recovery:
            return ""
        }
    }
}
