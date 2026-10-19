import AppKit
import SwiftUI

/// Off by default. While dictating, the strip shrinks to the audio level and
/// the elapsed time; outcomes that need an action still open the full panel.
enum DictationCompactIndicator {
    static let defaultsKey = "dictationCompactIndicator"
    static let size = NSSize(width: 176, height: 32)

    /// A microphone notice needs the full strip's words.
    @MainActor
    static func applies(to controller: DictationController) -> Bool {
        controller.microphoneNotice == nil && applies(to: controller.phase)
    }

    static func applies(to phase: DictationController.Phase, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: defaultsKey) else { return false }
        switch phase {
        case .preparing, .listening, .delivering, .verified, .dispatched: return true
        default: return false
        }
    }

    static func elapsed(since start: Date?, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start ?? now)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct DictationCompactStripView: View {
    let controller: DictationController

    var body: some View {
        HStack(spacing: 8) {
            if case .dispatched = controller.phase {
                Circle()
                    .fill(.orange)
                    .frame(width: 8, height: 8)
                    .accessibilityIdentifier("dictation-panel-compact")
                Text("Sent, not verified")
                    .font(.caption)
                    .accessibilityIdentifier("dictation-panel-delivery-status")
            } else if case .verified(let words) = controller.phase {
                Image(systemName: PVSymbol.success)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("dictation-panel-compact")
                Text(L10n.format("%d words inserted.", words))
                    .font(.caption)
                    .accessibilityIdentifier("dictation-panel-delivery-status")
            } else {
                icon
                    .accessibilityIdentifier("dictation-panel-compact")
                DictationWaveform(
                    level: controller.micLevel, isActive: controller.phase == .listening, dimmed: isLoadingModel)
                    .frame(width: 64, height: 22)
                    .accessibilityIdentifier("dictation-panel-meter")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(DictationCompactIndicator.elapsed(since: controller.captureStartedAt, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("dictation-panel-elapsed")
                }
            }
        }
        // No backdrop: the glyphs float, and a soft shadow keeps them legible on any wallpaper.
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .padding(.horizontal, 12)
        .frame(width: DictationCompactIndicator.size.width, height: DictationCompactIndicator.size.height)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        if isLoadingModel {
            Image(systemName: "hourglass")
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
                .accessibilityLabel(L10n.text("Loading the speech model"))
        } else if controller.phase == .delivering {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel(L10n.text("Inserting…"))
        } else {
            Image(systemName: "waveform.badge.mic")
                .foregroundStyle(controller.phase == .listening ? PVDesign.accent : Color.secondary)
                .symbolEffect(.pulse, isActive: controller.phase == .listening)
                .accessibilityLabel(L10n.text("Dictating"))
        }
    }

    private var isLoadingModel: Bool { controller.phase == .listening && controller.isLoadingModel }
}
