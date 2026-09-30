import Foundation
import PortavozCore
import TranscriptionKit
import XCTest

@testable import portavoz_app

@MainActor
final class ModelIdleReleaseTests: XCTestCase {
    func testServiceBurstCoalescesDeadlinesAndResidentAcquisitionCancelsOnlySpeech() async throws {
        let clock = ControlledModelIdleClock()
        let scheduler = AppModelIdleReleaseScheduler(sleep: { try await clock.sleep($0) })
        let services = try services(scheduler: scheduler)
        for _ in 0..<500 {
            services.scheduleRecordingEnginesRelease()
            services.scheduleWhisperRelease()
            services.scheduleMLXRelease()
        }
        XCTAssertEqual(scheduler.pendingCount, 3)
        try await eventually { await clock.delays.count == 3 }
        let delays = await clock.delays
        XCTAssertEqual(delays.filter { $0 == .seconds(600) }.count, 1)
        XCTAssertEqual(delays.filter { $0 == .seconds(120) }.count, 2)
        services.modelsState = .failed("synthetic readiness marker")
        XCTAssertNil(try services.acquireResidentLiveSpeechRuntime())
        XCTAssertEqual(scheduler.pendingCount, 2)
        await clock.resumeAll()
        try await eventually { scheduler.pendingCount == 0 }
        guard case .failed = services.modelsState else {
            return XCTFail("cancelled speech deadline must not publish readiness")
        }
    }

    func testReplacedTaskCannotReleaseOrEraseItsSuccessor() async throws {
        let clock = ControlledModelIdleClock()
        let scheduler = AppModelIdleReleaseScheduler(sleep: { try await clock.sleep($0) })
        var releases = 0
        scheduler.schedule(.quality, profile: .balanced) { releases += 100 }
        try await eventually { await clock.delays.count == 1 }
        scheduler.schedule(.quality, profile: .balanced) { releases += 1 }
        try await eventually { await clock.delays.count == 2 }
        await clock.resumeFirst()
        // The fake clock deliberately ignores cancellation. A subsequent actor
        // turn observes the fence rather than relying on cooperative Task.sleep.
        await clock.resumeAll()
        try await eventually { scheduler.pendingCount == 0 }
        XCTAssertEqual(releases, 1)
    }

    func testClockFailureCannotReleaseInEitherProfile() async throws {
        let scheduler = AppModelIdleReleaseScheduler(sleep: { _ in throw ClockFailure.failed })
        var releases = 0
        for profile in AppModelMemoryPreferences.Profile.allCases {
            scheduler.schedule(.recording, profile: profile) { releases += 1 }
            try await eventually { scheduler.pendingCount == 0 }
        }
        XCTAssertEqual(releases, 0)
    }

    func testLightweightKeepsAShortGraceBeforeEachRelease() async throws {
        let clock = ControlledModelIdleClock()
        let scheduler = AppModelIdleReleaseScheduler(sleep: { try await clock.sleep($0) })
        var released: [AppModelIdleReleaseScheduler.Slot] = []
        for slot in AppModelIdleReleaseScheduler.Slot.allCases {
            scheduler.schedule(slot, profile: .lightweight) { released.append(slot) }
        }
        try await eventually { await clock.delays.count == 3 }
        let delays = await clock.delays
        XCTAssertEqual(delays.sorted(), [.seconds(30), .seconds(30), .seconds(60)])
        XCTAssertTrue(released.isEmpty, "a burst inside the grace must reuse hot weights")
        await clock.resumeAll()
        try await eventually { scheduler.pendingCount == 0 }
        XCTAssertEqual(Set(released), Set(AppModelIdleReleaseScheduler.Slot.allCases))
    }

    func testModelWarmUpArmsTheIdleReleaseEvenWhenItStops() async throws {
        let clock = ControlledModelIdleClock()
        let scheduler = AppModelIdleReleaseScheduler(sleep: { try await clock.sleep($0) })
        let services = try services(scheduler: scheduler)
        let warmUp = Task { try await services.loadEnginesIfNeeded() }
        warmUp.cancel()
        _ = try? await warmUp.value
        XCTAssertEqual(scheduler.pendingCount, 1)
        try await eventually { await clock.delays == [.seconds(600)] }
        await clock.resumeAll()
        try await eventually { scheduler.pendingCount == 0 }
    }

    func testProfileChangeRearmsExistingServiceDeadlinesWithoutChangingModelChoice() async throws {
        let suite = "model-idle-release-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "whisperCompact")
        defaults.set("ollama", forKey: "summaryEngine")
        let clock = ControlledModelIdleClock()
        let scheduler = AppModelIdleReleaseScheduler(sleep: { try await clock.sleep($0) })
        let services = try services(defaults: defaults, scheduler: scheduler)
        services.setModelMemoryProfile(.balanced)
        try await eventually { await clock.delays.count == 3 }
        services.modelsState = .failed("synthetic readiness marker")
        services.setModelMemoryProfile(.lightweight)
        try await eventually { await clock.delays.count == 6 }
        let allDelays = await clock.delays
        XCTAssertEqual(allDelays.suffix(3).sorted(), [.seconds(30), .seconds(30), .seconds(60)])
        await clock.resumeAll()
        try await eventually { scheduler.pendingCount == 0 }
        guard case .unknown = services.modelsState else {
            return XCTFail("the real service release must settle unloaded models")
        }
        XCTAssertEqual(services.modelMemoryPreferences.profile, .lightweight)
        XCTAssertEqual(defaults.object(forKey: "whisperCompact") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "summaryEngine"), "ollama")
        await clock.resumeAll()
    }

    func testActualProfileActionSurvivesServiceReconstructionWithoutChangingOtherChoices() async throws {
        let suite = "model-profile-roundtrip-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "whisperCompact")
        defaults.set("ollama", forKey: "summaryEngine")
        for original: Any in ["unknown — inválido", -1, false, "balanced", "lightweight"] {
            for selected in AppModelMemoryPreferences.Profile.allCases {
                defaults.set(original, forKey: AppModelMemoryPreferences.key)
                let owner = try services(defaults: defaults, scheduler: .init(sleep: { _ in
                    throw ClockFailure.failed
                }))
                owner.setModelMemoryProfile(selected)
                let independentDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                let rebuilt = try services(defaults: independentDefaults, scheduler: .init(sleep: { _ in
                    throw ClockFailure.failed
                }))
                XCTAssertEqual(rebuilt.modelMemoryPreferences.profile, selected)
                XCTAssertEqual(independentDefaults.string(forKey: AppModelMemoryPreferences.key), selected.rawValue)
                XCTAssertEqual(independentDefaults.object(forKey: "whisperCompact") as? Bool, false)
                XCTAssertEqual(independentDefaults.string(forKey: "summaryEngine"), "ollama")
            }
        }
    }

    func testLightweightReleaseDoesNotEraseInFlightPreparationState() async throws {
        let scheduler = AppModelIdleReleaseScheduler(sleep: { _ in })
        let services = try services(scheduler: scheduler)
        let ticket = try XCTUnwrap(services.modelResidencyLedger.beginLoad(.liveSpeech))
        let generation = UUID()
        let task = Task<ParakeetEngine, Error> { throw CancellationError() }
        services.liveSpeechRuntimeLoad = .init(generation: generation, ticket: ticket, task: task)
        services.modelsState = .downloading("Synthetic preparation")
        services.setModelMemoryProfile(.lightweight)
        try await eventually { scheduler.pendingCount == 0 }
        XCTAssertEqual(services.liveSpeechRuntimeLoad?.generation, generation)
        guard case .downloading("Synthetic preparation") = services.modelsState else {
            return XCTFail("rejected release must not erase the active preparation status")
        }
        services.liveSpeechRuntimeLoad = nil
        XCTAssertTrue(services.modelResidencyLedger.failLoad(ticket))
    }

    func testMLXAcquisitionWaitsForAnAcceptedReleaseInsteadOfFailing() async throws {
        let services = try services(scheduler: AppModelIdleReleaseScheduler())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-release-\(UUID().uuidString)")
        let ticket = try XCTUnwrap(services.modelResidencyLedger.beginLoad(.languageIntelligence))
        XCTAssertTrue(services.modelResidencyLedger.finishLoad(ticket, measuredFootprintBytes: nil))
        services.mlxRuntimeDirectoryKey = directory.standardizedFileURL.resolvingSymlinksInPath().path

        // Main-actor FIFO: the acquire runs while the release awaits the runtime.
        let release = Task { await services.releaseMLXRuntime() }
        let acquire = Task {
            try await services.acquireMLXRuntime(directory: directory, workloadClass: .userInitiated)
        }
        acquire.cancel()
        do {
            _ = try await acquire.value
            XCTFail("a cancelled caller must not load")
        } catch is CancellationError {
        } catch {
            XCTFail("acquisition during an accepted release must wait, not fail: \(error)")
        }
        let released = await release.value
        XCTAssertTrue(released)
        XCTAssertNil(services.mlxRuntimeDirectoryKey)
        XCTAssertEqual(services.modelResidencyLedger.record(for: .languageIntelligence).status, .unloaded)
    }

    func testPendingDeadlineDoesNotRetainScheduler() async throws {
        let clock = ControlledModelIdleClock()
        var scheduler: AppModelIdleReleaseScheduler? = .init(sleep: { try await clock.sleep($0) })
        weak let observed = scheduler
        var released = false
        scheduler?.schedule(.language, profile: .balanced) { released = true }
        try await eventually { await clock.delays.count == 1 }
        scheduler = nil
        XCTAssertNil(observed)
        await clock.resumeAll()
        XCTAssertFalse(released)
    }

    private func services(
        defaults: UserDefaults? = nil,
        scheduler: AppModelIdleReleaseScheduler
    ) throws -> AppServices {
        try AppServices(
            arguments: ["portavoz-app", "-use-temp-store"],
            defaults: defaults ?? makeDefaults(),
            modelIdleReleaseScheduler: scheduler)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "model-idle-release-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func eventually(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { return XCTFail("state did not settle") }
            await Task.yield()
        }
    }
}

private enum ClockFailure: Error { case failed }

private actor ControlledModelIdleClock {
    private(set) var delays: [Duration] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(_ delay: Duration) async throws {
        delays.append(delay)
        await withCheckedContinuation { continuations.append($0) }
    }

    func resumeFirst() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
