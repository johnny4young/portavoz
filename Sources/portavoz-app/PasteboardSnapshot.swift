import AppKit

/// Owned bytes, not server-bound NSPasteboardItems: those become stale as soon
/// as the clipboard changes. Capture is all-or-nothing across ordered items.
struct PasteboardSnapshot {
    static let maximumItems = 16
    static let maximumRepresentations = 64
    static let maximumRepresentationBytes = 4 * 1_024 * 1_024
    static let maximumRetainedBytes = 8 * 1_024 * 1_024

    private struct Representation {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    private let items: [[Representation]]
    let changeCount: Int

    // No arbitrary conversion services, promised-file dereferencing or keyed
    // object decoding. Unknown formats keep the clipboard untouched.
    private static let supportedTypes: Set<NSPasteboard.PasteboardType> = [
        .string, .rtf, .rtfd, .html, .png, .tiff, .pdf, .URL, .fileURL,
        .font, .ruler, .color,
        .init("public.utf16-plain-text"), .init("public.utf16-external-plain-text"),
        .init("org.nspasteboard.source")
    ]

    init?(of pasteboard: NSPasteboard) {
        let generation = pasteboard.changeCount
        guard let source = pasteboard.pasteboardItems else {
            // An empty board may report nil rather than an empty item array.
            guard pasteboard.types?.isEmpty != false, pasteboard.changeCount == generation else { return nil }
            self.items = []
            self.changeCount = generation
            return
        }
        guard source.count <= Self.maximumItems else { return nil }
        let advertisedTypes = source.map(\.types)
        var representationCount = 0
        for types in advertisedTypes {
            guard !types.isEmpty, types.count <= Self.maximumRepresentations - representationCount,
                  types.allSatisfy(Self.supportedTypes.contains), Set(types).count == types.count else { return nil }
            representationCount += types.count
        }
        guard pasteboard.changeCount == generation else { return nil }
        var retainedBytes = 0
        var captured: [[Representation]] = []
        for (item, types) in zip(source, advertisedTypes) {
            var values: [Representation] = []
            for type in types {
                // AppKit has no size-limited read. These are retained-byte
                // bounds, not a promise about a provider's peak allocation.
                guard let data = item.data(forType: type), pasteboard.changeCount == generation,
                      data.count <= Self.maximumRepresentationBytes,
                      data.count <= Self.maximumRetainedBytes - retainedBytes else { return nil }
                retainedBytes += data.count
                values.append(Representation(type: type, data: data))
            }
            guard item.types == types else { return nil }
            captured.append(values)
        }
        guard pasteboard.changeCount == generation else { return nil }
        self.items = captured
        self.changeCount = generation
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard, expectedChangeCount: Int? = nil) -> Bool {
        var restored: [NSPasteboardItem] = []
        for item in items {
            let value = NSPasteboardItem()
            for representation in item {
                guard value.setData(representation.data, forType: representation.type) else { return false }
            }
            restored.append(value)
        }
        if let expectedChangeCount, pasteboard.changeCount != expectedChangeCount { return false }
        // Never re-share borrowed data through Universal Clipboard. AppKit
        // exposes no getter for the prior board's sharing provenance.
        let generation = pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard restored.isEmpty || pasteboard.writeObjects(restored) else { return false }
        return pasteboard.changeCount == generation
    }
}
