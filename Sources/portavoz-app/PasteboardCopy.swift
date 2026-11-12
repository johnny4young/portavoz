import AppKit

/// A user-initiated Copy: like any Copy command it replaces whatever the clipboard held,
/// several items included, without reading, snapshotting or restoring it.
enum PasteboardCopy {
    @MainActor
    static func copy(
        _ text: String, to pasteboard: NSPasteboard = .general,
        writeString: (NSPasteboard, String) -> Bool = { $0.setString($1, forType: .string) }
    ) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.declareTypes([.string], owner: nil)
        return writeString(pasteboard, text)
    }
}
