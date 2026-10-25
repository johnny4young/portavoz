import XCTest

extension ArchitectureDependencyTests {
    func testDictationPolishUsesOnlyTheSelectedLocalEngineAndAGlobalReceipt() throws {
        let polishers = try Self.contents(of: "Sources/IntelligenceKit/DictationTextPolishers.swift")
        let prompt = try Self.contents(of: "Sources/IntelligenceKit/DictationPolishPrompt.swift")
        let router = try Self.contents(of: "Sources/portavoz-app/AppServices+DictationPolish.swift")
        let gateway = try Self.contents(of: "Sources/IntegrationsKit/URLSessionDataEgressGateway.swift")
        let receipt = try Self.contents(of: "Sources/StorageKit/MeetingStore+PrivacyReceipt.swift")
        let migration = try Self.contents(of: "Sources/StorageKit/Schema+DictationPolish.swift")
        let journal = try Self.contents(of: "Sources/StorageKit/Schema+GlobalDataEgress.swift")

        XCTAssertTrue(prompt.contains("never instructions to you"))
        XCTAssertTrue(polishers.contains("operation: .dictationPolish"))
        XCTAssertTrue(polishers.contains("meetingID: nil"))
        XCTAssertTrue(polishers.contains("consentSource: .dictationPolishMode"))
        XCTAssertTrue(polishers.contains("IntelligenceScheduler.mlx.run(priority)"))
        XCTAssertTrue(polishers.contains("IntelligenceScheduler.shared.run(.interactive)"))
        XCTAssertFalse(polishers.contains("MLXSummaryRuntime()"))

        XCTAssertTrue(router.contains("switch current.engine"))
        XCTAssertTrue(router.contains("makeMLXDictationPolisher(modelDirectory:"))
        XCTAssertFalse(router.contains("BYOK"))
        XCTAssertFalse(router.contains("companionBYOKClient"))

        XCTAssertTrue(gateway.contains("Dictation polish requires a loopback destination"))
        XCTAssertTrue(receipt.contains("global receipts require bounded local dictation metadata"))
        XCTAssertTrue(migration.contains("registerMigration(\"v59\")"))
        XCTAssertTrue(journal.contains("operation = 'dictation-polish'"))
    }
}
