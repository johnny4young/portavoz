import SwiftUI

/// The live recording command surface. It remains one row when space allows
/// and becomes two rows at the app's compact window width, keeping both the
/// elapsed clock and Stop visible without crowding the transcript.
struct RecordingToolbar: View {
    let controller: RecordingController
    let companionAvailable: Bool
    let onStop: () -> Void
    let onCompact: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                recordingStatus
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                secondaryControls
                    .fixedSize(horizontal: true, vertical: false)
                stopButton
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    recordingStatus
                    Spacer(minLength: 12)
                    stopButton
                }
                HStack(spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        secondaryControls
                        secondaryControls
                            .labelStyle(.iconOnly)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private var recordingStatus: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: controller.startedAt, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(controller.startedAt))
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .opacity(elapsed.isMultiple(of: 2) ? 1 : 0.35)
                        .animation(.easeInOut(duration: 0.6), value: elapsed)
                    Text(String(format: "%02d:%02d", max(0, elapsed) / 60, max(0, elapsed) % 60))
                        .font(.system(size: 24, weight: .medium).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("recording-elapsed-time")
                }
            }
            RecordingLevelMeter(controller: controller)
            RecordingTalkBalanceCue(captions: controller.captions)
        }
    }

    @ViewBuilder
    private var secondaryControls: some View {
        HStack(spacing: 12) {
            if #available(macOS 15.0, *) {
                Picker("Translate", selection: translationBinding) {
                    Text("No translation").tag(String?.none)
                    Text("→ Spanish").tag(String?.some("es"))
                    Text("→ English").tag(String?.some("en"))
                }
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
                .help(L10n.text(
                    "Show an English or Spanish translation below each spoken caption."))
                .accessibilityIdentifier("recording-translation-picker")
                .accessibilityHint(L10n.text(
                    "Show an English or Spanish translation below each spoken caption."))
            }
            if companionAvailable {
                Toggle(isOn: companionBinding) {
                    Label("Apuntador", systemImage: "questionmark.bubble")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(L10n.text(
                    "Detects questions and suggests on-device answers. It never answers for you."))
                .accessibilityIdentifier("recording-companion")
                .accessibilityHint(L10n.text(
                    "Detects questions and suggests on-device answers. It never answers for you."))
            }
            Button {
                controller.requestCatchUp()
            } label: {
                Label(L10n.text("Catch me up"), systemImage: "clock.arrow.circlepath")
            }
            .controlSize(.small)
            .help(L10n.text(
                "A quick recap of the last few minutes — for when you zoned out or just joined."))
            .accessibilityIdentifier("recording-catch-up")
            .accessibilityHint(L10n.text(
                "A quick recap of the last few minutes — for when you zoned out or just joined."))
            Button {
                controller.requestNextQuestion()
            } label: {
                Label(L10n.text("Suggest a question"), systemImage: "lightbulb")
            }
            .controlSize(.small)
            .help(L10n.text(
                "One or two questions worth asking next, grounded in the conversation and your open objectives."))
            .accessibilityIdentifier("recording-next-question")
            .accessibilityHint(L10n.text(
                "One or two questions worth asking next, grounded in the conversation and your open objectives."))
            Button(action: onCompact) {
                Label("HUD", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .controlSize(.small)
            .help(L10n.text(
                "Floating mini panel with the timer and captions — records without covering your meeting"))
            .accessibilityIdentifier("recording-hud")
            .accessibilityHint(L10n.text(
                "Floating mini panel with the timer and captions — records without covering your meeting"))
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Label("Stop", systemImage: "stop.circle.fill")
        }
        .controlSize(.small)
        .tint(.red)
        .keyboardShortcut(".")
        .accessibilityIdentifier("recording-stop")
    }

    private var companionBinding: Binding<Bool> {
        Binding(
            get: { controller.companionEnabled },
            set: { controller.companionEnabled = $0 }
        )
    }

    private var translationBinding: Binding<String?> {
        Binding(
            get: { controller.translationTarget },
            set: { controller.translationTarget = $0 }
        )
    }
}

/// The meter is the only surface that needs the 20 Hz mic-level publication.
/// Its observation boundary keeps those frames from rebuilding translation,
/// Companion, catch-up, and window controls.
private struct RecordingLevelMeter: View {
    @Bindable var controller: RecordingController

    var body: some View {
        HStack(spacing: 6) {
            Button {
                controller.setMicMuted(!controller.micMuted)
            } label: {
                Image(
                    systemName: controller.micMuted
                        ? "mic.slash.fill" : (controller.micLevelLow ? "mic.fill" : "mic")
                )
                .foregroundStyle(
                    controller.micMuted ? .red : (controller.micLevelLow ? .orange : .secondary)
                )
                .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("recording-mute-mic")
            .help(L10n.text(controller.micMuted
                    ? "Your mic is muted for Portavoz" : "Mute your mic for Portavoz"))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                GeometryReader { geometry in
                    Capsule()
                        .fill(controller.micLevelLow ? Color.orange : Color.green)
                        .frame(width: geometry.size.width * (controller.micMuted ? 0 : meterFraction))
                }
            }
            .frame(width: 90, height: 5)
            .opacity(controller.micMuted ? 0.4 : 1)
            .animation(.easeOut(duration: 0.15), value: controller.micLevel)
        }
    }

    private var meterFraction: CGFloat {
        let level = controller.micLevel
        guard level > 0.0001 else { return 0 }
        let decibels = 20 * log10(level)
        return CGFloat(max(0, min(1, (Double(decibels) + 60) / 60)))
    }
}
