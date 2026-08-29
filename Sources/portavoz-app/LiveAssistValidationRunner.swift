import Darwin
import Foundation
import IntelligenceKit
import PortavozCore

@MainActor
enum LiveAssistValidationRunner {
    private struct Measurement {
        let questions: [LiveAssistValidationObservations.Question]
        let interviews: [LiveAssistValidationObservations.Interview]
        let summaries: [LiveAssistValidationObservations.Summary]
        let translations: [LiveAssistValidationObservations.Translation]
        let timings: LiveAssistValidationObservations.Timings
    }

    @discardableResult
    static func runIfRequested(arguments: [String]) -> Bool {
        let configuration: LiveAssistValidationConfiguration?
        do {
            configuration = try LiveAssistValidationConfiguration.requested(
                arguments: arguments)
        } catch {
            fail(error)
        }
        guard let configuration else { return false }
        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                try await run(configuration: configuration)
                print("live-assist-validation: observations written")
                exit(0)
            } catch {
                fail(error)
            }
        }
        return true
    }

    static func run(
        configuration: LiveAssistValidationConfiguration
    ) async throws {
        guard !FileManager.default.fileExists(
            atPath: configuration.outputURL.path)
        else { throw LiveAssistValidationError.outputAlreadyExists }
        let fixture = try LiveAssistValidationFixture.load(
            from: configuration.fixtureURL)
        if configuration.adapter == .foundationModels {
            guard FoundationModelsCapability.current().isAvailable
            else { throw LiveAssistValidationError.foundationModelsUnavailable }
        }

        let resources = try LiveAssistResourceMeasurement()
        resources.start()
        let measurement = try await measure(
            fixture: fixture,
            adapter: configuration.adapter,
            iterations: configuration.iterations)
        let faults = try await LiveAssistValidationFaultRunner.run(
            fixture.faultScenarios)
        let resourceObservation = try resources.finish(
            iterations: configuration.iterations)
        let observations = LiveAssistValidationObservations(
            schemaVersion: 1,
            kind: "live-assist-validation-observations",
            fixtureGeneration: LiveAssistValidationFixture.generation,
            fixtureChecksum: LiveAssistValidationFixture.checksum,
            adapter: configuration.adapter.receipt,
            run: .init(
                commit: configuration.commit,
                build: configuration.build,
                platform: "macos",
                osVersion: Self.operatingSystemVersion,
                architecture: Self.architecture,
                sourceState: configuration.sourceState),
            questionEvents: measurement.questions,
            interviewScenarios: measurement.interviews,
            rollingSummaryScenarios: measurement.summaries,
            translationScenarios: measurement.translations,
            faultScenarios: faults,
            timings: measurement.timings,
            resources: resourceObservation)
        try write(observations, to: configuration.outputURL)
    }

    private static func measure(
        fixture: LiveAssistValidationFixture,
        adapter: LiveAssistValidationAdapter,
        iterations: Int
    ) async throws -> Measurement {
        var questionResults: [LiveAssistValidationObservations.Question] = []
        var interviewResults: [LiveAssistValidationObservations.Interview] = []
        var summaryResults: [LiveAssistValidationObservations.Summary] = []
        var translationResults: [LiveAssistValidationObservations.Translation] = []
        var questionSamples: [Double] = []
        var interviewSamples: [Double] = []
        var summarySamples: [Double] = []
        var translationSamples: [Double] = []
        var firstQuestion = 0.0
        var firstInterview = 0.0
        var firstSummary = 0.0
        var firstTranslation = 0.0

        for iteration in 0..<iterations {
            let questionRound = try await measureQuestions(
                fixture.questionSessions,
                adapter: adapter)
            let interviewRound = measureScenarios(
                fixture.interviewScenarios,
                operation: LiveAssistValidationPolicy.interviews)
            let summaryRound = measureScenarios(
                fixture.rollingSummaryScenarios,
                operation: LiveAssistValidationPolicy.summaries)
            let translationRound = measureScenarios(
                fixture.translationScenarios,
                operation: LiveAssistValidationPolicy.translations)

            if iteration == 0 {
                questionResults = questionRound.values
                interviewResults = interviewRound.values
                summaryResults = summaryRound.values
                translationResults = translationRound.values
                firstQuestion = questionRound.firstMilliseconds
                firstInterview = interviewRound.firstMilliseconds
                firstSummary = summaryRound.firstMilliseconds
                firstTranslation = translationRound.firstMilliseconds
            }
            questionSamples.append(questionRound.averageMilliseconds)
            interviewSamples.append(interviewRound.averageMilliseconds)
            summarySamples.append(summaryRound.averageMilliseconds)
            translationSamples.append(translationRound.averageMilliseconds)
        }

        return Measurement(
            questions: questionResults,
            interviews: interviewResults,
            summaries: summaryResults,
            translations: translationResults,
            timings: .init(
                questionDetection: .init(
                    firstResultMilliseconds: firstQuestion,
                    steadyStateMilliseconds: questionSamples),
                interview: .init(
                    firstResultMilliseconds: firstInterview,
                    steadyStateMilliseconds: interviewSamples),
                rollingSummary: .init(
                    firstResultMilliseconds: firstSummary,
                    steadyStateMilliseconds: summarySamples),
                translation: .init(
                    firstResultMilliseconds: firstTranslation,
                    steadyStateMilliseconds: translationSamples)))
    }

    private struct TimedValues<Value> {
        let values: [Value]
        let firstMilliseconds: Double
        let averageMilliseconds: Double
    }

    private static func measureQuestions(
        _ sessions: [LiveAssistValidationFixture.QuestionSession],
        adapter: LiveAssistValidationAdapter
    ) async throws -> TimedValues<LiveAssistValidationObservations.Question> {
        var values: [LiveAssistValidationObservations.Question] = []
        var durations: [Double] = []
        for session in sessions {
            for event in session.events {
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let decision = await questionDecision(
                    event,
                    ownerName: session.ownerName,
                    adapter: adapter)
                durations.append(elapsedMilliseconds(since: startedAt))
                values.append(.init(
                    eventID: event.id.liveAssistReceiptID,
                    decision: decision))
            }
        }
        guard let first = durations.first, !values.isEmpty
        else { throw LiveAssistValidationError.invalidFixture }
        return TimedValues(
            values: values,
            firstMilliseconds: first,
            averageMilliseconds: durations.reduce(0, +) / Double(durations.count))
    }

    private static func questionDecision(
        _ event: LiveAssistValidationFixture.QuestionEvent,
        ownerName: String,
        adapter: LiveAssistValidationAdapter
    ) async -> String {
        guard event.channel == .system else { return "ignore" }
        guard !TranscriptNoiseFilter.isLikelyNoise(
            text: event.text,
            confidence: event.confidence)
        else { return "abstain" }
        let directed = QuestionHeuristic.mentions(ownerName, in: event.text)
        guard QuestionHeuristic.looksLikeQuestion(event.text) || directed
        else { return "ignore" }
        guard adapter == .foundationModels else { return "prompt" }

        guard #available(macOS 26.0, *) else { return "abstain" }
        do {
            let detected = try await FoundationModelLiveQuestionDetector().detect(
                candidate: event.text,
                ownerName: ownerName)
            guard detected.isQuestion,
                  !detected.question.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty
            else { return "ignore" }
            switch detected.kind.lowercased() {
            case "knowledge", "context":
                return "prompt"
            default:
                return directed ? "prompt" : "ignore"
            }
        } catch is CancellationError {
            return "abstain"
        } catch {
            return "abstain"
        }
    }

    private static func measureScenarios<Input, Output>(
        _ inputs: [Input],
        operation: ([Input]) -> [Output]
    ) -> TimedValues<Output> {
        guard let firstInput = inputs.first else {
            return TimedValues(
                values: [],
                firstMilliseconds: 0,
                averageMilliseconds: 0)
        }
        let firstStartedAt = DispatchTime.now().uptimeNanoseconds
        _ = operation([firstInput])
        let first = elapsedMilliseconds(since: firstStartedAt)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let values = operation(inputs)
        let total = elapsedMilliseconds(since: startedAt)
        return TimedValues(
            values: values,
            firstMilliseconds: first,
            averageMilliseconds: total / Double(max(1, inputs.count)))
    }

    private static func elapsedMilliseconds(since startedAt: UInt64) -> Double {
        Double(
            elapsedNanoseconds(since: startedAt)
        ) / 1_000_000
    }

    private static func elapsedNanoseconds(since startedAt: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= startedAt ? now - startedAt : 0
    }

    private static var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static func write(
        _ observations: LiveAssistValidationObservations,
        to output: URL
    ) throws {
        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path)
        guard !FileManager.default.fileExists(atPath: output.path)
        else { throw LiveAssistValidationError.outputAlreadyExists }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(observations) + Data("\n".utf8)
        let temporary = directory.appendingPathComponent(
            ".\(output.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        do {
            try FileManager.default.moveItem(at: temporary, to: output)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func fail(_ error: Error) -> Never {
        let message = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        print("live-assist-validation: FAILED: \(message)")
        exit(1)
    }
}
