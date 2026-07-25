import IntelligenceKit
import PortavozCore
import SwiftUI

/// The live-assist surfaces (APUN-003/004) as standalone views, keeping the
/// already-large `RecordingView` inside its size budget.

/// Pre-meeting objectives with live check-off. Manual toggling is always
/// available; the sparkle marks a check the Apuntador made from the
/// conversation (opt-in, never unchecks).
struct RecordingObjectivesPanel: View {
    @Bindable var controller: RecordingController
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Objectives", systemImage: "target")
                .font(.headline)
                .accessibilityIdentifier("recording-objectives-panel")
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Add an objective…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .accessibilityIdentifier("recording-objective-field")
                Button(action: add) {
                    Image(systemName: "plus.circle.fill").imageScale(.large)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    draft.trimmingCharacters(in: .whitespaces).isEmpty
                        ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("recording-objective-add")
                .help(L10n.text("Add objective (⏎)"))
            }
            ForEach(controller.objectives.objectives) { objective in
                objectiveRow(objective)
            }
            if controller.objectives.objectives.isEmpty {
                // One-line UI help text.
                // swiftlint:disable:next line_length
                Text("What should this meeting achieve? Objectives get checked off as the conversation covers them, and the summary reports what stayed open.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func objectiveRow(
        _ objective: RecordingObjectivesModel.LiveObjective
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                controller.objectives.toggle(
                    objective.id,
                    elapsed: Date().timeIntervalSince(controller.startedAt))
            } label: {
                Image(systemName: objective.checkedAt == nil
                    ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(objective.checkedAt == nil
                        ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Toggle objective"))
            Text(objective.text)
                .font(.callout)
                .strikethrough(objective.checkedAt != nil)
                .foregroundStyle(objective.checkedAt == nil
                    ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            if objective.checkedByModel {
                Image(systemName: "sparkle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(L10n.text("Checked off by Apuntador"))
            }
            Spacer(minLength: 2)
            Button {
                controller.objectives.remove(objective.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(L10n.text("Remove objective"))
        }
    }

    private func add() {
        controller.objectives.add(draft)
        draft = ""
    }
}

/// The next-question sibling of the catch-up card: same lifecycle, same
/// honesty about capability, dismiss as the only other action.
struct RecordingNextQuestionCard: View {
    let state: RecordingNextQuestionModel.State
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.text("Suggest a question"), systemImage: "lightbulb")
                    .font(.headline)
                    .accessibilityIdentifier("recording-next-question-panel")
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Dismiss suggestion"))
                .accessibilityIdentifier("recording-next-question-dismiss")
            }
            switch state {
            case .generating:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Thinking of a good question…"))
                        .foregroundStyle(.secondary)
                }
            case .ready(let suggestion):
                MarkdownText(text: suggestion)
                    .font(.callout)
            case .unavailable(let reason):
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Rolling talk-time balance (APUN-004): your share of the last five
/// minutes as an amber fill. Pure math over closed captions — measured,
/// not judged — with a soft emphasis only when you carry most of the
/// conversation on solid evidence.
struct RecordingTalkBalanceCue: View {
    let captions: [TranscriptSegment]

    var body: some View {
        if let balance = LiveTalkTimePolicy.balance(captions) {
            let percent = Int((balance.meFraction * 100).rounded())
            Capsule()
                .fill(.quaternary)
                .frame(width: 44, height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(balance.isNotable
                                ? AnyShapeStyle(.orange)
                                : AnyShapeStyle(.tint))
                            .frame(width: geometry.size.width
                                * CGFloat(balance.meFraction))
                    }
                }
                .accessibilityIdentifier("recording-talk-balance")
                .accessibilityLabel(L10n.text("Talk balance"))
                .accessibilityValue("\(percent)%")
                .help(L10n.format(
                    "You spoke %d%% of the last five minutes.", percent))
        }
    }
}
