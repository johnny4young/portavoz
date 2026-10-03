import Foundation

/// Scripted audio and recognition enter the production controller. Only the
/// explicitly armed disposable fixture stops after an acknowledged mode gesture;
/// it never changes that choice, activates a receiver, or registers global input.
@MainActor
enum DictationNativeControllerUITestFixture {
    static func run(
        controller: DictationController, dependencies: DictationSessionDependencies,
        stopRequested: @MainActor () -> Bool
    ) async -> String {
        guard !Task.isCancelled else { return "controller-cancelled" }
        guard controller.phase == .idle else { return "controller-busy" }
        controller.toggle(using: dependencies)
        defer { controller.cancel() }
        var deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var firstCaptionAt: ContinuousClock.Instant?
        var observedChoice = false
        var stopped = false
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if !stopped, controller.isActive {
                if !controller.partialText.isEmpty, firstCaptionAt == nil {
                    firstCaptionAt = .now
                }
                if !observedChoice, controller.textMode == .clean {
                    observedChoice = true
                    deadline = ContinuousClock.now.advanced(by: .seconds(10))
                }
                // Both clocks are real: observing a caption precedes an additional
                // minimum-capture interval. No simulated age bypasses tap safety.
                if observedChoice, let firstCaptionAt,
                   firstCaptionAt.duration(to: .now) >= .seconds(DictationCapturePolicy.minimumCapture),
                   stopRequested() {
                    stopped = true
                    deadline = ContinuousClock.now.advanced(by: .seconds(10))
                    controller.toggle(using: dependencies)
                }
            } else if let outcome = terminalOutcome(controller.phase) {
                return outcome
            }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return "controller-cancelled" }
        }
        return Task.isCancelled ? "controller-cancelled" : "controller-timeout"
    }

    private static func terminalOutcome(_ phase: DictationController.Phase) -> String? {
        switch phase {
        case .inserted: "inserted"
        case .recovery(let result): String(describing: result)
        case .failed: "controller-failed"
        case .idle: "controller-cancelled"
        case .preparing, .listening: nil
        }
    }
}
