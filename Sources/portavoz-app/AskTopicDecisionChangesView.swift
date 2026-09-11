import ApplicationKit
import SwiftUI

enum AskTopicDecisionChangeContext {
    case decisionConflicts
    case changesSince

    var identifierPrefix: String {
        switch self {
        case .decisionConflicts: "ask-topic-conflict"
        case .changesSince: "ask-topic-change-since"
        }
    }

    var heading: LocalizedStringKey {
        switch self {
        case .decisionConflicts: "Confirmed decision change"
        case .changesSince: "Confirmed change since meeting"
        }
    }
}

struct AskTopicDecisionChangesView: View {
    let changes: [AskMemoryDecisionConflict]
    let context: AskTopicDecisionChangeContext
    let onOpenCitation: (AskCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(changes) { change in
                changeCard(change)
            }
        }
    }

    private func changeCard(
        _ change: AskMemoryDecisionConflict
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(context.heading, systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            Text("Changed to")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(change.successorStatement)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier(
                    "\(context.identifierPrefix)-\(change.id.rawValue.uuidString)")
            Text("Replaced")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text(change.replacedStatement)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "\(context.identifierPrefix)-replaced-\(change.id.rawValue.uuidString)")
            Text(change.occurredAt.formatted(
                date: .abbreviated,
                time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Divider()
            Text("Evidence")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(
                Array(orderedCitations(change).enumerated()),
                id: \.offset
            ) { index, citation in
                Button {
                    onOpenCitation(citation)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                        Text(
                            "\(citation.meetingTitle) · \(AskMarkdown.clock(citation.timestamp))")
                            .lineLimit(1)
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PVDesign.accent)
                .help(citation.text)
                .accessibilityIdentifier(
                    "\(context.identifierPrefix)-evidence-"
                        + "\(change.id.rawValue.uuidString)-\(index)")
            }
        }
        .padding(12)
        .background(
            .quaternary.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 10))
    }

    private func orderedCitations(
        _ change: AskMemoryDecisionConflict
    ) -> [AskCitation] {
        [change.primaryCitation] + change.citations.filter {
            $0.segmentID != change.primaryCitation.segmentID
        }
    }
}
