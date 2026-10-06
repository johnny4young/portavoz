import XCTest

/// Traverse one immutable observation, never cache it across a user action.
@MainActor
func uiSnapshotMatches(
    _ matches: (any XCUIElementSnapshot) -> Bool,
    in snapshot: any XCUIElementSnapshot
) -> [any XCUIElementSnapshot] {
    var pending = [snapshot]
    var result: [any XCUIElementSnapshot] = []
    while let node = pending.popLast() {
        if matches(node) { result.append(node) }
        pending.append(contentsOf: node.children)
    }
    return result
}

@MainActor
func uiSnapshotElement(
    _ identifier: String,
    type: XCUIElement.ElementType? = nil,
    in snapshot: any XCUIElementSnapshot
) throws -> any XCUIElementSnapshot {
    let matches = uiSnapshotMatches({
        $0.identifier == identifier && (type == nil || $0.elementType == type)
    }, in: snapshot)
    return try XCTUnwrap(matches.count == 1 ? matches.first : nil,
                         "Expected exactly one \(identifier) in this observation; found \(matches.count)")
}

/// Preserve the value-first semantics of `renderedText(of: XCUIElement)`.
@MainActor
func renderedText(of snapshot: any XCUIElementSnapshot) -> String {
    guard let value = snapshot.value as? String, !value.isEmpty else { return snapshot.label }
    return value
}

/// True when exactly one `identifier` element in this observation exposes
/// `text` through its label, value or title. Content readiness, not presence.
@MainActor
func uiSnapshot(_ snapshot: any XCUIElementSnapshot, identifier: String, contains text: String) -> Bool {
    let matches = uiSnapshotMatches({ $0.identifier == identifier }, in: snapshot)
    guard matches.count == 1 else { return false }
    return [matches[0].label, matches[0].value as? String, matches[0].title]
        .compactMap { $0 }.contains { $0.contains(text) }
}
