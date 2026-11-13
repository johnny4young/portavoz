import Foundation
import XCTest

extension ArchitectureDependencyTests {
    // Dictation lives in Secreteo; Portavoz keeps only what a 1.x library needs.
    func testNoDictationRuntimeRemains() throws {
        let app = try XCTUnwrap(FileManager.default.enumerator(
            atPath: Self.repoRoot.appendingPathComponent("Sources/portavoz-app").path))
            .compactMap { $0 as? String }
            .filter { $0.contains("Dictation") }
        XCTAssertEqual(
            app.filter { !$0.hasPrefix("LegacyDictation") }, [],
            "only the legacy retention, notice and ownership release stay in the app")

        // A 1.x library's dictation tables are touched only by the frozen migrations and the legacy facade.
        let tables = #"\b(dictationRecord|dictationRecordSearch|dictationHistoryPolicy|dictationStatsDay|"#
            + #"dictationStatsCounted|dictationStatsPolicy|dictationMeetingNote)\b"#
        XCTAssertEqual(
            try Self.uncommentedSourceMatches(under: "Sources", pattern: tables)
                .filter { !$0.hasPrefix("StorageKit/Schema/Legacy/") },
            [])

        let history = #"\b(DictationRecord|DictationHistoryPolicy|DictationRecordFilter|DictationStatsCalendar|"#
            + #"DictationStatsSample|DictationMeetingChoice)\b"#
        XCTAssertEqual(try Self.sourceMatches(under: "Sources", pattern: history, codeOnly: true), [])

        let runtime = #"DictationController|DictationOwnershipCoordinator|DictationAdmission|TextInserter|"#
            + #"GlobalHotkey|SelectionRewrite|parakeetUltra|ParakeetCheckpoint|filtersLiveScript|"#
            + #"LiveSpeechPurpose|LiveSpeechCheckpointPlan|beginDictationCapture|dictationOwners"#
        XCTAssertEqual(try Self.sourceMatches(under: "Sources", pattern: runtime, codeOnly: true), [])

        let polish = #"\b(PolishDictation|DictationPolish(Prompt|PromptError|Unavailable|Outcome|Skip)|"#
            + #"DictationTextPolishing|\w*DictationPolisher|dictationPolisher)\b"#
        XCTAssertEqual(try Self.sourceMatches(under: "Sources", pattern: polish, codeOnly: true), [])

        let text = #"\b(DictationAssembler|DictationCorrectionCommand|DictationTerm|DictationReplacement|"#
            + #"DictationPolishFidelity|DictationTextRules)\b"#
        XCTAssertEqual(try Self.sourceMatches(under: "Sources", pattern: text, codeOnly: true), [])
        XCTAssertEqual(try Self.sourceMatches(under: "Tests", pattern: text, codeOnly: true), [])

        let domain = #"\b(DictationRecipe|DictationTextChoice|DictationTextMode|DictationApplicationTextProfile|"#
            + #"DictationTranslationTarget|DictationDeliveryOutcome|DictationRecordID)\b"#
        XCTAssertEqual(try Self.sourceMatches(under: "Sources", pattern: domain, codeOnly: true), [])
        XCTAssertEqual(try Self.sourceMatches(under: "Tests", pattern: domain, codeOnly: true), [])

        let tool = try Self.contents(of: "Sources/portavoz-app/CommandLineToolSection.swift")
        XCTAssertTrue(tool.contains("PasteboardCopy.copy("))
        let bench = try Self.contents(of: "Sources/TranscriptionKit/LiveTranscriptionBench.swift")
        XCTAssertFalse(bench.contains("DictationAssembler"))
    }

    // 1.x dictation polish receipts stay readable, and no path can create a new one.
    func testDictationPolishEgressIsReadOnly() throws {
        let gateway = try Self.contents(of: "Sources/IntegrationsKit/URLSessionDataEgressGateway.swift")
        let receipt = try Self.contents(of: "Sources/StorageKit/MeetingStore+PrivacyReceipt.swift")
        let migration = try Self.contents(of: "Sources/StorageKit/Schema/Legacy/Schema+DictationPolish.swift")
        let journal = try Self.contents(of: "Sources/StorageKit/Schema+GlobalDataEgress.swift")

        XCTAssertTrue(gateway.contains(#"throw DataEgressGatewayError.invalidMetadata("Dictation polish is retired")"#))
        XCTAssertTrue(receipt.contains("guard event.operation != .dictationPolish else"))
        XCTAssertTrue(receipt.contains("global receipts require bounded local dictation metadata"))
        XCTAssertTrue(migration.contains("registerMigration(\"v59\")"))
        XCTAssertTrue(journal.contains("operation = 'dictation-polish'"))
        XCTAssertEqual(
            try Self.sourceMatches(under: "Sources", pattern: #"operation:\s*\.dictationPolish"#, codeOnly: true), [])
    }

    // String literals stay, since SQL names its tables there; whole-line and block comments go.
    private static func uncommentedSourceMatches(under relativeDirectory: String, pattern: String) throws -> [String] {
        let root = repoRoot.appendingPathComponent(relativeDirectory)
        let regex = try NSRegularExpression(pattern: pattern)
        let comments = try NSRegularExpression(pattern: #"(?m)^\s*//.*$|/\*[\s\S]*?\*/"#)
        let files = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []
        return try files.filter { $0.hasSuffix(".swift") }.sorted().filter { file in
            let contents = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let code = comments.stringByReplacingMatches(
                in: contents, range: NSRange(contents.startIndex..., in: contents), withTemplate: "")
            return regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
        }
    }
}
