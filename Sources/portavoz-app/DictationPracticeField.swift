import AppKit
import Observation
import PortavozCore

/// An in-app field for trying dictation with the real microphone and model.
/// While its window is the key window, a new session delivers here: no
/// clipboard, no synthetic paste and no Accessibility.
@MainActor
@Observable
final class DictationPracticeField {
    private(set) var text = ""
    /// Each visible field and whether its window is key.
    @ObservationIgnored private var holders: [UUID: Bool] = [:]

    var isArmed: Bool { holders.values.contains(true) }

    func show(_ holder: UUID, isKey: Bool) {
        holders[holder] = isKey
    }

    /// Practice text is never kept once no view shows the field.
    func hide(_ holder: UUID) {
        holders[holder] = nil
        if holders.isEmpty { text = "" }
    }

    func clear() {
        text = ""
    }

    func receive(_ dictated: String) -> DictationDeliveryOutcome {
        let words = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return .refused(.emptyText) }
        guard !holders.isEmpty else { return .refused(.targetChanged) }
        text = text.isEmpty ? words : text + " " + words
        return .verified
    }

    /// The destination is chosen when a session starts, so a session begun in
    /// another app keeps that app's field even if the practice field appears later.
    func route(
        _ dependencies: DictationSessionDependencies, appIsActive: Bool
    ) -> DictationSessionDependencies {
        guard isArmed, appIsActive else { return dependencies }
        var routed = dependencies
        routed.canInsert = { true }
        routed.beginHistory = { nil }
        routed.recordStats = { _ in }
        routed.locatePanelAnchor = { Self.panelAnchor(around: NSEvent.mouseLocation) }
        routed.captureDestination = { [weak self] in
            CapturedDictationDestination(name: L10n.text("the practice field"), canRetry: false) { text in
                self?.receive(text) ?? .refused(.targetChanged)
            }
        }
        return routed
    }

    /// The field has no caret, so the strip opens by the pointer that started the
    /// session, above or below, without covering the button under it.
    static func panelAnchor(around point: NSPoint) -> DictationPanelAnchor {
        .caret(NSRect(x: point.x, y: point.y - 24, width: 0, height: 48))
    }
}
