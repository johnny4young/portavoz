import AVFoundation
import Foundation
import XCTest
@testable import AudioPlaybackKit

final class AudioExportSessionTests: XCTestCase {
    func testLegacyCompletionAcceptsOnlyCompletedAndPreservesCallerErrorFamilies() throws {
        let nativeError = NSError(domain: "ExportFixture", code: 7,
                                  userInfo: [NSLocalizedDescriptionKey: "fixture failure"])
        // Completed was authoritative in all three original call sites, even if an error exists.
        try AudioExportSession.requireLegacyCompletion(
            status: .completed, error: nativeError, failure: AudioClipExporter.ClipError.exportFailed)
        for status in [AVAssetExportSession.Status.unknown, .waiting, .exporting, .failed, .cancelled] {
            for error in [nil, nativeError] {
                let reason = error == nil ? "unknown" : "fixture failure"
                XCTAssertThrowsError(try AudioExportSession.requireLegacyCompletion(
                    status: status, error: error, failure: AudioClipExporter.ClipError.exportFailed)) { thrown in
                    guard case AudioClipExporter.ClipError.exportFailed(let message) = thrown else {
                        return XCTFail("the clip caller must keep its own failure type")
                    }
                    XCTAssertEqual(message, reason)
                }
                XCTAssertThrowsError(try AudioExportSession.requireLegacyCompletion(
                    status: status, error: error, failure: AudioTranscoder.TranscodeError.exportFailed)) { thrown in
                    guard case AudioTranscoder.TranscodeError.exportFailed(let message) = thrown else {
                        return XCTFail("the compression caller must keep its own failure type")
                    }
                    XCTAssertEqual(message, reason)
                }
            }
        }
    }

    func testLegacyCallbackMayCompleteSynchronously() async {
        await AudioExportSession.waitForLegacyCompletion { completion in completion() }
    }

    func testLegacyWaitRetainsCallbackOwnershipAfterCancellation() async {
        let callback = LegacyExportCallback()
        let task = Task {
            await AudioExportSession.waitForLegacyCompletion { completion in callback.install(completion) }
            callback.recordReturn()
        }
        await callback.waitUntilInstalled()
        task.cancel()
        XCTAssertFalse(callback.hasReturned)
        callback.complete()
        await task.value
        XCTAssertTrue(callback.hasReturned)
        XCTAssertTrue(callback.returnedAfterCompletion,
                      "the wait must not return before the native callback fires")
    }

    func testAlreadyCancelledLegacyWaitStillDrainsItsCallback() async {
        let callback = LegacyExportCallback()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await AudioExportSession.waitForLegacyCompletion { completion in callback.install(completion) }
            callback.recordReturn()
        }
        await callback.waitUntilInstalled()
        XCTAssertFalse(callback.hasReturned)
        callback.complete()
        await task.value
        XCTAssertTrue(callback.hasReturned)
        XCTAssertTrue(callback.returnedAfterCompletion,
                      "the wait must not return before the native callback fires")
    }
}

/// A lock-owned fake native callback, never a process-wide export or real user file.
private final class LegacyExportCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable () -> Void)?
    private var installed = false
    private var returned = false
    private var delivered = false
    private var deliveredBeforeReturn = false
    private var installationWaiter: CheckedContinuation<Void, Never>?

    var hasReturned: Bool { lock.withLock { returned } }
    var returnedAfterCompletion: Bool { lock.withLock { deliveredBeforeReturn } }

    func install(_ completion: @escaping @Sendable () -> Void) {
        let waiter = lock.withLock {
            self.completion = completion
            installed = true
            let waiter = installationWaiter
            installationWaiter = nil
            return waiter
        }
        waiter?.resume()
    }

    func waitUntilInstalled() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if installed { return true }
                installationWaiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func complete() {
        let completion = lock.withLock {
            let value = self.completion
            self.completion = nil
            delivered = true
            return value
        }
        completion?()
    }

    func recordReturn() {
        lock.withLock {
            returned = true
            deliveredBeforeReturn = delivered
        }
    }
}
