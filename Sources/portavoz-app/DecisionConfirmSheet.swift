import ApplicationKit
import PortavozCore
import SwiftUI

/// The explicit gesture that turns one generated decision into durable truth,
/// optionally saying what it is about. The statement is shown exactly as the
/// summary carries it; the topic stays optional because "we decided this" is
/// already worth confirming before the user has a topic vocabulary.
struct DecisionConfirmSheet: View {
    let target: MeetingDetailFlowState.DecisionConfirmTarget
    let topics: [LinkableTopic]
    let confirm: (DecisionTopicChoice) async -> Bool
    let dismiss: @MainActor () -> Void

    @State private var topicLabel = ""
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Confirm this decision").font(.headline)
            Text(target.statement)
                .textSelection(.enabled)
                .accessibilityIdentifier("decision-confirm-statement")
            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    L10n.text("Topic (optional)"),
                    text: $topicLabel)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("decision-confirm-topic-field")
                if !suggestions.isEmpty {
                    // Suggestions only: picking one fills the field, typing a
                    // fresh label creates a new topic on confirm.
                    HStack(spacing: 6) {
                        ForEach(suggestions) { topic in
                            Button(topic.preferredLabel) {
                                topicLabel = topic.preferredLabel
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier(
                                "decision-confirm-topic-\(topic.id.rawValue.uuidString)")
                        }
                    }
                }
                Text("The decision is saved with its exact source. A topic groups it for later questions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L10n.text("Cancel"), action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button {
                    confirming = true
                    Task {
                        let label = topicLabel.trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        let done = await confirm(
                            label.isEmpty ? .none : .labeled(label))
                        confirming = false
                        if done { dismiss() }
                    }
                } label: {
                    if confirming {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Confirm decision")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(confirming)
                .accessibilityIdentifier("decision-confirm-submit")
            }
        }
        .padding(20)
        .frame(width: 440)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("decision-confirm-sheet")
    }

    /// A short, stable head of the topic list; the field itself is the escape
    /// hatch for everything else.
    private var suggestions: [LinkableTopic] {
        Array(topics.prefix(4))
    }
}
