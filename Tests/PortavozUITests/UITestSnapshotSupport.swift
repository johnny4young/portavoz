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

/// True when this element exposes `text` through its label, value or title.
@MainActor
func uiSnapshotText(_ snapshot: any XCUIElementSnapshot, contains text: String) -> Bool {
    [snapshot.label, snapshot.value as? String, snapshot.title]
        .compactMap { $0 }.contains { $0.contains(text) }
}

/// One bounded readiness wait over fresh observations of `owner`. Every
/// required, typed or text-bearing identifier must appear exactly once in the
/// same observation, with its required element type and expected content.
/// Each poll indexes the tree in one traversal. A transient snapshot failure
/// retries inside the same deadline; the last error is reported on expiry.
@MainActor
func uiObservation(
    of owner: XCUIElement,
    requiring requiredIdentifiers: Set<String> = [],
    types requiredTypes: [String: XCUIElement.ElementType] = [:],
    expectedText: [String: String] = [:],
    timeout: TimeInterval = 5,
    message: String
) throws -> any XCUIElementSnapshot {
    let identifiers = requiredIdentifiers
        .union(requiredTypes.keys)
        .union(expectedText.keys)
    var observation: (any XCUIElementSnapshot)?
    var lastError: (any Error)?
    let ready = waitForUITestCondition(timeout: timeout) {
        let snapshot: any XCUIElementSnapshot
        do {
            snapshot = try owner.snapshot()
        } catch {
            lastError = error
            return false
        }
        var index: [String: [any XCUIElementSnapshot]] = [:]
        for node in uiSnapshotMatches({ identifiers.contains($0.identifier) }, in: snapshot) {
            index[node.identifier, default: []].append(node)
        }
        let complete = identifiers.allSatisfy { identifier in
            guard let nodes = index[identifier], nodes.count == 1 else { return false }
            if let type = requiredTypes[identifier], nodes[0].elementType != type { return false }
            if let text = expectedText[identifier], !uiSnapshotText(nodes[0], contains: text) {
                return false
            }
            return true
        }
        guard complete else { return false }
        observation = snapshot
        return true
    }
    let diagnostic = lastError.map { "; last snapshot error: \($0)" } ?? ""
    return try XCTUnwrap(ready ? observation : nil, message + diagnostic)
}
