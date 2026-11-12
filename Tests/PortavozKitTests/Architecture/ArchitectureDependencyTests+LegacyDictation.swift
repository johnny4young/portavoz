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
        // It may change only legacy dictation tables; a note link goes by cascade, never by name.
        let writes = try NSRegularExpression(pattern: #"(?i)\b(?:DELETE\s+FROM|UPDATE|INSERT\s+INTO)\s+(\w+)"#)
        let targets = Set(writes.matches(in: retention, range: NSRange(retention.startIndex..., in: retention))
            .compactMap { Range($0.range(at: 1), in: retention).map { String(retention[$0]) } })
        XCTAssertEqual(targets, ["dictationRecord", "dictationStatsDay", "dictationStatsCounted", "dictationHistoryPolicy"])
    }
}
