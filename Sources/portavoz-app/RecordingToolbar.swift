import SwiftUI

/// The live recording's control row: the Recording kicker, then Translate,
/// Catch me up and More. Its labels give way to glyphs before anything wraps.
struct RecordingToolbar: View {
    let controller: RecordingController
    let onCompact: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RecordingKicker(startedAt: controller.startedAt)
                .fixedSize()
            Spacer(minLength: 12)
            ViewThatFits(in: .horizontal) {
                secondaryControls
                    .fixedSize(horizontal: true, vertical: false)
                secondaryControls
                    .labelStyle(.iconOnly)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    @ViewBuilder
    private var secondaryControls: some View {
        HStack(spacing: 12) {
            Picker("Translate", selection: translationBinding) {
                Text("No translation").tag(String?.none)
                Text("→ Spanish").tag(String?.some("es"))
                Text("→ English").tag(String?.some("en"))
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help(L10n.text(
                "Show an English or Spanish translation below each spoken caption."))
            .accessibilityIdentifier("recording-translation-picker")
            .accessibilityHint(L10n.text(
                "Show an English or Spanish translation below each spoken caption."))
            Button {
                controller.requestCatchUp()
            } label: {
                Label(L10n.text("Catch me up"), systemImage: PVSymbol.history)
            }
            .controlSize(.small)
            .help(L10n.text(
                "Recap the last few minutes"))
            .accessibilityIdentifier("recording-catch-up")
            .accessibilityHint(L10n.text(
                "Recap the last few minutes"))
            RecordingMoreMenu(controller: controller, onCompact: onCompact)
        }
    }

    private var translationBinding: Binding<String?> {
        Binding(
            get: { controller.translationTarget },
            set: { controller.translationTarget = $0 }
        )
    }
}

/// "● RECORDING" in the colour of the present. The dot's timeline lives in an
/// overlay of a fixed frame, so its blink never re-measures the row.
private struct RecordingKicker: View {
    let startedAt: Date

    var body: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: 8, height: 8)
                .overlay { RecordingKickerDot(startedAt: startedAt) }
            Text("Recording")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(PVDesign.now)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recording-kicker")
    }
}

private struct RecordingKickerDot: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            RecordingLiveDot(
                elapsed: Int(context.date.timeIntervalSince(startedAt)),
                diameter: 8,
                easing: .easeInOut(duration: 0.6))
        }
    }
}

/// The live recording dot: it blinks each second and holds solid under Reduce Motion.
struct RecordingLiveDot: View {
    let elapsed: Int
    let diameter: CGFloat
    var easing: Animation?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(PVDesign.now)
            .frame(width: diameter, height: diameter)
            .opacity(Self.opacity(elapsed: elapsed, reduceMotion: reduceMotion))
            .pvAnimation(easing, value: elapsed)
    }

    nonisolated static func opacity(elapsed: Int, reduceMotion: Bool) -> Double {
        reduceMotion || elapsed.isMultiple(of: 2) ? 1 : 0.35
    }
}

/// The stage's status line: your share of the last five minutes, then your
/// microphone's mute control and level.
struct RecordingStageFooter: View {
    let controller: RecordingController

    var body: some View {
        HStack(spacing: 16) {
            RecordingTalkBalanceCue(controller: controller)
            Spacer(minLength: 12)
            RecordingLevelMeter(controller: controller)
        }
        .frame(height: 40)
        .padding(.horizontal, 20)
        .overlay(alignment: .top) {
            Rectangle().fill(PVDesign.line).frame(height: 1)
        }
    }
}

/// Mute control and level track. Neither reads the 20 Hz level: a change in
/// this body would re-measure the row around it.
private struct RecordingLevelMeter: View {
    let controller: RecordingController

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
                    controller.micMuted || controller.micLevelLow ? PVDesign.caution : PVDesign.ink3)
                .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text(controller.micMuted
                ? "Your mic is muted for Portavoz" : "Mute your mic for Portavoz"))
            .accessibilityIdentifier("recording-mute-mic")
            .help(L10n.text(controller.micMuted
                    ? "Your mic is muted for Portavoz" : "Mute your mic for Portavoz"))
            Capsule()
                .fill(.quaternary)
                .frame(width: 90, height: 5)
                .overlay { RecordingLevelMeterFill(controller: controller) }
                .opacity(controller.micMuted ? 0.4 : 1)
        }
    }
}

/// The only reader of the 20 Hz level. It lives in an overlay, with its
/// animation inside, so each sample redraws the fill and nothing else.
private struct RecordingLevelMeterFill: View {
    let controller: RecordingController

    var body: some View {
        LevelBarFill(
            fraction: controller.micMuted
                ? 0 : LevelBarFill.fraction(forLevel: controller.micLevel))
            .fill(controller.micLevelLow ? PVDesign.ink3 : VoicePalette.me)
            .pvAnimation(.easeOut(duration: 0.15), value: controller.micLevel)
    }
}

/// The rest of the bar's actions live in one panel. It reads only the two
/// opt-in flags, so caption updates that re-render the bar never rebuild it
/// under the pointer, and its switches show their state plainly.
private struct RecordingMoreMenu: View {
    let controller: RecordingController
    let onCompact: () -> Void

    @State private var showsPanel = false

    var body: some View {
        Button {
            showsPanel.toggle()
        } label: {
            Label(L10n.text("More"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .controlSize(.small)
        .help(L10n.text("Proactive help, interview mode, a suggested question and the mini panel"))
        .accessibilityIdentifier("recording-more")
        .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: proactiveAssistBinding) {
                    Label(L10n.text("Proactive"), systemImage: PVSymbol.proactive)
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("recording-proactive-assist")
                Toggle(isOn: interviewAssistBinding) {
                    Label(L10n.text("Interview"), systemImage: "person.crop.rectangle.stack")
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("recording-interview-assist")
                Divider()
                Button {
                    showsPanel = false
                    controller.requestNextQuestion()
                } label: {
                    Label(L10n.text("Suggest a question"), systemImage: "lightbulb")
                }
                .accessibilityIdentifier("recording-next-question")
                Button {
                    showsPanel = false
                    onCompact()
                } label: {
                    Label(L10n.text("Floating mini panel"), systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .accessibilityIdentifier("recording-hud")
            }
            .controlSize(.small)
            .padding(14)
            .frame(width: 260, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("recording-more-panel")
        }
    }

    private var interviewAssistBinding: Binding<Bool> {
        Binding(
            get: { controller.interviewAssist.isEnabled },
            set: { controller.interviewAssist.setEnabled($0, captions: controller.captions) })
    }

    private var proactiveAssistBinding: Binding<Bool> {
        Binding(
            get: { controller.proactiveAssist.isEnabled },
            set: { controller.setProactiveAssistEnabled($0) })
    }
}
