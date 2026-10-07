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
/// retries inside the same deadline; on expiry the failure names the unmet
/// identifiers and reports a snapshot error only if one ended the final poll.
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
    // Name what the final successful observation still lacked, as the former
    // per-element assertions did, instead of failing with only the phase.
    var unmet = identifiers.sorted()
    let ready = waitForUITestCondition(timeout: timeout) {
        let snapshot: any XCUIElementSnapshot
        do {
            snapshot = try owner.snapshot()
            lastError = nil
        } catch {
            lastError = error
            return false
        }
        var index: [String: [any XCUIElementSnapshot]] = [:]
        for node in uiSnapshotMatches({ identifiers.contains($0.identifier) }, in: snapshot) {
            index[node.identifier, default: []].append(node)
        }
        unmet = identifiers.filter { identifier in
            guard let nodes = index[identifier], nodes.count == 1 else { return true }
            if let type = requiredTypes[identifier], nodes[0].elementType != type { return true }
            if let text = expectedText[identifier], !uiSnapshotText(nodes[0], contains: text) {
                return true
            }
            return false
        }.sorted()
        guard unmet.isEmpty else { return false }
        observation = snapshot
        return true
    }
    var diagnostic = unmet.isEmpty ? "" : "; unmet: \(unmet.joined(separator: ", "))"
    if let lastError { diagnostic += "; last snapshot error: \(lastError)" }
    return try XCTUnwrap(ready ? observation : nil, message + diagnostic)
}
