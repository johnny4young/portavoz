import Foundation
import PortavozCore
import SwiftUI

struct CommitmentRadarDueDateSheet: View {
    let item: CommitmentRadarItem
    let cancel: @MainActor () -> Void
    let save: @MainActor (Date?) async -> Void

    @State private var includesDueDate: Bool
    @State private var dueAt: Date
    @State private var isSaving = false

    init(
        item: CommitmentRadarItem,
        cancel: @escaping @MainActor () -> Void,
        save: @escaping @MainActor (Date?) async -> Void
    ) {
        self.item = item
        self.cancel = cancel
        self.save = save
        _includesDueDate = State(initialValue: item.commitment.dueAt != nil)
        _dueAt = State(initialValue: item.commitment.dueAt
            ?? Date().addingTimeInterval(24 * 60 * 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Due date")
                .font(.title3.weight(.semibold))
            Text(verbatim: item.commitment.title)
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle("Add due date", isOn: $includesDueDate)
                .accessibilityIdentifier("commitment-radar-due-toggle")
            if includesDueDate {
                DatePicker(
                    "Due date",
                    selection: $dueAt,
                    displayedComponents: [.date])
                    .accessibilityIdentifier("commitment-radar-due-date")
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("commitment-radar-due-cancel")
                Button("Save") {
                    isSaving = true
                    Task {
                        await save(includesDueDate ? dueAt : nil)
                        isSaving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .accessibilityIdentifier("commitment-radar-due-save")
            }
        }
        .padding(20)
        .frame(width: 430)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commitment-radar-due-editor")
    }
}
