import Foundation
import PortavozCore
import StorageKit
import XCTest

@testable import portavoz_app

final class DictationIntentTests: XCTestCase {
    @MainActor
    func testDictationRequestsAreAnsweredDuringThePostAndNeverReplayed() async throws {
        XCTAssertEqual(PortavozAppIntentBridge.requestDictation(.toggle), .notReady, "nobody listening yet")
        XCTAssertNil(PortavozAppIntentBridge.consumeDictationRequest(), "a late dictation must not start after launch")

        let observer = NotificationCenter.default.addObserver(
            forName: PortavozAppIntentBridge.dictationRequested, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                if PortavozAppIntentBridge.consumeDictationRequest() == .pasteLast {
                    PortavozAppIntentBridge.answerDictationRequest(.nothingToPaste)
                } else {
                    PortavozAppIntentBridge.answerDictationRequest(.accepted)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = try await DictateIntent().perform()
        do {
            _ = try await PasteLastDictationIntent().perform()
            XCTFail("an empty paste must say so")
        } catch {
            XCTAssertEqual(error as? PortavozDictationIntentError, .nothingToPaste)
        }
    }

    @MainActor
    func testOutcomesFollowTheDictationSettingAndPhase() async {
        func outcome(
            _ request: PortavozAppIntentBridge.DictationRequest, enabled: Bool = true,
            phase: DictationController.Phase = .idle, pastable: Bool = true
        ) -> PortavozAppIntentBridge.DictationRequestOutcome {
            PortavozAppDelegate.dictationIntentOutcome(
                for: request, dictationEnabled: enabled, phase: phase, hasPastableText: pastable)
        }
        XCTAssertEqual(outcome(.toggle, enabled: false), .dictationOff)
        XCTAssertEqual(outcome(.pasteLast, enabled: false), .dictationOff)
        XCTAssertEqual(outcome(.toggle), .accepted)
        XCTAssertEqual(outcome(.toggle, phase: .listening), .accepted, "a second run finishes the dictation")
        XCTAssertEqual(outcome(.toggle, phase: .delivering), .busy)
        XCTAssertEqual(outcome(.pasteLast, phase: .listening), .busy)
        XCTAssertEqual(outcome(.pasteLast, pastable: false), .nothingToPaste)
        XCTAssertEqual(outcome(.pasteLast), .accepted)
    }

    @MainActor
    func testOpenDictationsRoutesWithItsSearch() async throws {
        _ = PortavozAppIntentBridge.consumeNavigationRequest()
        let intent = OpenDictationsIntent()
        intent.search = "  informe  "
        _ = try await intent.perform()

        let request = PortavozAppIntentBridge.consumeNavigationRequest()
        XCTAssertEqual(request, .dictations("informe"))
        XCTAssertEqual(PortavozAppDelegate.route(for: .dictations("informe")), .dictations)
    }

    func testSearchReadsOnlyWhileTheHistoryIsSharedWithAgentsAndShortcuts() async throws {
        let store = try MeetingStore.inMemory()
        let now = Date()
        _ = try await store.setDictationHistoryPolicy(
            isEnabled: true, keepsOriginal: false, retentionDays: 30, exposesToAgents: false, at: now)
        for (offset, text) in ["Send the report on Friday.", "No borres estas notas."].enumerated() {
            _ = try await store.recordDictation(
                DictationRecord(
                    id: DictationRecordID(), createdAt: now.addingTimeInterval(Double(offset)), duration: 1,
                    text: text, originalText: nil, mode: .literal, language: nil, engine: "parakeet",
                    applicationName: "Slack", applicationBundleID: nil, delivery: .verified),
                admittedGeneration: 0, at: now)
        }
        let reader = AppDictationIntentReader(store: store)

        do {
            _ = try await PortavozDictationSearchAction.search("report", limit: 10, reader: reader)
            XCTFail("an unshared history returns nothing")
        } catch {
            XCTAssertEqual(error as? PortavozDictationIntentError, .notShared)
        }

        _ = try await store.setDictationHistoryPolicy(
            isEnabled: true, keepsOriginal: false, retentionDays: 30, exposesToAgents: true, at: now)
        let found = try await PortavozDictationSearchAction.search("  report ", limit: 10, reader: reader)
        let newest = try await PortavozDictationSearchAction.search("", limit: 1, reader: reader)
        XCTAssertEqual(found, ["Send the report on Friday."])
        XCTAssertEqual(newest, ["No borres estas notas."])
    }

    @MainActor
    func testASearchFromAShortcutReplacesOtherHistoryFilters() async throws {
        let model = DictationHistoryModel(store: try MeetingStore.inMemory())
        model.focus(on: DictationRecordID())
        model.show(search: "report")
        XCTAssertEqual(model.filter, DictationRecordFilter(query: "report"))
    }
}
