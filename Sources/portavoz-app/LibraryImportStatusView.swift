import SwiftUI

/// Queue discovery and mutation feedback remain outside the selectable meeting List.
struct LibraryImportStatusView: View {
    let imports: AudioImportQueueModel
    let actionError: String?
    let onOpen: () -> Void
    let onDismissError: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if imports.page.total > 0 || imports.isAdmitting || imports.error != nil {
                Button(action: onOpen) {
                    Label(L10n.format("Audio imports · %lld unfinished", imports.page.unfinished),
                          systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("library-import-queue-open")
            }
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("library-action-error")
                Button("Dismiss", action: onDismissError)
                    .accessibilityIdentifier("library-action-error-dismiss")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
