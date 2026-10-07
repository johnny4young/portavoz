import Foundation
import XCTest

@testable import portavoz_app

final class OnboardingModelPreparationTests: XCTestCase {
    @MainActor
    func testFailedPreparationIsVisibleAndRetryReplacesFailureWithReady() async {
        let model = OnboardingModelPreparation()
        await model.prepare { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(model.phase, .failed(.network))
        XCTAssertEqual(model.attempt, 1)
        await model.prepare {
            XCTAssertEqual(model.phase, .preparing)
        }
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.attempt, 2)
        await model.prepare { XCTFail("ready models must not prepare again") }
        XCTAssertEqual(model.attempt, 2)
    }

    @MainActor
    func testRepeatedAdmissionWhilePreparingDoesNotStartAnotherLoad() async {
        let model = OnboardingModelPreparation()
        await model.prepare {
            await model.prepare { XCTFail("preparation is already in flight") }
            XCTAssertEqual(model.phase, .preparing)
            XCTAssertEqual(model.attempt, 1)
        }
        XCTAssertEqual(model.phase, .ready)
    }

    @MainActor
    func testFailuresUseClosedCategoriesAndNeverExposeDescriptions() async {
        let cases: [(any Error, OnboardingModelPreparation.Failure)] = [
            (URLError(.timedOut), .network),
            (URLError(.cannotWriteToFile), .unavailable),
            (URLError(.cancelled), .cancelled),
            (CancellationError(), .cancelled),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), .storage),
            (NSError(domain: "private.invalid", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "secret-token /private/model/path https://private.invalid"
            ]), .unavailable)
        ]
        for (error, expected) in cases {
            let model = OnboardingModelPreparation()
            await model.prepare { throw error }
            XCTAssertEqual(model.phase, .failed(expected))
            XCTAssertFalse(expected.message.contains("secret-token"))
            XCTAssertFalse(expected.message.contains("/private/"))
            XCTAssertFalse(expected.message.contains("https://"))
        }
    }

    @MainActor
    func testFixtureRequiresDisposableStoreAndNeverCallsRealPreparation() throws {
        let flag = "-simulate-onboarding-model-recovery"
        XCTAssertNil(OnboardingModelPreparation.disposableFixtureResult(arguments: [flag], attempt: 1))
        XCTAssertNil(OnboardingModelPreparation.disposableFixtureResult(arguments: ["-use-temp-store"], attempt: 1))
        let arguments = ["-use-temp-store", flag]
        let first = try XCTUnwrap(OnboardingModelPreparation.disposableFixtureResult(arguments: arguments, attempt: 1))
        XCTAssertThrowsError(try first.get()) { error in
            XCTAssertEqual(OnboardingModelPreparation.Failure.classify(error), .network)
        }
        let second = try XCTUnwrap(OnboardingModelPreparation.disposableFixtureResult(arguments: arguments, attempt: 2))
        XCTAssertNoThrow(try second.get())
    }
}
