import SwiftUI

struct DictationCopyStatusLabel: View {
    let status: DictationController.CopyStatus

    var body: some View {
        Text(message)
            .lineLimit(2)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var message: String {
        switch status {
        case .idle: L10n.text("Kept only in memory. Copy it before quitting Portavoz.")
        case .copied: L10n.text("Copied. You can paste the text yourself.")
        case .failed: L10n.text("Couldn't copy. Your text is still here.")
        }
    }
}
