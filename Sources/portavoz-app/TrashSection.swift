import ApplicationKit
import SwiftUI

/// Sidebar section: soft-deleted meetings with one-click restore. Deletes
/// were ALWAYS tombstones (D4) — this finally gives them a door back.
/// Collapsed by default; invisible while the trash is empty.
struct TrashSection: View {
    @AppStorage("trashSectionExpanded") private var expanded = false
    /// Supplied by LibraryModel's parent-level observation — a lifecycle
    /// modifier on a Section-producing view inside a List does not reliably fire.
    let items: [LibraryTrashItem]
    let onRestore: (LibraryTrashItem) -> Void
    let onPurge: (LibraryTrashItem) -> Void

    var body: some View {
        if !items.isEmpty {
            Section("Recently deleted", isExpanded: $expanded) {
                ForEach(items) { entry in
                    row(entry)
                }
                Text("Kept for 30 days, then removed for good.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ entry: LibraryTrashItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.meeting.title).lineLimit(1)
                Text(L10n.format(
                    "Deleted %@",
                    entry.deletedAt.formatted(.relative(presentation: .named))))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onRestore(entry)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .help(L10n.text("Restore this meeting"))
        }
        .selectionDisabled()
        .contextMenu {
            Button("Delete permanently", role: .destructive) {
                onPurge(entry)
            }
        }
    }
}
