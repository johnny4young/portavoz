import AppKit
import ApplicationServices
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class TextInsertionReadbackTests: XCTestCase {
    func testActualInserterVerifiesOnlyExactInsertedUTF16Span() async {
        for text in ["Don’t delete: 1.250,50 €", "No borres el cafe\u{301} 👩🏽‍💻", "\nC++ — $1\\\n"] {
            let receiver = TextReadbackHarness()
            defer { receiver.board.releaseGlobally() }
            let result = await receiver.insert(text)
            XCTAssertEqual(result, .verified)
            XCTAssertEqual(receiver.posts, 1)
            XCTAssertEqual(receiver.requestedSpans, [NSRange(location: 7, length: text.utf16.count)])
            XCTAssertEqual(receiver.document, "Before " + text + " after")
            XCTAssertEqual(receiver.board.string(forType: .string), text)
        }
    }

    func testNoAcknowledgementNeverRetriesAndCannotClaimSuccess() async {
        for mode in ["unsupported", "noop", "wrong-text", "wrong-caret", "focus-changed", "read-unavailable", "metadata-unavailable"] {
            let receiver = TextReadbackHarness()
            defer { receiver.board.releaseGlobally() }
            switch mode {
            case "unsupported": receiver.readbackAvailable = false
            case "noop": receiver.appliesPaste = false
            case "wrong-text": receiver.readOverride = { _ in "Do delete." }
            case "wrong-caret": receiver.afterPost = { receiver.selection.location = 0 }
            case "focus-changed": receiver.afterPost = { receiver.targetFailure = .targetChanged }
            case "metadata-unavailable": receiver.afterPost = { receiver.positionOverride = { nil } }
            default: receiver.readOverride = { _ in nil }
            }
            let result = await receiver.insert("No delete.")
            XCTAssertEqual(result, .dispatched, mode)
            XCTAssertEqual(receiver.posts, 1, mode)
            if ["unsupported", "noop", "wrong-caret", "focus-changed"].contains(mode) {
                XCTAssertTrue(receiver.requestedSpans.isEmpty, "Never inspect an unrelated span")
            }
        }
    }

    func testMalformedMetadataAndReadLimitNeverTruncateOrBroadenReads() async {
        let invalid: [DictationTextReadback.Position] = [
            .init(selection: NSRange(location: -1, length: 0), characterCount: 10),
            .init(selection: NSRange(location: NSNotFound, length: 0), characterCount: .max),
            .init(selection: NSRange(location: 0, length: -1), characterCount: 10),
            .init(selection: NSRange(location: 0, length: 0), characterCount: -1),
            .init(selection: NSRange(location: 10, length: 1), characterCount: 10),
            .init(selection: NSRange(location: Int.max - 1, length: 0), characterCount: .max)
        ]
        for position in invalid {
            let receiver = TextReadbackHarness()
            defer { receiver.board.releaseGlobally() }
            receiver.positionOverride = { position }
            let result = await receiver.insert("Never truncate")
            XCTAssertEqual(result, .dispatched)
            XCTAssertEqual(receiver.posts, 1)
            XCTAssertTrue(receiver.requestedSpans.isEmpty)
        }
        for length in [16_384, 16_385] {
            let receiver = TextReadbackHarness()
            defer { receiver.board.releaseGlobally() }
            let text = String(repeating: "a", count: length)
            let result = await receiver.insert(text)
            XCTAssertEqual(result, length == 16_384 ? .verified : .dispatched)
            XCTAssertEqual(receiver.board.string(forType: .string), text)
            XCTAssertEqual(receiver.requestedSpans.count, length == 16_384 ? 1 : 0)
        }
    }

    func testSelectionChangedDuringFinalValidationRefusesBeforePost() async {
        let receiver = TextReadbackHarness()
        defer { receiver.board.releaseGlobally() }
        let original = receiver.board.string(forType: .string)
        receiver.onValidate = { count in if count == 2 { receiver.selection.location += 1 } }
        let result = await receiver.insert("No borres")
        XCTAssertEqual(result, .refused(.targetChanged))
        XCTAssertEqual(receiver.posts, 0)
        XCTAssertEqual(receiver.board.string(forType: .string), original)
    }

    func testLostReadableMetadataBeforePostingRefusesInsteadOfGuessing() async {
        let receiver = TextReadbackHarness()
        defer { receiver.board.releaseGlobally() }
        var reads = 0
        receiver.positionOverride = {
            reads += 1
            return reads == 1 ? .init(selection: receiver.selection, characterCount: receiver.document.utf16.count) : nil
        }
        let result = await receiver.insert("No borres")
        XCTAssertEqual(result, .refused(.focusUnavailable))
        XCTAssertEqual(receiver.posts, 0)
        XCTAssertEqual(receiver.board.string(forType: .string), "Original clipboard")
    }

    func testMetadataInspectionCannotReadTextAfterAFieldBecomesSecure() async {
        let receiver = TextReadbackHarness()
        defer { receiver.board.releaseGlobally() }
        receiver.positionOverride = {
            if receiver.posts > 0 { receiver.targetFailure = .secureField }
            return .init(selection: receiver.selection, characterCount: receiver.document.utf16.count)
        }
        let result = await receiver.insert("Don't delete")
        XCTAssertEqual(result, .dispatched)
        XCTAssertEqual(receiver.posts, 1)
        XCTAssertTrue(receiver.requestedSpans.isEmpty,
                      "Rejection after reading private text is too late; metadata can service a security transition")
    }

    func testClipboardSnapshotFollowsTheBaselineAXCallThatMayServiceANewOwner() async {
        let receiver = TextReadbackHarness()
        defer { receiver.board.releaseGlobally() }
        var reads = 0
        receiver.positionOverride = {
            reads += 1
            if reads == 1 {
                receiver.board.clearContents()
                receiver.board.setString("New clipboard owner", forType: .string)
                return .init(selection: receiver.selection, characterCount: receiver.document.utf16.count)
            }
            return nil
        }
        let result = await receiver.insert("No borres")
        XCTAssertEqual(result, .refused(.focusUnavailable))
        XCTAssertEqual(receiver.posts, 0)
        XCTAssertEqual(receiver.board.string(forType: .string), "New clipboard owner")
    }

    func testCancelledReadbackOrChangedPositionAfterReadStaysDispatched() async {
        for cancelDuringRead in [false, true] {
            let receiver = TextReadbackHarness()
            defer { receiver.board.releaseGlobally() }
            var task: Task<DictationDeliveryOutcome, Never>?
            receiver.readOverride = { _ in
                if cancelDuringRead { task?.cancel() } else { receiver.selection.location = 0 }
                return "Don't delete"
            }
            task = Task { await receiver.insert("Don't delete") }
            let result = await task?.value
            task = nil
            XCTAssertEqual(result, .dispatched)
            XCTAssertEqual(receiver.posts, 1)
            XCTAssertEqual(receiver.document, "Before Don't delete after", "Cancellation cannot undo an already posted edit")
        }
    }

    func testCanonicalEquivalenceIsNotExactLiteralDelivery() async {
        let receiver = TextReadbackHarness()
        defer { receiver.board.releaseGlobally() }
        receiver.readOverride = { _ in "café" }
        let result = await receiver.insert("cafe\u{301}")
        XCTAssertEqual(result, .dispatched)
        XCTAssertEqual(receiver.posts, 1)
    }

    func testEmptyInsertionCannotEraseExternalSelection() async {
        let receiver = TextReadbackHarness()
        defer { receiver.board.releaseGlobally() }
        let count = receiver.board.changeCount
        let result = await receiver.insert("")
        XCTAssertEqual(result, .refused(.emptyText))
        XCTAssertEqual(receiver.posts, 0)
        XCTAssertEqual(receiver.board.changeCount, count)
        XCTAssertEqual(receiver.document, "Before 📝 after")
    }

    func testCancellationInBaselineDoesNotBorrowClipboard() async {
        let receiver = TextReadbackHarness()
        defer { receiver.board.releaseGlobally() }
        let count = receiver.board.changeCount
        var task: Task<DictationDeliveryOutcome, Never>?
        receiver.positionOverride = {
            task?.cancel()
            return .init(selection: receiver.selection, characterCount: receiver.document.utf16.count)
        }
        task = Task { await receiver.insert("Don't delete") }
        let result = await task?.value
        task = nil
        XCTAssertEqual(result, .refused(.cancelled))
        XCTAssertEqual(receiver.posts, 0)
        XCTAssertEqual(receiver.board.changeCount, count)
    }

    func testLateMatchingReadIsNotVerifiedAfterItsDeadline() async {
        let receiver = TextReadbackHarness()
        defer { receiver.board.releaseGlobally() }
        receiver.readOverride = { _ in
            receiver.clock = receiver.clock.advanced(by: .seconds(1))
            return "No borres"
        }
        let result = await receiver.insert("No borres")
        XCTAssertEqual(result, .dispatched)
        XCTAssertEqual(receiver.posts, 1)
    }

    func testAXCountsRejectWrongTypesAndLossyNumericConversions() async {
        for value: AnyObject in [NSNumber(value: true), "3" as NSString, NSNumber(value: -1),
                                NSNumber(value: 1.5), NSNumber(value: Double.nan),
                                NSNumber(value: Double.infinity), NSNumber(value: Double(Int.max)), NSNumber(value: UInt64.max)] {
            XCTAssertNil(DictationTextReadback.characterCount(value), "Synthetic numeric boundary: \(value)")
        }
        for count in [0, 1, Int.max] {
            XCTAssertEqual(DictationTextReadback.characterCount(NSNumber(value: count)), count)
        }
        XCTAssertNil(TextInserter.checkedCFValue("not an AX range" as CFString, as: .accessibilityValue))
    }
}

/// Deterministic receiver behind the real inserter. This does not grant AX or
/// post a native event; the separate app receiver remains the native oracle.
@MainActor
final class TextReadbackHarness {
    let board = NSPasteboard(name: .init("app.portavoz.dictation-test." + UUID().uuidString))
    var document = "Before 📝 after"
    var selection = NSRange(location: 7, length: 2)
    var posts = 0
    var validations = 0
    var requestedSpans: [NSRange] = []
    var readbackAvailable = true
    var appliesPaste = true
    var targetFailure: DictationDeliveryOutcome.Refusal?
    var afterPost: (() -> Void)?
    var onValidate: ((Int) -> Void)?
    var positionOverride: (() -> DictationTextReadback.Position?)?
    var readOverride: ((NSRange) -> String?)?
    var clock = ContinuousClock.now

    init() { board.setString("Original clipboard", forType: .string) }

    func insert(_ text: String) async -> DictationDeliveryOutcome {
        let readback = DictationTextReadback(position: { [self] in
            if let positionOverride { return positionOverride() }
            return .init(selection: selection, characterCount: document.utf16.count)
        }, string: { [self] span in
            requestedSpans.append(span)
            if let readOverride { return readOverride(span) }
            return (document as NSString).substring(with: span)
        }, now: { [self] in clock }, pause: { [self] in clock = clock.advanced(by: .milliseconds(25)) })
        let target = TextInserter.Target(processID: 101, readback: readbackAvailable ? readback : nil) { [self] in
            validations += 1
            onValidate?(validations)
            return targetFailure
        }
        return await TextInserter.insert(text, into: target, pasteboard: board,
            effects: .init(waitForModifiers: { true }, post: { [self] _ in
                posts += 1
                if appliesPaste {
                    document = (document as NSString).replacingCharacters(in: selection, with: text)
                    selection = NSRange(location: selection.location + text.utf16.count, length: 0)
                }
                afterPost?()
                return true
            }))
    }
}
