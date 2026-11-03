import XCTest
@testable import IntelligenceKit

/// A resource bundle that only its builder can read must disable one optional
/// feature, never end the app: the generated SwiftPM accessor traps instead.
final class IntelligenceResourceBundleTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/Applications/Portavoz.app/Contents/Resources")

    func testStagedLocationsAreSearchedBeforeTheBuildDirectory() {
        let container = URL(fileURLWithPath: "/tmp/container")
        let main = URL(fileURLWithPath: "/Applications/Portavoz.app")
        let candidates = IntelligenceResourceBundle.candidateURLs(
            mainResources: base,
            mainBundle: main,
            moduleResources: nil,
            moduleContainer: container,
            executableDirectory: main.appendingPathComponent("Contents/MacOS"))
        XCTAssertEqual(candidates.map(\.path), [
            base.path + "/Portavoz_IntelligenceKit.bundle",
            main.path + "/Portavoz_IntelligenceKit.bundle",
            container.path + "/Portavoz_IntelligenceKit.bundle",
            main.path + "/Contents/MacOS/Portavoz_IntelligenceKit.bundle",
        ], "the packaged Contents/Resources staging must be consulted first")
        XCTAssertEqual(
            IntelligenceResourceBundle.candidateURLs(
                mainResources: nil, mainBundle: main, moduleResources: nil,
                moduleContainer: nil, executableDirectory: nil).count,
            1,
            "an absent search root contributes no candidate")
        XCTAssertEqual(
            IntelligenceResourceBundle.candidateURLs(
                mainResources: base, mainBundle: base, moduleResources: base,
                moduleContainer: base, executableDirectory: base).count,
            1,
            "a repeated root is probed once")
    }

    func testUnreadableBundleResolvesToNilInsteadOfTrapping() {
        let attempted = LockedPaths()
        let resolved = IntelligenceResourceBundle.resolve(
            candidates: IntelligenceResourceBundle.candidateURLs(
                mainResources: base, mainBundle: nil, moduleResources: nil,
                moduleContainer: nil, executableDirectory: nil),
            load: { url in
                attempted.append(url.path)
                return nil  // Exactly what `Bundle(url:)` reports for a 0700 payload.
            })
        XCTAssertNil(resolved)
        XCTAssertEqual(attempted.paths.count, 1)
    }

    func testResolutionStopsAtTheFirstReadableCandidate() {
        let attempted = LockedPaths()
        let readable = Bundle(for: IntelligenceResourceBundleTests.self)
        let resolved = IntelligenceResourceBundle.resolve(
            candidates: IntelligenceResourceBundle.candidateURLs(
                mainResources: base,
                mainBundle: URL(fileURLWithPath: "/Applications/Portavoz.app"),
                moduleResources: URL(fileURLWithPath: "/tmp/container"),
                moduleContainer: nil,
                executableDirectory: nil),
            load: { url in
                attempted.append(url.path)
                return attempted.paths.count == 2 ? readable : nil
            })
        XCTAssertIdentical(resolved, readable)
        XCTAssertEqual(attempted.paths.count, 2, "later candidates are not consulted")
    }

    func testTheRealModuleResourcesStillResolveInThisBuild() throws {
        let bundle = try XCTUnwrap(
            IntelligenceResourceBundle.resolved,
            "the shipped classifier must still be found through the non-trapping lookup")
        XCTAssertNotNil(bundle.url(
            forResource: "PortavozLiveQuestionClassifier", withExtension: "mlmodelc"))
        XCTAssertTrue(BundledLiveQuestionDetector.resourceIsPresent)
    }

    func testDetectorWithoutAModelReportsUnavailableRatherThanCrashing() async {
        let detector = BundledLiveQuestionDetector(model: nil)
        do {
            _ = try await detector.detect(candidate: "¿Quién cierra el rollout?", ownerName: nil)
            XCTFail("a missing model must surface as an explicit unavailable error")
        } catch let error as LiveQuestionDetectorError {
            XCTAssertEqual(error, .modelUnavailable)
        } catch {
            XCTFail("unexpected error: \(type(of: error))")
        }
    }
}

private final class LockedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(path)
    }
}
