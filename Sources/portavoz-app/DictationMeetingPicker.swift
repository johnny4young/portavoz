import PortavozCore
import SwiftUI

/// Chooses the finished meeting whose notes receive a copy of a dictation.
struct DictationMeetingPicker: View {
    let record: DictationRecord
    let model: DictationHistoryModel
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [DictationMeetingChoice]?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to a meeting's notes")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("dictation-meeting-picker-title")
            Text("The text becomes a note of that meeting and goes wherever its notes go: sync, exports and Ask.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("dictation-meeting-picker-note")
            content
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("dictation-meeting-picker-cancel")
            }
        }
        .padding(20)
        .frame(width: 440, height: 400)
        .task { choices = await model.meetingChoices(for: record) }
    }

    @ViewBuilder private var content: some View {
        if let choices, choices.isEmpty {
            Text("No finished meetings yet.")
                .foregroundStyle(.secondary)
                .frame(maxHeight: .infinity, alignment: .top)
                .accessibilityIdentifier("dictation-meeting-picker-empty")
        } else if let choices {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(choices.enumerated()), id: \.element.id) { index, meeting in
                        Button { add(to: meeting) } label: { row(meeting) }
                            .buttonStyle(.plain)
                            .disabled(adding)
                            .accessibilityIdentifier("dictation-meeting-option-\(index)")
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxHeight: .infinity)
        }
    }

    private func row(_ meeting: DictationMeetingChoice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title).font(.callout.weight(.medium))
            let date = meeting.startedAt.formatted(date: .abbreviated, time: .shortened)
            Text(meeting.containsDictation ? L10n.format("%@ · recorded while you dictated", date) : date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PVDesign.radiusSmall))
        .contentShape(.rect)
    }

    private func add(to meeting: DictationMeetingChoice) {
        adding = true
        Task {
            await model.add(record, to: meeting)
            dismiss()
        }
    }
}
