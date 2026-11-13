import XCTest

extension ArchitectureDependencyTests {
    // One app owner calls the legacy facade, and launch opens it, so no window opens without a purge.
    func testLegacyDictationRetentionHasOneAppOwnerOpenedAtLaunch() throws {
        let callers = try Self.sourceMatches(
            under: "Sources",
            pattern: #"\b(purgeExpiredLegacyDictationData|deleteAllLegacyDictationData|legacyDictationRows)\("#,
            codeOnly: true)
        XCTAssertEqual(
            Set(callers),
            ["StorageKit/Schema/Legacy/LegacyDictationRetention.swift", "portavoz-app/LegacyDictationModel.swift"])
        XCTAssertTrue(try Self.contents(of: "Sources/portavoz-app/AppLaunchModel.swift")
            .contains("services.legacyDictation.open()"))
        XCTAssertTrue(try Self.contents(of: "Sources/portavoz-app/AppServices+ResourceGovernor.swift")
            .contains("legacyDictation.purgeExpiredInBackground()"))

        let retention = try Self.contents(of: "Sources/StorageKit/Schema/Legacy/LegacyDictationRetention.swift")
        XCTAssertFalse(retention.contains("import PortavozCore"), "the legacy facade must outlive the dictation types")
        // It may change only legacy dictation tables; a note link goes by cascade, never by name.
        let writes = try NSRegularExpression(pattern: #"(?i)\b(?:DELETE\s+FROM|UPDATE|INSERT\s+INTO)\s+(\w+)"#)
        let targets = Set(writes.matches(in: retention, range: NSRange(retention.startIndex..., in: retention))
            .compactMap { Range($0.range(at: 1), in: retention).map { String(retention[$0]) } })
        XCTAssertEqual(targets, [
            "dictationRecord", "dictationRecordSearch", "dictationStatsDay", "dictationStatsCounted",
            "dictationHistoryPolicy"
        ])
    }
}
