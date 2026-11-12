import XCTest

extension ArchitectureDependencyTests {
    // The legacy retention is prepared before the dictation code leaves; the change that removes
    // the dictation UI is the one that wires it, so no window opens without a purge.
    func testLegacyDictationRetentionHasNoProductionCallerYet() throws {
        let callers = try Self.sourceMatches(
            under: "Sources",
            pattern: #"\b(purgeExpiredLegacyDictationData|deleteAllLegacyDictationData|legacyDictationRows)\("#,
            codeOnly: true)
        XCTAssertEqual(callers, ["StorageKit/Schema/Legacy/LegacyDictationRetention.swift"])

        let retention = try Self.contents(of: "Sources/StorageKit/Schema/Legacy/LegacyDictationRetention.swift")
        XCTAssertFalse(retention.contains("import PortavozCore"), "the legacy facade must outlive the dictation types")
        XCTAssertFalse(retention.contains("contextItem"), "the legacy facade never deletes meeting notes")
    }
}
