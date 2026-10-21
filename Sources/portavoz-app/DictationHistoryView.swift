import PortavozCore
import SwiftUI

/// The private dictation history, newest first. Nothing is listed until the
/// user turns history on; rows can be copied or deleted one by one or all.
struct DictationHistoryView: View {
    let model: DictationHistoryModel
    @State private var confirmingDeleteAll = false
    @State private var addingToMeeting: DictationRecord?
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if showsFilters { filters }
                if let failure = model.failure {
                    Label(failure, systemImage: PVSymbol.warning)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("dictation-history-error")
                }
                content
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .accessibilityIdentifier("dictation-history")
        .task { await model.load() }
        .sheet(item: $addingToMeeting) { DictationMeetingPicker(record: $0, model: model) }
        .task(id: query) {
            // Typing settles before the query runs; each keystroke cancels the last wait.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            var filter = model.filter
            filter.query = query
            await model.apply(filter)
        }
        .confirmationDialog(
            "Delete every saved dictation?", isPresented: $confirmingDeleteAll, titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) {
                query = ""
                Task { await model.deleteAll() }
            }
                .accessibilityIdentifier("dictation-history-delete-all-confirm")
        } message: {
            Text("This removes them from this Mac. Copies you pasted elsewhere are not affected.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dictations")
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("dictation-history-title")
                Text(model.policy.isEnabled
                     ? L10n.format("Kept on this Mac for %d days.", model.policy.retentionDays)
                     : L10n.text("History is off. New dictations are not saved."))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dictation-history-status")
            }
            Spacer()
            if !model.records.isEmpty {
                Button("Delete all", role: .destructive) { confirmingDeleteAll = true }
                    .accessibilityIdentifier("dictation-history-delete-all")
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !model.isLoaded {
            ProgressView().controlSize(.small)
        } else if model.records.isEmpty, !model.filter.isUnfiltered {
            Text("No dictations match.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("dictation-history-no-results")
        } else if model.records.isEmpty, !model.policy.isEnabled {
            emptyOff
        } else if model.records.isEmpty {
            Text("Your dictations will appear here.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("dictation-history-empty")
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(model.records.enumerated()), id: \.element.id) { index, record in
                    DictationHistoryRow(
                        record: record, index: index, meetings: model.meetingLinks[record.id] ?? [],
                        needsTidyUp: model.needsTidyUp.contains(record.id),
                        onAddToMeeting: { addingToMeeting = record },
                        onDelete: { Task { await model.delete(record.id) } })
                }
                if model.hasMore {
                    Button("Show older dictations") { Task { await model.loadMore() } }
                        .accessibilityIdentifier("dictation-history-more")
                }
            }
        }
    }

    private var showsFilters: Bool {
        !model.records.isEmpty || !model.applications.isEmpty || !model.filter.isUnfiltered
    }

    private var filters: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search dictations", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("dictation-history-search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.text("Clear search"))
                        .accessibilityIdentifier("dictation-history-search-clear")
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PVDesign.radiusSmall))
            Picker("App", selection: filterBinding(\.applicationName)) {
                Text("All apps").tag(String?.none)
                ForEach(model.applications, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .fixedSize()
            .accessibilityIdentifier("dictation-history-app-filter")
            Toggle("Only not delivered", isOn: filterBinding(\.onlyNotDelivered))
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("dictation-history-undelivered-filter")
        }
    }

    private func filterBinding<Value>(_ keyPath: WritableKeyPath<DictationRecordFilter, Value>) -> Binding<Value> {
        Binding(
            get: { model.filter[keyPath: keyPath] },
            set: { value in
                var filter = model.filter
                filter[keyPath: keyPath] = value
                Task { await model.apply(filter) }
            })
    }

    private var emptyOff: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep a private history")
                .font(.title3.weight(.semibold))
            // swiftlint:disable:next line_length
            Text("Find what you dictated later, including text that didn't reach its app. It stays on this Mac, passwords and practice are never kept, and nothing is saved until you turn it on.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn on history") { Task { await model.update(isEnabled: true) } }
                .buttonStyle(.borderedProminent)
                .tint(PVDesign.accent)
                .accessibilityIdentifier("dictation-history-enable")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PVDesign.radiusSmall))
    }
}

private struct DictationHistoryRow: View {
    let record: DictationRecord
    let index: Int
    let meetings: [DictationMeetingLink]
    let needsTidyUp: Bool
    let onAddToMeeting: () -> Void
    let onDelete: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(record.text)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .accessibilityIdentifier("dictation-history-text-\(index)")
                if let original = record.originalText {
                    DisclosureGroup("Original") {
                        Text(original).textSelection(.enabled).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .accessibilityIdentifier("dictation-history-original-\(index)")
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(record.delivery == .notDelivered ? .orange : .secondary)
                    .accessibilityIdentifier("dictation-history-details-\(index)")
                if !meetings.isEmpty {
                    Label(
                        L10n.format("Added to %@", meetings.map(\.title).joined(separator: ", ")),
                        systemImage: PVSymbol.success)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("dictation-history-linked-\(index)")
                }
                if needsTidyUp {
                    Text("That meeting shows tidied notes. Tidy up again to include this one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("dictation-history-tidy-hint-\(index)")
                }
            }
            Spacer(minLength: 0)
            Button(action: onAddToMeeting) {
                Label("Add to a meeting", systemImage: "note.text.badge.plus")
            }
            .labelStyle(.iconOnly)
            .help(L10n.text("Add to a meeting's notes"))
            .accessibilityIdentifier("dictation-history-add-meeting-\(index)")
            Button {
                copied = TextInserter.copy(record.text)
            } label: {
                Label(copied ? L10n.text("Copied") : L10n.text("Copy"), systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("dictation-history-copy-\(index)")
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("dictation-history-delete-\(index)")
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: PVDesign.radiusSmall))
    }

    private var details: String {
        var parts = [record.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let app = record.applicationName { parts.append(app) }
        parts.append(record.mode == .clean ? L10n.text("Clean") : L10n.text("Literal"))
        let delivery = switch record.delivery {
        case .verified: L10n.text("Inserted")
        case .dispatched: L10n.text("Sent, not verified")
        case .notDelivered: L10n.text("Not delivered")
        }
        return (parts + [delivery]).joined(separator: " · ")
    }
}
