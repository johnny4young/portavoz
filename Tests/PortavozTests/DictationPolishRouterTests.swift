import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore
@testable import portavoz_app
import XCTest

final class DictationPolishRouterTests: XCTestCase {
    func testSelectedEngineIsReadOnEveryCall() async throws {
        let selected = EngineSelectionBox(.ollama)
        let router = makeRouter(selected: selected)

        let first = try await router.polish("hola")
        selected.engine = .mlx
        let second = try await router.polish("hola")
        selected.engine = .appleOnDevice
        let third = try await router.polish("hola")

        XCTAssertEqual([first, second, third], ["ollama", "mlx", "apple"])
    }

    func testUnconfiguredOllamaNeverFallsThroughToAnotherEngine() async {
        let router = makeRouter(selected: EngineSelectionBox(.ollama), ollamaModel: nil)

        await assertUnavailable(
            router, "Choose an Ollama model in Intelligence Settings to polish dictations.")
    }

    func testNonLoopbackOllamaEndpointIsRefusedBeforeAnyRequest() async {
        let built = BuildCounter()
        let router = makeRouter(
            selected: EngineSelectionBox(.ollama),
            ollamaEndpoint: URL(string: "http://192.168.1.20:11434/v1")!,
            built: built)

        await assertUnavailable(router, "Polish only uses Ollama on this Mac.")
        XCTAssertEqual(built.count, 0)
    }

    func testMissingMLXDownloadNeverFallsThroughToApple() async {
        let router = makeRouter(selected: EngineSelectionBox(.mlx), mlxDirectory: nil)

        await assertUnavailable(
            router, "Download the built-in model in Intelligence Settings to polish dictations.")
    }

    func testMLXAdmissionConflictBecomesUnavailable() async {
        let router = makeRouter(
            selected: EngineSelectionBox(.mlx),
            mlx: ThrowingPolisher(error: AppResourceGovernorAdmissionError.activeCaptureModelConflict))

        await assertUnavailable(
            router, "Finish the recording before starting another large on-device AI task.")
    }

    func testMLXBusyRuntimeBecomesUnavailable() async {
        let router = makeRouter(
            selected: EngineSelectionBox(.mlx),
            mlx: ThrowingPolisher(error: AppServices.MLXRuntimeError.modelInUse))

        await assertUnavailable(router, "The built-in model is busy. Try again in a moment.")
    }

    func testUnreachableOllamaBecomesUnavailable() async {
        let router = makeRouter(
            selected: EngineSelectionBox(.ollama),
            ollama: ThrowingPolisher(error: URLError(.cannotConnectToHost)))

        await assertUnavailable(
            router, "Ollama is not responding on localhost:11434. Install it and run “ollama serve”.")
    }

    func testAppleCapabilityGapsStayExplicit() async {
        await assertUnavailable(
            makeRouter(selected: EngineSelectionBox(.appleOnDevice), capability: .requiresMacOS26),
            "Polish needs Apple Intelligence on macOS 26.")
        await assertUnavailable(
            makeRouter(selected: EngineSelectionBox(.appleOnDevice), capability: .unavailable("it is off")),
            "Apple Intelligence is unavailable: it is off.")
    }

    func testCancellationAndGenerationFailuresPassThrough() async {
        let cancelled = makeRouter(
            selected: EngineSelectionBox(.mlx), mlx: ThrowingPolisher(error: CancellationError()))
        do {
            _ = try await cancelled.polish("hola")
            XCTFail("cancellation must surface")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let failed = makeRouter(
            selected: EngineSelectionBox(.ollama),
            ollama: ThrowingPolisher(error: IntelligenceError.providerFailed("HTTP 500")))
        do {
            _ = try await failed.polish("hola")
            XCTFail("a generation failure must surface")
        } catch {
            XCTAssertFalse(error is DictationPolishUnavailable)
        }
    }

    func testMissingServicesAreUnavailable() async {
        let router = AppDictationPolishRouter(
            selection: { nil },
            mlxModelDirectory: { nil },
            makeApple: { nil },
            makeOllama: { _, _ in FixedPolisher(text: "ollama") },
            makeMLX: { _ in FixedPolisher(text: "mlx") })

        await assertUnavailable(router, "Polish is unavailable right now.")
    }

    private func makeRouter(
        selected: EngineSelectionBox,
        ollamaModel: String? = "qwen-local",
        ollamaEndpoint: URL = OllamaService.openAIEndpoint,
        capability: FoundationModelsCapability = .available,
        mlxDirectory: URL? = URL(fileURLWithPath: "/verified/qwen"),
        ollama: any DictationTextPolishing = FixedPolisher(text: "ollama"),
        mlx: any DictationTextPolishing = FixedPolisher(text: "mlx"),
        built: BuildCounter = BuildCounter()
    ) -> AppDictationPolishRouter {
        AppDictationPolishRouter(
            selection: {
                AppDictationPolishSelection(
                    engine: selected.engine,
                    ollamaModel: ollamaModel,
                    ollamaEndpoint: ollamaEndpoint,
                    foundationModelsCapability: capability)
            },
            mlxModelDirectory: { mlxDirectory },
            makeApple: { FixedPolisher(text: "apple") },
            makeOllama: { endpoint, model in
                built.increment()
                XCTAssertEqual(endpoint, ollamaEndpoint)
                XCTAssertEqual(model, ollamaModel)
                return ollama
            },
            makeMLX: { directory in
                XCTAssertEqual(directory, mlxDirectory)
                return mlx
            })
    }

    private func assertUnavailable(
        _ router: AppDictationPolishRouter,
        _ reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await router.polish("hola qué tal")
            XCTFail("expected unavailable", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? DictationPolishUnavailable,
                DictationPolishUnavailable(reason: reason),
                file: file,
                line: line)
        }
    }
}

private final class EngineSelectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SummaryEngine

    init(_ engine: SummaryEngine) { value = engine }

    var engine: SummaryEngine {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private struct FixedPolisher: DictationTextPolishing {
    let text: String
    func polish(_: String) async throws -> String { text }
}

private struct ThrowingPolisher: DictationTextPolishing {
    let error: any Error
    func polish(_: String) async throws -> String { throw error }
}
