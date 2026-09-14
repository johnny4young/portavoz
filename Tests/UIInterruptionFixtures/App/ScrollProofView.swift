import AppKit

/// Deliberately amplifies only this disposable scroll view's wheel response.
/// It models an adversarial input/output scale, not a claimed macOS host factor.
@MainActor
final class ScrollProofView: NSScrollView {
    private var scenario = 0
    private var responseScale: CGFloat { scenario < 2 ? 8 : 1 }

    func advanceGeometry() {
        scenario += 1
        resetPosition()
    }

    private func resetPosition() {
        contentView.scroll(to: NSPoint(x: 0, y: scenario.isMultiple(of: 2) ? 0 : 240))
        reflectScrolledClipView(contentView)
    }

    init(target: NSButton) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("proof-scroll")
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 320, height: 1_200))
        target.frame = NSRect(x: 80, y: 112, width: 160, height: 28)
        document.addSubview(target)
        documentView = document
    }

    required init?(coder: NSCoder) { fatalError("programmatic synthetic fixture only") }

    override func scrollWheel(with event: NSEvent) {
        guard let documentView else { return }
        let proposedY = contentView.bounds.minY - event.scrollingDeltaY * responseScale
        let maximumY = max(0, documentView.bounds.height - contentView.bounds.height)
        let y = min(max(proposedY, 0), maximumY)
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
    }
}

@MainActor
private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}
