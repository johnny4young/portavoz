import XCTest

@testable import TranscriptionKit

/// The one-shot CPU degradation that keeps refine working when the
/// accelerator cannot create a context.
final class AcceleratorFallbackTests: XCTestCase {
    private struct Boom: Error, Equatable { let label: String }

    func testPrimarySuccessNeverTouchesTheFallback() async throws {
        nonisolated(unsafe) var fallbackRan = false
        let value = try await AcceleratorFallback.run {
            "accelerated"
        } cpuFallback: {
            fallbackRan = true
            return "cpu"
        }
        XCTAssertEqual(value, "accelerated")
        XCTAssertFalse(fallbackRan, "a healthy load must not pay for a second one")
    }

    func testPrimaryFailureDegradesOnceToTheCPU() async throws {
        let value = try await AcceleratorFallback.run {
            throw Boom(label: "metal")
        } cpuFallback: {
            "cpu"
        }
        XCTAssertEqual(value, "cpu")
    }

    func testBothFailuresSurfaceBothCauses() async {
        do {
            let _: String = try await AcceleratorFallback.run {
                throw Boom(label: "metal")
            } cpuFallback: {
                throw Boom(label: "cpu")
            }
            XCTFail("both attempts failing must throw")
        } catch let error as AcceleratorFallbackError {
            XCTAssertEqual(error.primary as? Boom, Boom(label: "metal"))
            XCTAssertEqual(error.fallback as? Boom, Boom(label: "cpu"))
            XCTAssertTrue(error.localizedDescription.contains("accelerator"))
        } catch {
            XCTFail("expected the typed dual-cause error, got \(error)")
        }
    }

    func testCancellationNeverTriggersTheFallback() async {
        nonisolated(unsafe) var fallbackRan = false
        do {
            let _: String = try await AcceleratorFallback.run {
                throw CancellationError()
            } cpuFallback: {
                fallbackRan = true
                return "cpu"
            }
            XCTFail("cancellation must propagate")
        } catch is CancellationError {
            XCTAssertFalse(fallbackRan, "a user cancel must not start a slower load")
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}
