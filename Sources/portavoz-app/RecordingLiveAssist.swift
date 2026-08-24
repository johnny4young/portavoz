import Foundation
import IntelligenceKit
import PortavozCore
import SwiftUI

/// The live-assist surfaces as standalone views, keeping the
/// already-large `RecordingView` inside its size budget.

/// Pre-meeting objectives with live check-off. Manual toggling is always
/// available; the sparkle marks a check the Apuntador made from the
/// conversation (opt-in, never unchecks).
struct RecordingObjectivesPanel: View {
    @Bindable var controller: RecordingController
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                L10n.text(controller.interviewAssist.isEnabled
                    ? "Interview objectives" : "Objectives"),
                systemImage: "target")
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
                .accessibilityLabel(L10n.text("Add objective (⏎)"))
                .accessibilityIdentifier("recording-objective-add")
                .help(L10n.text("Add objective (⏎)"))
            }
            ForEach(controller.objectives.objectives) { objective in
                objectiveRow(objective)
            }
            if let issue = controller.objectives.admissionIssue {
                Text(objectiveIssue(issue))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("recording-objective-limit")
            }
            if controller.interviewAssist.isEnabled {
                Text(L10n.format(
                    "%d of %d interview objectives",
                    controller.objectives.objectives.count,
                    RecordingObjectivesModel.maximumObjectives))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("recording-interview-objective-count")
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
                controller.toggleObjective(objective.id)
            } label: {
                Image(systemName: objective.checkedAt == nil
                    ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(objective.checkedAt == nil
                        ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Toggle objective"))
            .accessibilityIdentifier("recording-objective-toggle")
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
                controller.removeObjective(objective.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Remove objective"))
            .help(L10n.text("Remove objective"))
        }
    }

    private func add() {
        controller.addObjective(draft)
        if controller.objectives.admissionIssue == nil {
            draft = ""
        }
    }

    private func objectiveIssue(
        _ issue: RecordingObjectivesModel.AdmissionIssue
    ) -> String {
        switch issue {
        case .tooLong:
            L10n.format(
                "Keep each objective to %d characters or fewer.",
                RecordingObjectivesModel.maximumObjectiveCharacters)
        case .limitReached:
            L10n.format(
                "This recording supports up to %d objectives.",
                RecordingObjectivesModel.maximumObjectives)
        }
    }
}

/// Transparent, inert proactive coaching from two declared local signals.
/// The view can only disclose or dismiss cards; it owns no generation,
/// navigation, persistence, or external-effect action.
struct RecordingProactiveAssistView: View {
    @Bindable var controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("Proactive help"), systemImage: "sparkles")
                    .font(.headline)
                    .accessibilityIdentifier("recording-proactive-panel")
                Spacer()
                Text(controller.proactiveAssist.isPaused
                    ? L10n.text("Paused") : L10n.text("Watching local signals"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("recording-proactive-status")
            }
            if controller.proactiveAssist.suggestions.isEmpty {
                Text("Suggestions appear only from open objectives or measured recent talk balance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(controller.proactiveAssist.suggestions.reversed()) { suggestion in
                    suggestionCard(suggestion)
                }
            }
            Label(
                L10n.text("Local signals only · no model, Web request, or automatic action"),
                systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func suggestionCard(
        _ suggestion: ProactiveAssistSuggestion
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(title(for: suggestion), systemImage: icon(for: suggestion))
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 4)
                Button {
                    controller.dismissProactiveSuggestion(suggestion.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Dismiss suggestion"))
                .accessibilityIdentifier(
                    "recording-proactive-dismiss-\(suggestion.id.uuidString)")
            }
            Text(message(for: suggestion))
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(source(for: suggestion))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "recording-proactive-source-\(suggestion.id.uuidString)")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.orange.opacity(0.25), lineWidth: 1))
        .accessibilityIdentifier(
            "recording-proactive-suggestion-\(suggestion.kind.rawValue)")
    }

    private func title(for suggestion: ProactiveAssistSuggestion) -> String {
        switch suggestion.kind {
        case .openObjective:
            L10n.text("Bring this objective back")
        case .talkBalance:
            L10n.text("Invite another voice in")
        }
    }

    private func icon(for suggestion: ProactiveAssistSuggestion) -> String {
        switch suggestion.kind {
        case .openObjective: "target"
        case .talkBalance: "person.2.wave.2"
        }
    }

    private func message(for suggestion: ProactiveAssistSuggestion) -> String {
        switch suggestion.kind {
        case .openObjective:
            suggestion.objective?.text ?? ""
        case .talkBalance:
            L10n.format(
                "You spoke %d%% of the recent measured window.",
                Int(((suggestion.measuredUserFraction ?? 0) * 100).rounded()))
        }
    }

    private func source(for suggestion: ProactiveAssistSuggestion) -> String {
        let evidence = suggestion.evidence
        let range = "\(timestamp(evidence.startTime))–\(timestamp(evidence.endTime))"
        if suggestion.objective != nil {
            return L10n.format(
                "Source: your open objective + %d closed turns · %@",
                evidence.segmentIDs.count,
                range)
        }
        return L10n.format(
            "Source: %d recent closed turns · %@",
            evidence.segmentIDs.count,
            range)
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
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

/// Rolling talk-time balance: your share of the last five
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
