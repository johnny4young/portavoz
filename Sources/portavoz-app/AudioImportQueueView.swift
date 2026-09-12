import PortavozCore
import SwiftUI

struct AudioImportQueueView: View {
    let model: AudioImportQueueModel
    let onOpen: (MeetingID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Audio imports", systemImage: "tray.and.arrow.down")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("import-queue-close")
            }
            Text("Imports continue when you close this panel. Your original files stay unchanged.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = model.error {
                HStack {
                    Text(error).font(.callout).accessibilityIdentifier("import-queue-error")
                    Spacer()
                    Button("Dismiss") { model.dismissError() }
                        .accessibilityIdentifier("import-queue-error-dismiss")
                }
            }
            Divider()
            ScrollView {
                // The SQLite projection is capped at twenty rows; build all AX rows.
                VStack(alignment: .leading, spacing: 0) {
                    if model.page.entries.isEmpty {
                        Text("No audio imports").foregroundStyle(.secondary).padding(.vertical, 24)
                            .accessibilityIdentifier("import-queue-empty")
                    }
                    ForEach(model.page.entries) { entry in
                        row(entry)
                        Divider()
                    }
                }
            }
            HStack {
                Text(L10n.format("%lld imports · %lld unfinished", model.page.total, model.page.unfinished))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("import-queue-count")
                Spacer()
                Button("Previous") { model.showPage(max(0, model.offset - 20)) }
                    .disabled(model.offset == 0)
                    .accessibilityIdentifier("import-queue-previous")
                Button("Next") { model.showPage(model.offset + 20) }
                    .disabled(!model.page.hasNext)
                    .accessibilityIdentifier("import-queue-next")
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 380, idealHeight: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import-queue-panel")
    }

    private func row(_ entry: AudioImportQueueEntry) -> some View {
        let id = entry.id.rawValue.uuidString
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title).font(.body.weight(.medium)).lineLimit(2)
                Text(AudioImportQueuePresentation.status(
                    entry.job, phase: model.currentID == entry.id ? model.phase : nil))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("import-queue-state-\(id)")
            }
            Spacer()
            switch entry.job.state {
            case .pending, .running:
                Button("Cancel", role: .destructive) { Task { await model.cancel(entry.id) } }
                    .accessibilityIdentifier("import-queue-cancel-\(id)")
            case .failed, .cancelled:
                Button("Retry") { Task { await model.retry(entry.id) } }
                    .accessibilityIdentifier("import-queue-retry-\(id)")
            case .succeeded:
                Button("Open") { onOpen(entry.id) }
                    .accessibilityIdentifier("import-queue-open-\(id)")
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import-queue-row-\(id)")
    }
}
