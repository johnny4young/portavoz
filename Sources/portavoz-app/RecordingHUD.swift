import AppKit
import PortavozCore
import SwiftUI

/// Floating compact HUD for recording (GAPS #4): a small always-on-top,
/// NON-ACTIVATING panel with the timer, the latest caption, the mic meter
/// and Stop — recording stays visible without the full window covering the
/// meeting you're attending. Clicks never steal focus from Zoom/Meet.
@MainActor
final class RecordingHUDController {
    private var panel: NSPanel?

    var isVisible: Bool { panel != nil }

    static let width: CGFloat = 360
    private static let baseHeight: CGFloat = 88
    private static let maxHeight: CGFloat = 220

    func show(content: some View) {
        guard panel == nil else { return }
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.baseHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = UITestWindowPlacement.floatingPanelLevel()
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        // Top-right corner of the main screen, under the menu bar.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: frame.maxX - Self.width - 16, y: frame.maxY - Self.baseHeight - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Resizes the HUD to fit its content, growing toward whichever side has
    /// room: parked in the lower half of the screen it grows UPWARD (bottom
    /// edge fixed); up near the menu bar it grows downward (top edge fixed).
    /// Either way the newest caption stays visible and the panel is clamped
    /// inside the visible frame. Clamped in height so a long caption can't run
    /// off-screen.
    func setContentHeight(_ height: CGFloat) {
        guard let panel else { return }
        let clamped = max(Self.baseHeight, min(Self.maxHeight, height))
        guard abs(clamped - panel.frame.height) > 0.5 else { return }
        var frame = panel.frame
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame
        // AppKit's y grows upward, so a smaller midY means the lower half.
        if frame.midY < visible.midY {
            frame.size.height = clamped  // grow up: bottom (origin.y) stays put
        } else {
            let top = frame.maxY
            frame.size.height = clamped
            frame.origin.y = top - clamped  // grow down: top stays put
        }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        panel.setFrame(frame, display: true, animate: false)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Borderless panels refuse key status by default; the HUD needs it so its
/// buttons land clicks (the `.nonactivatingPanel` mask still keeps the
/// meeting app frontmost).
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The HUD's content: the clock, who is speaking beside a mini strip, Note,
/// Return and Stop, then the latest caption and the mic meter. Auto-expands
/// back to the window as soon as the recording leaves the `.recording`
/// phase, so processing/errors are never hidden in a mini panel.
struct RecordingHUDView: View {
    let controller: RecordingController
    let onExpand: () -> Void
    let onStop: () -> Void
    /// The panel resizes to this content height so a long, unbroken caption
    /// grows the HUD (up to a cap) instead of clipping — see `captionLineCap`.
    var onHeight: (CGFloat) -> Void = { _ in }

    /// How many lines a single ongoing utterance may grow the HUD to before it
    /// stops growing and shows only the newest lines (head truncation). A pause
    /// or a new speaker starts a fresh coalesced line, resetting it to one.
    private let captionLineCap = 6

    @State private var showsNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Color.clear
                        .frame(width: 8, height: 8)
                        .overlay {
                            TimelineView(.periodic(from: controller.startedAt, by: 1)) { context in
                                RecordingLiveDot(
                                    elapsed: Int(context.date.timeIntervalSince(controller.startedAt)), diameter: 8)
                            }
                        }
                    ElapsedClockText(
                        startedAt: controller.startedAt, style: .clock(size: 19), identifier: "recording-hud-clock")
                }
                RecordingHUDSpeaker(controller: controller)
                Spacer(minLength: 0)
                hudButton(
                    systemImage: "pencil", label: L10n.text("Add a note…"), identifier: "recording-hud-note",
                    fill: showsNote ? PVDesign.line2 : PVDesign.line
                ) { showsNote.toggle() }
                hudButton(
                    systemImage: "arrow.up.left.and.arrow.down.right", label: L10n.text("Return to the full window"),
                    identifier: "recording-hud-expand", fill: PVDesign.line, action: onExpand)
                hudButton(
                    systemImage: PVSymbol.stop, label: L10n.text("Stop recording"), identifier: "recording-hud-stop",
                    fill: PVDesign.now, foreground: PVDesign.onNow, action: onStop)
            }
            VStack(alignment: .leading, spacing: 6) {
                if showsNote {
                    RecordingNoteField(controller: controller)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(controller.captions.last?.text ?? "…")
                        .font(.system(size: 12))
                        .foregroundStyle(PVDesign.ink2)
                        // Grow with the current utterance, but keep the NEWEST words
                        // visible: past the cap, truncate the head (what was said
                        // earliest), never the tail (what's being said now).
                        .lineLimit(captionLineCap)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    hudMeter
                }
                if controller.microphoneCaptureFailed {
                    Label(L10n.text("Microphone capture failed. Stop and start a new recording."),
                          systemImage: "mic.slash.fill")
                        .foregroundStyle(PVDesign.caution)
                        .accessibilityIdentifier("recording-hud-microphone-capture-failure")
                }
                if case .asking(let secondsUntilStop) = controller.callEnd {
                    Label(
                        L10n.format(
                            "Call ended? Stopping in %@",
                            Duration.seconds(secondsUntilStop).formatted(.time(pattern: .minuteSecond))),
                        systemImage: PVSymbol.warning)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PVDesign.caution)
                        .accessibilityIdentifier("recording-hud-call-ended")
                }
                if controller.systemCaptureHealth != .healthy {
                    Label {
                        Text(hudCaptureHealthMessage)
                    } icon: {
                        Image(systemName: hudCaptureHealthIcon)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(hudCaptureHealthColor)
                    .accessibilityIdentifier("recording-hud-system-capture-health")
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 4)
            .overlay(alignment: .top) {
                Rectangle().fill(PVDesign.line).frame(height: 1).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: RecordingHUDController.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-hud-panel")
        .background(
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size.height) { _, height in onHeight(height) }
                    .onAppear { onHeight(geo.size.height) }
            }
        )
        .onChange(of: controller.phase) { _, phase in
            if phase != .recording { onExpand() }
        }
        // A saved note closes the field.
        .onChange(of: controller.contextItems.count) { showsNote = false }
    }

    private func hudButton(
        systemImage: String, label: String, identifier: String, fill: Color,
        foreground: Color = PVDesign.ink, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 28, height: 28)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var hudMeter: some View {
        Capsule()
            .fill(PVDesign.line)
            .frame(width: 44, height: 4)
            .overlay { RecordingHUDMeterFill(controller: controller) }
    }

    private var hudCaptureHealthMessage: String {
        if controller.shouldSuggestStopForRemoteOutage {
            return L10n.text("Call may have ended — stop recording")
        }
        return L10n.text(controller.systemCaptureHealth.compactStatusMessageKey)
    }

    private var hudCaptureHealthIcon: String {
        switch controller.systemCaptureHealth {
        case .recovered: PVSymbol.success
        case .failed: PVSymbol.error
        case .healthy, .stalled, .recovering: PVSymbol.warning
        }
    }

    private var hudCaptureHealthColor: Color {
        controller.systemCaptureHealth == .recovered ? PVDesign.ok : PVDesign.caution
    }
}

/// The only reader of the 20 Hz level in the HUD, behind an overlay so a
/// sample redraws the fill without rebuilding the panel.
private struct RecordingHUDMeterFill: View {
    let controller: RecordingController

    var body: some View {
        LevelBarFill(fraction: LevelBarFill.fraction(forLevel: controller.micLevel))
            .fill(controller.micLevelLow ? PVDesign.ink3 : VoicePalette.me)
    }
}
