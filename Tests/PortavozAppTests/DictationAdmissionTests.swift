import ApplicationKit
import Foundation
import PortavozCore
import Testing

@testable import portavoz_app
@testable import PortavozTestSupport

extension AppServices {
    /// For tests of what happens after admission, which these suites do not vary.
    func admittedDictationDependencies(capturesInstruction: Bool = true) -> DictationSessionDependencies {
        var dependencies = makeDictationSessionDependencies(capturesInstruction: capturesInstruction)
        dependencies.admission = DictationUITestFixture.openAdmission
        return dependencies
    }
}

// The controller harness overrides process-wide NSArgumentDomain.
@Suite(.serialized, .exclusiveArgumentDomain, .timeLimit(.minutes(1)))
@MainActor
struct DictationAdmissionTests {
    @MainActor
    private final class Port {
        var refuses = false
        var kinds: [DictationAdmissionKind] = []
        var released = 0
        var held: Int { kinds.count - released }

        var admission: DictationAdmission {
            DictationAdmission(
                acquire: { kind in
                    guard !self.refuses else { return .failure(.dictationOff) }
                    self.kinds.append(kind)
                    return .success(DictationLease { self.released += 1 })
                },
                isEligible: { !self.refuses })
        }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        _ = await TestPolling.until(condition)
        try #require(condition())
    }

    private func dictate(
        _ harness: DictationControllerHarness, _ dependencies: DictationSessionDependencies
    ) async throws {
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
    }

    private func dependencies(_ harness: DictationControllerHarness, _ port: Port) -> DictationSessionDependencies {
        var dependencies = harness.dependencies
        dependencies.admission = port.admission
        return dependencies
    }

    @Test
    func thePreferenceAdmitsGlobalWorkAndPracticeAlwaysRuns() throws {
        let suite = "dictation-admission-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let admission = DictationAdmission.preference(in: defaults)

        #expect(throws: DictationAdmissionRefusal.dictationOff) { try admission.acquire(.global).get() }
        #expect(!admission.isEligible())
        #expect(throws: Never.self) { try admission.acquire(.practice).get() }
        #expect(defaults.object(forKey: DictationController.defaultsKey) == nil, "A refusal writes nothing")

        defaults.set(true, forKey: DictationController.defaultsKey)
        #expect(throws: Never.self) { try admission.acquire(.global).get() }
        #expect(admission.isEligible())
    }

    @Test
    func aRefusedStartOpensNothing() async {
        let harness = DictationControllerHarness(text: "No borres estas notas.")
        let port = Port()
        port.refuses = true

        harness.controller.toggle(using: dependencies(harness, port))

        #expect(harness.controller.phase == .idle)
        #expect(harness.loads == 0)
        let starts = await harness.microphone.starts
        #expect(starts == 0)
        #expect(harness.insertions.isEmpty)
    }

    @Test
    func aReleaseAfterARefusedPressDoesNothing() {
        let harness = DictationControllerHarness(text: "No borres estas notas.")
        let port = Port()
        port.refuses = true
        let dependencies = dependencies(harness, port)

        harness.controller.handleHotkeyPress(using: dependencies, at: harness.now)
        harness.controller.handleHotkeyRelease(at: harness.now.addingTimeInterval(5))

        #expect(harness.controller.phase == .idle)
        #expect(harness.insertions.isEmpty)
    }

    @Test
    func theLeaseLastsThroughDelivery() async throws {
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        let port = Port()
        var dependencies = dependencies(harness, port)
        var heldWhileDelivering: [Int] = []
        dependencies.captureDestination = {
            CapturedDictationDestination(name: "Receiver", canRetry: false) { _ in
                heldWhileDelivering.append(port.held)
                return .verified
            }
        }

        try await dictate(harness, dependencies)

        try await eventually { heldWhileDelivering == [1] && port.held == 0 }
        #expect(port.kinds == [.global])
    }

    @Test
    func aCancelledSessionReleasesItsLease() async throws {
        let harness = DictationControllerHarness(text: "No borres estas notas.")
        let port = Port()
        let dependencies = dependencies(harness, port)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        #expect(port.held == 1)

        harness.controller.cancel()

        try await eventually { port.held == 0 }
        #expect(harness.insertions.isEmpty)
    }

    @Test
    func aMissingPermissionReleasesTheLease() {
        let harness = DictationControllerHarness(text: "No borres estas notas.")
        let port = Port()
        var dependencies = dependencies(harness, port)
        dependencies.canInsert = { false }

        harness.controller.toggle(using: dependencies)

        #expect(port.kinds == [.global])
        #expect(port.held == 0)
        harness.controller.cancel()
    }

    @Test
    func aRefusedRetryKeepsTheWordsAndAnAdmittedOneDelivers() async throws {
        let harness = DictationControllerHarness(text: "No borres estas notas.")
        defer { harness.controller.cancel() }
        let port = Port()
        var dependencies = dependencies(harness, port)
        var accepts = false
        var delivered: [String] = []
        dependencies.captureDestination = {
            CapturedDictationDestination(name: "Receiver", canRetry: true) { text in
                guard accepts else { return .refused(.targetChanged) }
                delivered.append(text)
                return .verified
            }
        }
        try await dictate(harness, dependencies)
        try await eventually { harness.controller.phase == .recovery(.targetChanged) }
        try await eventually { port.held == 0 }
        accepts = true
        port.refuses = true

        harness.controller.retryUndeliveredText()

        #expect(harness.controller.phase == .recovery(.targetChanged))
        #expect(harness.controller.recoveryText == harness.text)
        #expect(!harness.controller.isRetryingDelivery)
        #expect(delivered.isEmpty)

        port.refuses = false
        harness.controller.retryUndeliveredText()

        try await eventually { delivered == [harness.text] && port.held == 0 }
    }

    @Test
    func aRefusedPasteLastKeepsTheTextAndAnAdmittedOneReleases() async throws {
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        let port = Port()
        let dependencies = dependencies(harness, port)
        try await dictate(harness, dependencies)
        try await eventually { harness.insertions.count == 1 && !harness.controller.isActive && port.held == 0 }
        port.refuses = true

        harness.controller.pasteLastDictation(using: dependencies)

        #expect(!harness.controller.isRetryingDelivery)
        #expect(harness.insertions.count == 1)
        #expect(harness.controller.hasPastableText)

        port.refuses = false
        harness.controller.pasteLastDictation(using: dependencies)

        try await eventually { harness.insertions.count == 2 && port.held == 0 }
    }

    @Test
    func thePracticeFieldAsksForPracticeOnlyWhileItIsTheTarget() {
        let harness = DictationControllerHarness(text: "Hola")
        let practice = DictationPracticeField()
        let holder = UUID()

        #expect(practice.route(harness.dependencies, appIsActive: true).admissionKind == .global)
        practice.show(holder, isKey: true)
        #expect(practice.route(harness.dependencies, appIsActive: false).admissionKind == .global)
        #expect(practice.route(harness.dependencies, appIsActive: true).admissionKind == .practice)
    }

    @Test
    func aPracticeSessionRunsWithTheGlobalPreferenceOff() async throws {
        let harness = DictationControllerHarness(text: "Hola")
        defer { harness.controller.cancel() }
        let practice = DictationPracticeField()
        practice.show(UUID(), isKey: true)
        var dependencies = practice.route(harness.dependencies, appIsActive: true)
        dependencies.admission = .preference(in: harness.defaults)

        try await dictate(harness, dependencies)

        try await eventually { practice.text == "Hola" }
    }

    @Test
    func compositionReadsItsOwnDefaultsForPrewarmAndAdmission() throws {
        let suite = "dictation-admission-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = try AppServices(
            arguments: ["-use-temp-store"], environment: [:], defaults: defaults,
            dictation: DictationController(presentsPanel: false))

        #expect(!services.dictationPrewarmConditions.dictationEnabled)
        #expect(!services.makeDictationSessionDependencies().admission.isEligible())
        #expect(!services.makeSelectionRewriteDependencies().admission.isEligible())

        defaults.set(true, forKey: DictationController.defaultsKey)

        #expect(services.dictationPrewarmConditions.dictationEnabled)
        #expect(services.makeDictationSessionDependencies().admission.isEligible())
        #expect(services.makeSelectionRewriteDependencies().admission.isEligible())
    }

    // MARK: Rewrite

    @MainActor
    private final class RewriteRecorder {
        var captures = 0
        var insertions: [String] = []
        var heldWhileCapturing: [Int] = []
        var heldWhileReplacing: [Int] = []
    }

    private func rewriteDependencies(
        _ port: Port, _ recorder: RewriteRecorder
    ) -> SelectionRewriteController.Dependencies {
        SelectionRewriteController.Dependencies(
            admission: port.admission,
            capture: {
                recorder.captures += 1
                recorder.heldWhileCapturing.append(port.held)
                return .success(CapturedSelection(
                    text: "so we ship it tomorrow", source: .accessibility, applicationName: "Receiver",
                    revalidate: { nil },
                    destination: CapturedDictationDestination(name: "Receiver", canRetry: false) { text in
                        recorder.heldWhileReplacing.append(port.held)
                        recorder.insertions.append(text)
                        return .verified
                    }))
            },
            polish: { text, _, _ in .polished(text.uppercased()) },
            recipes: { [] },
            protectedTerms: { [] },
            copyText: { _ in true },
            wait: { _ in try await Task.sleep(for: .seconds(3_600)) })
    }

    @Test
    func aRefusedRewriteReadsNothing() {
        let port = Port()
        port.refuses = true
        let recorder = RewriteRecorder()
        let controller = SelectionRewriteController(presentsPanel: false)

        controller.start(using: rewriteDependencies(port, recorder))

        #expect(controller.phase == .idle)
        #expect(recorder.captures == 0)
    }

    @Test
    func aRewriteHoldsNoLeaseWhileTheUserDecides() async throws {
        let port = Port()
        let recorder = RewriteRecorder()
        let controller = SelectionRewriteController(presentsPanel: false)
        defer { controller.cancel() }

        controller.start(using: rewriteDependencies(port, recorder))
        try await eventually { controller.phase == .choosing }
        #expect(recorder.heldWhileCapturing == [1])
        #expect(port.held == 0)

        controller.choose(nil)
        try await eventually { controller.phase == .preview("SO WE SHIP IT TOMORROW") }
        #expect(port.held == 0)

        controller.replace()
        try await eventually { controller.phase == .replaced }
        #expect(recorder.heldWhileReplacing == [1])
        #expect(port.held == 0)
    }

    @Test
    func aRefusedReplaceKeepsTheRewriteToCopy() async throws {
        let port = Port()
        let recorder = RewriteRecorder()
        let controller = SelectionRewriteController(presentsPanel: false)
        defer { controller.cancel() }
        controller.start(using: rewriteDependencies(port, recorder))
        try await eventually { controller.phase == .choosing }
        controller.choose(nil)
        try await eventually { controller.phase == .preview("SO WE SHIP IT TOMORROW") }
        port.refuses = true

        controller.replace()

        guard case .failed = controller.phase else { throw CancellationError() }
        #expect(recorder.insertions.isEmpty)
        #expect(controller.result == "SO WE SHIP IT TOMORROW")
    }
}
