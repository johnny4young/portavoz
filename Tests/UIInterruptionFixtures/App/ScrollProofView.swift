import AppKit

/// Deliberately amplifies only this disposable scroll view's wheel response.
/// It also buffers or discards initial events before observable movement.
/// These are adversarial delivery shapes, not a claimed macOS host factor.
@MainActor
final class ScrollProofView: NSScrollView {
    private var scenario = 0
    private var delayedEventsRemaining = 0
    private var pendingDeltaY: CGFloat = 0
    private var responseScale: CGFloat { scenario < 2 ? 8 : 1 }

    func advanceGeometry() {
        scenario += 1
        resetPosition()
    }

    private func resetPosition() {
        delayedEventsRemaining = scenario >= 4 ? 2 : 0
        pendingDeltaY = 0
        let originY: CGFloat
        switch scenario {
        case 5: originY = 160 // Buffered upward input crosses the target.
        case 7: originY = 200 // Two delivered events can still reach the target.
        default: originY = scenario.isMultiple(of: 2) ? 0 : 240
        }
        contentView.scroll(to: NSPoint(x: 0, y: originY))
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
        pendingDeltaY += event.scrollingDeltaY
        if delayedEventsRemaining > 0 {
            delayedEventsRemaining -= 1
            if scenario >= 6 { pendingDeltaY = 0 }
            return
        }
        let proposedY = contentView.bounds.minY - pendingDeltaY * responseScale
        pendingDeltaY = 0
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
