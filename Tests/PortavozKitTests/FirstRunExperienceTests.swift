import ApplicationKit
import XCTest

final class FirstRunExperienceTests: XCTestCase {
    func testForcedPresentationWinsWithoutReadingLibrary() async throws {
        let library = FirstRunLibraryFake(.value(true))
        let useCase = ResolveFirstRunExperience(library: library)

        let result = try await useCase(.init(
            forcePresentation: true,
            suppressForDisposableStore: true,
            hasCompleted: true))

        XCTAssertTrue(result.shouldPresent)
        XCTAssertFalse(result.shouldMarkCompleted)
        let calls = await library.calls
        XCTAssertEqual(calls, 0)
    }

    func testAutomationAndCompletionSuppressWithoutReadingLibrary() async throws {
        for request in [
            ResolveFirstRunExperience.Request(
                forcePresentation: false,
                suppressForDisposableStore: true,
                hasCompleted: false),
            ResolveFirstRunExperience.Request(
                forcePresentation: false,
                suppressForDisposableStore: false,
                hasCompleted: true),
        ] {
            let library = FirstRunLibraryFake(.value(false))
            let result = try await ResolveFirstRunExperience(library: library)(request)
            XCTAssertFalse(result.shouldPresent)
            XCTAssertFalse(result.shouldMarkCompleted)
            let calls = await library.calls
            XCTAssertEqual(calls, 0)
        }
    }

    func testExistingLibrarySuppressesAndPersistsCompletion() async throws {
        let library = FirstRunLibraryFake(.value(true))
        let result = try await ResolveFirstRunExperience(library: library)(.init(
            forcePresentation: false,
            suppressForDisposableStore: false,
            hasCompleted: false))

        XCTAssertFalse(result.shouldPresent)
        XCTAssertTrue(result.shouldMarkCompleted)
        let calls = await library.calls
        XCTAssertEqual(calls, 1)
    }

    func testCleanLibraryAndReadFailureBothKeepGuidanceAvailable() async throws {
        for scenario in [FirstRunLibraryFake.Scenario.value(false), .failure] {
            let result = try await ResolveFirstRunExperience(
                library: FirstRunLibraryFake(scenario))(.init(
                    forcePresentation: false,
                    suppressForDisposableStore: false,
                    hasCompleted: false))
            XCTAssertTrue(result.shouldPresent)
            XCTAssertFalse(result.shouldMarkCompleted)
        }
    }

    func testCancellationRemainsCancellation() async {
        do {
            _ = try await ResolveFirstRunExperience(
                library: FirstRunLibraryFake(.cancelled))(.init(
                    forcePresentation: false,
                    suppressForDisposableStore: false,
                    hasCompleted: false))
            XCTFail("cancellation must propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private actor FirstRunLibraryFake: FirstRunLibraryReading {
    enum Scenario: Sendable {
        case value(Bool)
        case failure
        case cancelled
    }

    private(set) var calls = 0
    private let scenario: Scenario

    init(_ scenario: Scenario) {
        self.scenario = scenario
    }

    func containsMeetings() throws -> Bool {
        calls += 1
        switch scenario {
        case .value(let value): return value
        case .failure: throw FirstRunFakeError.expected
        case .cancelled: throw CancellationError()
        }
    }
}

private enum FirstRunFakeError: Error {
    case expected
}
