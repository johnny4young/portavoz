import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore

@MainActor
enum LiveAssistValidationFaultRunner {
    private struct DomainResult {
        let cancellationSucceeded: Bool
        let relaunchSucceeded: Bool
        let latePublicationCount: Int
    }

    static func run(
        _ scenarios: [LiveAssistValidationFixture.FaultScenario]
    ) async throws -> [LiveAssistValidationObservations.Fault] {
        let questionResult = try await questionDetection()
        let interviewResult = try await interview()
        let summaryResult = try await rollingSummary()
        let translationResult = try await translation()
        let results = [
            "questionDetection": questionResult,
            "interview": interviewResult,
            "rollingSummary": summaryResult,
            "translation": translationResult
        ]
        return try scenarios.map { scenario in
            guard let result = results[scenario.domain],
                  ["cancelBeforeResult", "relaunch"].contains(scenario.fault)
            else { throw LiveAssistValidationError.invalidFixture }
            if scenario.fault == "cancelBeforeResult" {
                return .init(
                    scenarioID: scenario.id,
                    outcome: result.cancellationSucceeded
                        ? "cancelled" : "recovered",
                    latePublicationCount: result.latePublicationCount)
            }
            return .init(
                scenarioID: scenario.id,
                outcome: result.relaunchSucceeded
                    ? "recovered" : "cancelled",
                latePublicationCount: result.latePublicationCount)
        }
    }

    private static func questionDetection() async throws -> DomainResult {
        let started = LiveAssistEventQueue<String>()
        let generator = LiveAssistControlledCompanionGenerator(started: started)
        let sink = LiveAssistCompanionSink()
        let coordinator = LiveCompanionWorkCoordinator(
            generator: { await generator.generate($0) },
            receiver: { request, _ in sink.receive(request.candidate) })

        coordinator.submit(companionRequest("obsolete"))
        guard try await next(started, domain: "question cancellation") == "obsolete"
        else { throw LiveAssistValidationError.invalidFixture }
        coordinator.cancel()
        coordinator.submit(companionRequest("fresh"))
        await generator.finish("obsolete")
        guard try await next(started, domain: "question relaunch") == "fresh"
        else { throw LiveAssistValidationError.invalidFixture }
        await generator.finish("fresh")
        try await waitUntil(domain: "question completion") {
            !coordinator.isRunning
        }
        let late = sink.candidates.filter { $0 == "obsolete" }.count
        return DomainResult(
            cancellationSucceeded: late == 0,
            relaunchSucceeded: sink.candidates == ["fresh"],
            latePublicationCount: late)
    }

    private static func rollingSummary() async throws -> DomainResult {
        let started = LiveAssistEventQueue<Int>()
        let operated = LiveAssistEventQueue<Int>()
        let sleeper = LiveAssistControlledSummarySleep(started: started)
        let operation = LiveAssistControlledSummaryOperation(started: operated)
        let coordinator = LiveSummaryWorkCoordinator(
            interval: .seconds(40),
            sleep: { _ in await sleeper.wait() },
            operation: { await operation.run() })

        coordinator.request()
        guard try await next(
            started,
            domain: "summary cancellation") == 1
        else { throw LiveAssistValidationError.invalidFixture }
        coordinator.cancel()
        coordinator.request()
        await sleeper.resumeNext()
        guard try await next(started, domain: "summary relaunch") == 2
        else { throw LiveAssistValidationError.invalidFixture }
        let countBeforeFreshRun = await operation.count
        await sleeper.resumeNext()
        guard try await next(operated, domain: "summary operation") == 1
        else { throw LiveAssistValidationError.invalidFixture }
        try await waitUntil(domain: "summary completion") {
            !coordinator.isRunning
        }
        let operationCount = await operation.count
        return DomainResult(
            cancellationSucceeded: countBeforeFreshRun == 0,
            relaunchSucceeded: operationCount == 1,
            latePublicationCount: countBeforeFreshRun)
    }

    private static func interview() async throws -> DomainResult {
        let started = LiveAssistEventQueue<Int>()
        let answerer = LiveAssistControlledInterviewAnswerer(started: started)
        let useCase = AssistInterviewQuestion(
            answering: answerer,
            timeout: .seconds(5))
        let model = RecordingInterviewAssistModel()
        let captions = interviewCaptions()

        model.setEnabled(true, captions: captions)
        model.requestAnswer(using: useCase, isRecording: { true })
        guard try await next(started, domain: "interview cancellation") == 1
        else { throw LiveAssistValidationError.invalidFixture }
        model.setEnabled(false, captions: [])
        await answerer.resume(with: "Obsolete answer [1].")
        try await waitUntil(domain: "interview cancellation unwind") {
            await answerer.pendingCount == 0
        }
        let cancellationSucceeded = model.answerState == nil
            && model.context == nil

        model.setEnabled(true, captions: captions)
        model.requestAnswer(using: useCase, isRecording: { true })
        guard try await next(started, domain: "interview relaunch") == 2
        else { throw LiveAssistValidationError.invalidFixture }
        await answerer.resume(with: "The retry budget is two attempts [1].")
        try await waitUntil(domain: "interview publication") {
            if case .answered = model.answerState { return true }
            return false
        }
        let relaunchSucceeded: Bool
        if case .answered = model.answerState {
            relaunchSucceeded = true
        } else {
            relaunchSucceeded = false
        }
        return DomainResult(
            cancellationSucceeded: cancellationSucceeded,
            relaunchSucceeded: relaunchSucceeded,
            latePublicationCount: cancellationSucceeded ? 0 : 1)
    }

    private static func translation() async throws -> DomainResult {
        let hub = LiveTranslationWakeHub()
        let obsolete = hub.subscribe()
        obsolete.cancel()
        hub.signal()
        let obsoleteValue = try await streamProducedValue(
            obsolete.stream,
            domain: "translation cancellation")

        let fresh = hub.subscribe()
        hub.signal()
        let freshValue = try await streamProducedValue(
            fresh.stream,
            domain: "translation relaunch")
        fresh.cancel()
        return DomainResult(
            cancellationSucceeded: !obsoleteValue,
            relaunchSucceeded: freshValue,
            latePublicationCount: obsoleteValue ? 1 : 0)
    }

    private static func companionRequest(
        _ candidate: String
    ) -> CompanionGenerationRequest {
        CompanionGenerationRequest(
            meetingID: MeetingID(),
            sourceTranscriptRevision: 0,
            sourceCorrectionRevision: .accepted,
            workflow: .liveRecording,
            candidate: candidate,
            questionSegmentIDs: [UUID()],
            recentTranscript: [],
            ownerName: nil,
            outputLanguage: "en",
            askedAt: 1)
    }

    private static func interviewCaptions() -> [TranscriptSegment] {
        let meetingID = MeetingID()
        return [
            TranscriptSegment(
                meetingID: meetingID,
                channel: .microphone,
                text: "The retry budget is two attempts.",
                startTime: 0,
                endTime: 4,
                isFinal: true),
            TranscriptSegment(
                meetingID: meetingID,
                channel: .system,
                text: "How would you explain that retry policy?",
                startTime: 5,
                endTime: 9,
                isFinal: true)
        ]
    }

    private static func waitUntil(
        domain: String,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await condition() { return }
            await Task.yield()
        }
        throw LiveAssistValidationError.timedOut(domain)
    }

    private static func next<Element: Sendable>(
        _ queue: LiveAssistEventQueue<Element>,
        domain: String
    ) async throws -> Element {
        guard let value = try await nextOptional(queue, domain: domain)
        else { throw LiveAssistValidationError.timedOut(domain) }
        return value
    }

    private static func nextOptional<Element: Sendable>(
        _ queue: LiveAssistEventQueue<Element>,
        domain: String
    ) async throws -> Element? {
        try await withThrowingTaskGroup(of: Element?.self) { group in
            group.addTask {
                await queue.next()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw LiveAssistValidationError.timedOut(domain)
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw LiveAssistValidationError.timedOut(domain)
            }
            return value
        }
    }

    private static func streamProducedValue(
        _ stream: AsyncStream<Void>,
        domain: String
    ) async throws -> Bool {
        let queue = LiveAssistEventQueue<Bool>()
        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            let value: Void? = await iterator.next()
            await queue.send(value != nil)
        }
        defer { consumer.cancel() }
        return try await next(queue, domain: domain)
    }
}

private actor LiveAssistEventQueue<Element: Sendable> {
    private var values: [Element] = []
    private var waiterOrder: [UUID] = []
    private var waiters: [
        UUID: CheckedContinuation<Element?, Never>
    ] = [:]

    func send(_ value: Element) {
        while let id = waiterOrder.first {
            waiterOrder.removeFirst()
            if let waiter = waiters.removeValue(forKey: id) {
                waiter.resume(returning: value)
                return
            }
        }
        values.append(value)
    }

    func next() async -> Element? {
        if !values.isEmpty {
            return values.removeFirst()
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else if !values.isEmpty {
                    continuation.resume(returning: values.removeFirst())
                } else {
                    waiterOrder.append(id)
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func cancel(id: UUID) {
        waiterOrder.removeAll { $0 == id }
        waiters.removeValue(forKey: id)?.resume(returning: nil)
    }
}

private actor LiveAssistControlledCompanionGenerator {
    private let started: LiveAssistEventQueue<String>
    private var continuations: [
        String: CheckedContinuation<CompanionGenerationResult, Never>
    ] = [:]

    init(started: LiveAssistEventQueue<String>) {
        self.started = started
    }

    func generate(
        _ request: CompanionGenerationRequest
    ) async -> CompanionGenerationResult {
        await started.send(request.candidate)
        return await withCheckedContinuation { continuation in
            continuations[request.candidate] = continuation
        }
    }

    func finish(_ candidate: String) {
        continuations.removeValue(forKey: candidate)?.resume(
            returning: .noAttempt)
    }
}

@MainActor
private final class LiveAssistCompanionSink {
    private(set) var candidates: [String] = []

    func receive(_ candidate: String) {
        candidates.append(candidate)
    }
}

private actor LiveAssistControlledSummarySleep {
    private let started: LiveAssistEventQueue<Int>
    private var count = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(started: LiveAssistEventQueue<Int>) {
        self.started = started
    }

    func wait() async {
        count += 1
        await started.send(count)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor LiveAssistControlledSummaryOperation {
    private let started: LiveAssistEventQueue<Int>
    private(set) var count = 0

    init(started: LiveAssistEventQueue<Int>) {
        self.started = started
    }

    func run() async -> Bool {
        count += 1
        await started.send(count)
        return false
    }
}

private actor LiveAssistControlledInterviewAnswerer: InterviewQuestionAnswering {
    private let started: LiveAssistEventQueue<Int>
    private var count = 0
    private var continuations: [CheckedContinuation<String?, Never>] = []

    var pendingCount: Int { continuations.count }

    init(started: LiveAssistEventQueue<Int>) {
        self.started = started
    }

    func answer(
        question _: String,
        passages _: [RAGPassage]
    ) async throws -> String? {
        count += 1
        await started.send(count)
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(with answer: String?) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: answer)
    }
}
