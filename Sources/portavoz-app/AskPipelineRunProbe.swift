import ApplicationKit
import Darwin
import Foundation
import PortavozCore

struct AskPipelineTiming: Codable, Equatable, Sendable {
    let wallDurationMilliseconds: Double
    let cpuTimeMilliseconds: Double
}

struct AskPipelineStageSample: Codable, Equatable, Sendable {
    let stage: String
    let outcome: String
    let wallDurationMilliseconds: Double
    let cpuTimeMilliseconds: Double
}

struct AskPipelineCorpusEvidence: Codable, Equatable, Sendable {
    let generation: String
    let checksum: String
    let fixtureSegmentCount: Int
    let pendingBefore: Int
    let pendingAfter: Int
    let readyBefore: Bool
    let readyAfter: Bool
    let warmup: String
}

struct AskPipelineCitationEvidence: Codable, Equatable, Sendable {
    let count: Int
    let digest: String
    let valid: Bool
}

struct AskPipelineBenchmarkSample: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let run: Int
    let operation: String
    let outcome: String
    let total: AskPipelineTiming
    let firstEvidence: AskPipelineTiming
    let firstToken: AskPipelineTiming
    let stages: [AskPipelineStageSample]
    let corpus: AskPipelineCorpusEvidence
    let citations: AskPipelineCitationEvidence
}

enum AskPipelineRunProbeError: Error, Equatable, LocalizedError {
    case duplicateMilestone(AskPipelineMilestone)
    case duplicateStage(AskPipelineStage)
    case duplicateTrace
    case eventAfterCompletion
    case foreignTrace
    case incompleteTrace
    case invalidCorpusReadiness
    case invalidCitations
    case invalidDigest
    case invalidMilestoneOrder
    case invalidRun
    case missingMilestone(AskPipelineMilestone)
    case missingStage(AskPipelineStage)
    case outputAlreadyExists
    case processUsageUnavailable
    case stageStillRunning(AskPipelineStage)
    case unexpectedOperation
    case unexpectedOutcome
    case unmatchedStage(AskPipelineStage)

    var errorDescription: String? {
        switch self {
        case .duplicateMilestone(let milestone):
            "Ask benchmark repeated milestone \(milestone.rawValue)"
        case .duplicateStage(let stage):
            "Ask benchmark repeated stage \(stage.rawValue)"
        case .duplicateTrace:
            "Ask benchmark observed more than one trace"
        case .eventAfterCompletion:
            "Ask benchmark observed an event after completion"
        case .foreignTrace:
            "Ask benchmark observed an event from another trace"
        case .incompleteTrace:
            "Ask benchmark trace did not finish"
        case .invalidCorpusReadiness:
            "Ask benchmark corpus readiness evidence is invalid"
        case .invalidCitations:
            "Ask benchmark citation evidence is invalid"
        case .invalidDigest:
            "Ask benchmark digest evidence is invalid"
        case .invalidMilestoneOrder:
            "Ask benchmark first-token milestone preceded first evidence"
        case .invalidRun:
            "Ask benchmark run must be greater than zero"
        case .missingMilestone(let milestone):
            "Ask benchmark did not reach milestone \(milestone.rawValue)"
        case .missingStage(let stage):
            "Ask benchmark did not complete stage \(stage.rawValue)"
        case .outputAlreadyExists:
            "Ask benchmark output already exists"
        case .processUsageUnavailable:
            "Ask benchmark process CPU counters could not be measured"
        case .stageStillRunning(let stage):
            "Ask benchmark stage \(stage.rawValue) is still running"
        case .unexpectedOperation:
            "Ask benchmark observed an unexpected operation"
        case .unexpectedOutcome:
            "Ask benchmark did not complete successfully"
        case .unmatchedStage(let stage):
            "Ask benchmark finished unmatched stage \(stage.rawValue)"
        }
    }
}

/// Strict benchmark-only collector for the closed Ask telemetry vocabulary.
/// Runtime UUIDs correlate events in memory but never cross into the receipt.
final class AskPipelineRunProbe: @unchecked Sendable {
    typealias CPUProvider = @Sendable () throws -> UInt64
    typealias UptimeProvider = @Sendable () -> UInt64

    private struct Snapshot {
        let uptime: UInt64
        let cpu: UInt64
    }

    private struct ActiveStage {
        let span: AskPipelineStageSpan
        let startedAt: Snapshot
    }

    private struct FinishedTrace {
        let outcome: ResourceWorkloadOutcome
        let finishedAt: Snapshot
    }

    private let run: Int
    private let expectedOperation: AskPipelineOperation
    private let cpuProvider: CPUProvider
    private let uptimeProvider: UptimeProvider
    private let lock = NSLock()
    private var identity: AskPipelineTraceIdentity?
    private var startedAt: Snapshot?
    private var finishedTrace: FinishedTrace?
    private var activeStages: [UUID: ActiveStage] = [:]
    private var completedStages: [AskPipelineStage: AskPipelineStageSample] = [:]
    private var milestones: [AskPipelineMilestone: AskPipelineTiming] = [:]
    private var violation: AskPipelineRunProbeError?

    init(
        run: Int,
        expectedOperation: AskPipelineOperation = .answer,
        cpuProvider: @escaping CPUProvider = {
            try AskPipelineRunProbe.currentCPUTime()
        },
        uptimeProvider: @escaping UptimeProvider = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws {
        guard run > 0 else { throw AskPipelineRunProbeError.invalidRun }
        self.run = run
        self.expectedOperation = expectedOperation
        self.cpuProvider = cpuProvider
        self.uptimeProvider = uptimeProvider
    }

    func receive(_ event: AskPipelineEvent) {
        let snapshot: Snapshot
        do {
            snapshot = Snapshot(
                uptime: uptimeProvider(),
                cpu: try cpuProvider())
        } catch {
            record(.processUsageUnavailable)
            return
        }

        lock.lock()
        defer { lock.unlock() }
        guard violation == nil else { return }
        if finishedTrace != nil {
            violation = .eventAfterCompletion
            return
        }

        ingest(event, at: snapshot)
    }

    private func ingest(_ event: AskPipelineEvent, at snapshot: Snapshot) {
        switch event {
        case .started(let trace):
            start(trace, at: snapshot)

        case .stageStarted(let span):
            start(span, at: snapshot)

        case .stageFinished(let span, let outcome):
            finish(span, outcome: outcome, at: snapshot)

        case .reached(let trace, let milestone):
            reach(milestone, on: trace, at: snapshot)

        case .finished(let trace, let outcome):
            finish(trace, outcome: outcome, at: snapshot)
        }
    }

    private func start(
        _ trace: AskPipelineTraceIdentity,
        at snapshot: Snapshot
    ) {
        guard identity == nil else {
            violation = .duplicateTrace
            return
        }
        guard trace.operation == expectedOperation else {
            violation = .unexpectedOperation
            return
        }
        identity = trace
        startedAt = snapshot
    }

    private func start(
        _ span: AskPipelineStageSpan,
        at snapshot: Snapshot
    ) {
        guard owns(span.trace) else { return }
        guard completedStages[span.stage] == nil,
              !activeStages.values.contains(where: {
                  $0.span.stage == span.stage
              })
        else {
            violation = .duplicateStage(span.stage)
            return
        }
        activeStages[span.id] = ActiveStage(
            span: span,
            startedAt: snapshot)
    }

    private func finish(
        _ span: AskPipelineStageSpan,
        outcome: ResourceWorkloadOutcome,
        at snapshot: Snapshot
    ) {
        guard owns(span.trace) else { return }
        guard let active = activeStages.removeValue(forKey: span.id),
              active.span == span
        else {
            violation = .unmatchedStage(span.stage)
            return
        }
        completedStages[span.stage] = AskPipelineStageSample(
            stage: span.stage.rawValue,
            outcome: outcome.rawValue,
            wallDurationMilliseconds: Self.milliseconds(
                snapshot.uptime.saturatingSubtract(active.startedAt.uptime)),
            cpuTimeMilliseconds: Self.cpuMilliseconds(
                snapshot.cpu.saturatingSubtract(active.startedAt.cpu)))
    }

    private func reach(
        _ milestone: AskPipelineMilestone,
        on trace: AskPipelineTraceIdentity,
        at snapshot: Snapshot
    ) {
        guard owns(trace) else { return }
        guard milestones[milestone] == nil else {
            violation = .duplicateMilestone(milestone)
            return
        }
        guard let startedAt else {
            violation = .incompleteTrace
            return
        }
        milestones[milestone] = Self.timing(from: startedAt, to: snapshot)
    }

    private func finish(
        _ trace: AskPipelineTraceIdentity,
        outcome: ResourceWorkloadOutcome,
        at snapshot: Snapshot
    ) {
        guard owns(trace) else { return }
        if let active = activeStages.values.first {
            violation = .stageStillRunning(active.span.stage)
            return
        }
        finishedTrace = FinishedTrace(
            outcome: outcome,
            finishedAt: snapshot)
    }

    func makeSample(
        corpus: AskPipelineCorpusEvidence,
        citations: AskPipelineCitationEvidence
    ) throws -> AskPipelineBenchmarkSample {
        lock.lock()
        defer { lock.unlock() }
        if let violation { throw violation }
        guard let identity, let startedAt, let finishedTrace else {
            throw AskPipelineRunProbeError.incompleteTrace
        }
        guard identity.operation == expectedOperation else {
            throw AskPipelineRunProbeError.unexpectedOperation
        }
        guard finishedTrace.outcome == .completed else {
            throw AskPipelineRunProbeError.unexpectedOutcome
        }
        let stages = try validatedStages()
        let milestones = try validatedMilestones()
        try validate(corpus)
        try validate(citations)
        return AskPipelineBenchmarkSample(
            schemaVersion: 1,
            run: run,
            operation: identity.operation.rawValue,
            outcome: finishedTrace.outcome.rawValue,
            total: Self.timing(from: startedAt, to: finishedTrace.finishedAt),
            firstEvidence: milestones.firstEvidence,
            firstToken: milestones.firstToken,
            stages: stages,
            corpus: corpus,
            citations: citations)
    }

    private func validatedStages() throws -> [AskPipelineStageSample] {
        for stage in AskPipelineStage.allCases {
            guard let sample = completedStages[stage] else {
                throw AskPipelineRunProbeError.missingStage(stage)
            }
            guard sample.outcome == ResourceWorkloadOutcome.completed.rawValue else {
                throw AskPipelineRunProbeError.unexpectedOutcome
            }
        }
        return AskPipelineStage.allCases.compactMap { completedStages[$0] }
    }

    private func validatedMilestones() throws -> (
        firstEvidence: AskPipelineTiming,
        firstToken: AskPipelineTiming
    ) {
        guard let firstEvidence = milestones[.firstEvidence] else {
            throw AskPipelineRunProbeError.missingMilestone(.firstEvidence)
        }
        guard let firstToken = milestones[.firstToken] else {
            throw AskPipelineRunProbeError.missingMilestone(.firstToken)
        }
        guard firstEvidence.wallDurationMilliseconds
                <= firstToken.wallDurationMilliseconds,
              firstEvidence.cpuTimeMilliseconds
                <= firstToken.cpuTimeMilliseconds
        else {
            throw AskPipelineRunProbeError.invalidMilestoneOrder
        }
        return (firstEvidence, firstToken)
    }

    private func validate(_ corpus: AskPipelineCorpusEvidence) throws {
        guard corpus.fixtureSegmentCount > 0,
              corpus.pendingBefore == corpus.fixtureSegmentCount,
              corpus.pendingAfter == 0,
              !corpus.readyBefore,
              corpus.readyAfter,
              corpus.warmup == "cold"
        else {
            throw AskPipelineRunProbeError.invalidCorpusReadiness
        }
        guard Self.isSHA256(corpus.checksum) else {
            throw AskPipelineRunProbeError.invalidDigest
        }
    }

    private func validate(_ citations: AskPipelineCitationEvidence) throws {
        guard citations.valid,
              citations.count >= 1
        else {
            throw AskPipelineRunProbeError.invalidCitations
        }
        guard Self.isSHA256(citations.digest) else {
            throw AskPipelineRunProbeError.invalidDigest
        }
    }

    func writeSample(
        to output: URL,
        corpus: AskPipelineCorpusEvidence,
        citations: AskPipelineCitationEvidence
    ) throws {
        let sample = try makeSample(corpus: corpus, citations: citations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sample) + Data("\n".utf8)
        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw AskPipelineRunProbeError.outputAlreadyExists
        }
        let temporary = directory.appendingPathComponent(
            ".\(output.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: output)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func owns(_ trace: AskPipelineTraceIdentity) -> Bool {
        guard let identity else {
            violation = .foreignTrace
            return false
        }
        guard identity == trace else {
            violation = .foreignTrace
            return false
        }
        return true
    }

    private func record(_ error: AskPipelineRunProbeError) {
        lock.lock()
        if violation == nil { violation = error }
        lock.unlock()
    }

    private static func timing(
        from start: Snapshot,
        to end: Snapshot
    ) -> AskPipelineTiming {
        AskPipelineTiming(
            wallDurationMilliseconds: milliseconds(
                end.uptime.saturatingSubtract(start.uptime)),
            cpuTimeMilliseconds: cpuMilliseconds(
                end.cpu.saturatingSubtract(start.cpu)))
    }

    private static func currentCPUTime() throws -> UInt64 {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) { reboundPointer in
                proc_pid_rusage(
                    getpid(),
                    RUSAGE_INFO_CURRENT,
                    reboundPointer)
            }
        }
        guard result == 0 else {
            throw AskPipelineRunProbeError.processUsageUnavailable
        }
        return usage.ri_user_time + usage.ri_system_time
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    private static func cpuMilliseconds(_ ticks: UInt64) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(ticks) * Double(timebase.numer)
            / Double(timebase.denom) / 1_000_000
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
