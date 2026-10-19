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
        case .preparing, .listening, .delivering, .verified: return true
        default: return false
        }
    }

    static func elapsed(since start: Date?, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start ?? now)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Same dB mapping as the recording HUD's meter: −60 dB → 0, 0 dB → 1.
struct DictationLevelMeter: View {
    let level: Float
    let width: CGFloat
    var dimmed = false

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            GeometryReader { geometry in
                Capsule()
                    .fill(dimmed ? Color.secondary : PVDesign.accent)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(width: width, height: 4)
    }

    private var fraction: CGFloat {
        guard level > 0.0001 else { return 0 }
        let decibels = 20 * log10(level)
        return CGFloat(max(0, min(1, (Double(decibels) + 60) / 60)))
    }
}

struct DictationCompactStripView: View {
    let controller: DictationController

    var body: some View {
        HStack(spacing: 8) {
            if case .verified(let words) = controller.phase {
                Image(systemName: PVSymbol.success)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("dictation-panel-compact")
                Text(L10n.format("%d words inserted.", words))
                    .font(.caption)
                    .accessibilityIdentifier("dictation-panel-delivery-status")
            } else {
                icon
                    .accessibilityIdentifier("dictation-panel-compact")
                DictationLevelMeter(level: controller.micLevel, width: 48, dimmed: isLoadingModel)
                    .accessibilityIdentifier("dictation-panel-meter")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(DictationCompactIndicator.elapsed(since: controller.captureStartedAt, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("dictation-panel-elapsed")
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(width: DictationCompactIndicator.size.width, height: DictationCompactIndicator.size.height)
        .background(.regularMaterial, in: Capsule())
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
