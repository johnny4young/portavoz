import ApplicationKit
import AudioCaptureKit
import CryptoKit
import Foundation
import IntelligenceKit
import ModelStoreKit
import PortavozCore
import StorageKit
import TranscriptionKit

/// Hidden launch-arg bench mode (M12): SpeechAnalyzer refuses to run in an
/// unbundled CLI (the Speech daemon never answers — spike finding), so the
/// comparative benchmark runs INSIDE the app bundle and prints to stdout:
///
///   Portavoz.app/Contents/MacOS/portavoz-app --bench-live <file> \
///       [--seconds 60] [--language es] [--vocab "a,b"]
///
/// The process exits when the bench finishes — it never touches the UI,
/// the library or the database.
enum BenchMode {
    static func runsIsolatedBenchmark(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains("--bench-record")
            || arguments.contains("--bench-resource-refine")
            || arguments.contains("--bench-resource-summary")
            || arguments.contains("--bench-resource-ask")
            || arguments.contains("--bench-resource-indexing")
            || arguments.contains("--bench-graph-queries")
    }

    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--bench-live"),
            arguments.indices.contains(flag + 1)
        else { return }
        let file = arguments[flag + 1]

        func value(after option: String) -> String? {
            guard let index = arguments.firstIndex(of: option),
                arguments.indices.contains(index + 1)
            else { return nil }
            return arguments[index + 1]
        }
        let seconds = value(after: "--seconds").flatMap(Int.init) ?? 60
        let language = value(after: "--language")
        let vocabulary = value(after: "--vocab").map(VocabularyPrompt.parse) ?? []

        Task.detached {
            do {
                guard #available(macOS 26.0, *) else {
                    print("error: el bench de SpeechAnalyzer requiere macOS 26")
                    exit(1)
                }
                guard SpeechAnalyzerEngine.isAvailable else {
                    print("error: SpeechTranscriber is not available on this device")
                    exit(1)
                }
                let hints = TranscriptionHints(language: language, vocabulary: vocabulary)
                print("bench-live (in-app) · speech · \(seconds)s de \(file)")
                let locale = try await SpeechAnalyzerEngine.ensureAssets(
                    language: language) { print($0) }
                print("locale: \(locale.identifier)")
                let result = try await LiveTranscriptionBench.run(
                    file: URL(fileURLWithPath: file), seconds: seconds,
                    transcribe: {
                        SpeechAnalyzerEngine().transcribe($0, hints: hints, locale: locale)
                    },
                    log: { print($0) })
                print("")
                print(result.report)
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}

extension BenchMode {
    private struct AskResourceBenchmark {
        let useCase: AskMeetings
        let question: String
        let meeting: Meeting
        let segments: [TranscriptSegment]
        let ordinalBySegmentID: [UUID: Int]
        let corpusChecksum: String
        let pendingAtSeed: Int
        let pendingBefore: Int
    }

    /// `portavoz-app --mlx-smoke [real]` — loads the (already downloaded)
    /// embedded model and summarizes either a tiny synthetic Spanish meeting
    /// (default) or, with `real`, the most recent library meeting that has a
    /// transcript (read-only: nothing is saved back). Prints timing and the
    /// markdown. In-app on purpose: SwiftPM CLI builds cannot compile the
    /// Metal shaders (mlx-swift README), so the metallib only exists in
    /// xcodebuild products — same reasoning as `--bench-live`.
    static func runMLXSmokeIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--mlx-smoke") else { return }
        let useRealMeeting = arguments.indices.contains(flag + 1) && arguments[flag + 1] == "real"
        // Optional extra word picks the model — the A/B switch. Qwen3.5 is
        // the shipping default; "qwen3" reruns the previous generation.
        let descriptor = arguments.contains("qwen3") ? ModelCatalog.mlxQwen3 : ModelCatalog.mlxQwen35
        // Unbuffered stdout: when piped to a file, progress lines must land
        // as they happen — a killed run would otherwise lose everything.
        setbuf(stdout, nil)
        Task.detached {
            do {
                print("model: \(descriptor.displayName)")
                let directory = try await ModelStore()
                    .ensureAvailable(descriptor)
                let request =
                    useRealMeeting ? try await realMeetingRequest() : syntheticRequest()
                let start = Date()
                let runtime = MLXSummaryRuntime()
                let draft = try await MLXSummaryProvider(
                    modelDirectory: directory,
                    runtime: runtime)
                    .summarize(request)
                let elapsed = Date().timeIntervalSince(start)
                print("MLX smoke OK in \(String(format: "%.1f", elapsed)) s")
                print(draft.markdown)
                print("action items: \(draft.actionItems.map(\.text))")
                exit(0)
            } catch {
                print("MLX smoke FAILED: \(error)")
                exit(1)
            }
        }
    }

    private static func syntheticRequest() -> SummaryRequest {
        let meetingID = MeetingID()
        let me = Speaker(meetingID: meetingID, label: "Me", isMe: true)
        let ana = Speaker(meetingID: meetingID, label: "S1", displayName: "Ana")
        let lines: [(Speaker, String)] = [
            (me, "Revisemos el presupuesto de transcripción del trimestre."),
            (ana, "El costo actual es de doscientos dólares al mes y podemos bajarlo."),
            (me, "Decidido: migramos el pipeline a los modelos locales esta semana."),
            (ana, "Yo me encargo de la migración y te aviso el viernes.")
        ]
        let segments = lines.enumerated().map { index, line in
            TranscriptSegment(
                meetingID: meetingID, speakerID: line.0.id, channel: .system,
                text: line.1, startTime: TimeInterval(index * 8),
                endTime: TimeInterval(index * 8 + 7), isFinal: true)
        }
        return SummaryRequest(
            meetingID: meetingID, segments: segments, speakers: [me, ana],
            recipe: .general, targetLanguage: "es", glossary: [])
    }

    /// Newest library meeting that has a transcript, as a summary request
    /// shaped exactly like the app's regenerate path: Spanish target, the
    /// user's vocabulary as glossary, and the meeting's notes woven in.
    /// Reads the real database; never writes.
    private static func realMeetingRequest() async throws -> SummaryRequest {
        let store = try MeetingStore(databaseURL: MeetingStore.defaultDatabaseURL)
        for meeting in try await store.meetings() {
            guard let detail = try await store.detail(meeting.id), !detail.segments.isEmpty
            else { continue }
            let minutes = Int((meeting.endedAt?.timeIntervalSince(meeting.startedAt) ?? 0) / 60)
            print("meeting: \(meeting.title) · \(detail.segments.count) segments · \(minutes) min")
            let notes = (try? await store.contextItems(for: meeting.id)) ?? []
            return SummaryRequest(
                meetingID: meeting.id, segments: detail.segments,
                speakers: detail.speakers, recipe: .general,
                targetLanguage: "es",
                glossary: VocabularyPrompt.parse(
                    UserDefaults.standard.string(forKey: "customVocabulary") ?? ""),
                contextItems: notes)
        }
        throw NSError(
            domain: "MLXSmoke", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no meeting with a transcript in the library"])
    }
}

extension BenchMode {
    /// `portavoz-app --bench-startup` — prints the time from process exec
    /// (dyld included, via the kernel's process start time) to the first
    /// rendered frame of ContentView, then exits. Run it a few times: the
    /// first run after a reboot is the honest cold start; later runs
    /// measure the warm start.
    static func reportStartupIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--bench-startup") else { return }
        let elapsed = Date().timeIntervalSince(processStartTime())
        print(String(format: "startup-to-first-frame: %.0f ms", elapsed * 1_000))
        exit(0)
    }

    /// Runs the real recording resource harness from the app composition root.
    /// Its lifecycle lives in a focused outer-layer runner so normal benchmark
    /// dispatch stays readable as concurrent scenarios are added.
    @MainActor
    static func runRecordBenchIfRequested(services: AppServices, recording: RecordingController) {
        BenchRecordingResourceRunner.runIfRequested(
            services: services,
            recording: recording)
    }

    /// `portavoz-app --bench-resource-refine <audio>` executes the real
    /// app-composed Refine draft against a public synthetic fixture. It uses a
    /// disposable meeting store, requires already-verified local models, and
    /// writes only the exact content-free resource sample.
    @MainActor
    static func runRefineResourceBenchIfRequested(services: AppServices) {
        let arguments = ProcessInfo.processInfo.arguments
        let configuration: BenchRefineResourceConfiguration?
        do {
            configuration = try BenchRefineResourceConfiguration.requested(
                arguments: arguments)
        } catch {
            emit("bench-refine: setup FAILED: \(error.localizedDescription)")
            exit(1)
        }
        guard let configuration else { return }
        guard arguments.contains("-use-temp-store") else {
            emit("bench-refine: -use-temp-store is required")
            exit(1)
        }
        let probe: BenchResourceScenarioProbe
        do {
            probe = try BenchResourceScenarioProbe(arguments: arguments)
        } catch {
            emit("bench-refine: probe setup FAILED: \(error.localizedDescription)")
            exit(1)
        }

        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                try await verifyRefineBenchmarkModels(services: services)
                let request = try makeRefineBenchmarkRequest(
                    fixtureURL: configuration.fixtureURL)
                let draft = try await probe.measure(scenario: "refine") {
                    try await runRefineBenchmark(
                        services: services,
                        request: request,
                        timeoutSeconds: configuration.timeoutSeconds)
                }
                emit(
                    "bench-refine: resource sample complete "
                        + "(\(draft.segments.count) segments)")
                exit(0)
            } catch {
                probe.cancel()
                emit("bench-refine: FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    @MainActor
    private static func verifyRefineBenchmarkModels(
        services: AppServices
    ) async throws {
        for descriptor in [
            AppServices.preferredWhisperDescriptor(),
            ModelCatalog.whisperTokenizer,
            ModelCatalog.speakerDiarization
        ] {
            guard await services.modelLifecycle.installation(
                for: descriptor,
                forceVerification: true) != nil
            else {
                throw BenchRefineResourceError.modelsNotReady
            }
        }
    }

    private static func makeRefineBenchmarkRequest(
        fixtureURL: URL
    ) throws -> RefineMeetingRequest {
        guard fixtureURL.isFileURL,
              FileManager.default.fileExists(atPath: fixtureURL.path)
        else {
            throw BenchRefineResourceError.missingFixture
        }
        guard !AudioSilence.fileIsSilent(at: fixtureURL) else {
            throw BenchRefineResourceError.fixtureIsSilent
        }
        let fingerprint = try SHA256.hash(
            data: Data(contentsOf: fixtureURL, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }
            .joined()
        let now = Date()
        let meeting = Meeting(
            title: "Resource benchmark",
            startedAt: now.addingTimeInterval(-60),
            endedAt: now)
        return RefineMeetingRequest(
            detail: MeetingDetail(
                meeting: meeting,
                speakers: [],
                segments: [],
                summaries: []),
            languagePolicy: .fixed(.english),
            audioOverride: RefineMeetingAudio(
                system: RefineMeetingAudioChannel(
                    fileURL: fixtureURL,
                    isSilent: false,
                    contentFingerprint: fingerprint),
                microphone: nil))
    }

    /// The first result wins without awaiting a cancelled model task. A model
    /// that ignores cooperative cancellation cannot turn the documented hard
    /// timeout into an unbounded benchmark.
    @MainActor
    private static func runRefineBenchmark(
        services: AppServices,
        request: RefineMeetingRequest,
        timeoutSeconds: Int
    ) async throws -> RefineDraft {
        do {
            return try await BenchResourceTimedOperation.run(
                timeout: .seconds(timeoutSeconds)
            ) {
                try await services.refineMeeting.draft.execute(request)
            }
        } catch BenchResourceTimedOperationError.operationFailed(let message) {
            throw BenchRefineResourceError.operationFailed(message)
        } catch BenchResourceTimedOperationError.timedOut {
            throw BenchRefineResourceError.timedOut(timeoutSeconds)
        }
    }

    /// `portavoz-app --bench-resource-summary` executes manual Summary through
    /// the real ApplicationKit workflow, the pinned embedded MLX provider, and
    /// a disposable fixed transcript. The summary is persisted only to the
    /// temporary benchmark database.
    @MainActor
    static func runSummaryResourceBenchIfRequested(services: AppServices) {
        let arguments = ProcessInfo.processInfo.arguments
        let configuration: BenchSummaryResourceConfiguration?
        do {
            configuration = try BenchSummaryResourceConfiguration.requested(
                arguments: arguments)
        } catch {
            emit("bench-summary: setup FAILED: \(error.localizedDescription)")
            exit(1)
        }
        guard let configuration else { return }
        guard arguments.contains("-use-temp-store") else {
            emit("bench-summary: -use-temp-store is required")
            exit(1)
        }
        let probe: BenchResourceScenarioProbe
        do {
            probe = try BenchResourceScenarioProbe(arguments: arguments)
        } catch {
            emit("bench-summary: probe setup FAILED: \(error.localizedDescription)")
            exit(1)
        }

        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                let request = try await makeSummaryBenchmarkRequest(
                    services: services)
                let result = try await probe.measure(scenario: "summary") {
                    try await runSummaryBenchmark(
                        services: services,
                        request: request,
                        timeoutSeconds: configuration.timeoutSeconds)
                }
                guard case .completed(persisted: true) = result else {
                    throw BenchSummaryResourceError.unexpectedResult(
                        summaryBenchmarkResultName(result))
                }
                emit("bench-summary: resource sample complete")
                exit(0)
            } catch {
                probe.cancel()
                emit("bench-summary: FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    @MainActor
    private static func makeSummaryBenchmarkRequest(
        services: AppServices
    ) async throws -> RegenerateSummaryRequest {
        guard await services.modelLifecycle.installation(
            for: ModelCatalog.mlxQwen35,
            forceVerification: true) != nil
        else {
            throw BenchSummaryResourceError.modelsNotReady
        }
        let fixture = makeIntelligenceBenchmarkFixture()
        try await services.store.saveImportedMeeting(
            fixture.meeting,
            speakers: fixture.speakers,
            segments: fixture.segments)
        return RegenerateSummaryRequest(
            meetingID: fixture.meeting.id,
            segments: fixture.segments,
            speakers: fixture.speakers,
            recipe: .general,
            targetLanguage: "en",
            sourceTranscriptRevision: fixture.meeting.transcriptRevision,
            sourceCorrectionRevision: .accepted,
            providerOverride: .mlx)
    }

    private static func makeIntelligenceBenchmarkFixture() -> (
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) {
        let now = Date()
        let meeting = Meeting(
            title: "Resource benchmark",
            startedAt: now.addingTimeInterval(-96),
            endedAt: now,
            language: "en")
        let me = Speaker(
            meetingID: meeting.id,
            label: "Me",
            displayName: "Jordan",
            isMe: true)
        let teammate = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: "Casey")
        let reviewer = Speaker(
            meetingID: meeting.id,
            label: "S2",
            displayName: "Morgan")
        let turns: [(Speaker, String)] = [
            (me, "We are reviewing a small local-first product release."),
            (teammate, "The installer checks passed on the sixteen gigabyte Mac."),
            (reviewer, "The eight gigabyte Mac still needs three stable resource runs."),
            (me, "Recording responsiveness remains the release-blocking priority."),
            (teammate, "I will measure startup time and memory before Friday."),
            (reviewer, "I will verify that every evidence file contains no meeting content."),
            (me, "We decided to defer background indexing while a call is active."),
            (teammate, "The summary must preserve decisions and explicit owners."),
            (reviewer, "Failed or incomplete measurements will remain visibly blocked."),
            (me, "We will publish only after the matrix is complete and reviewed.")
        ]
        let segments = turns.enumerated().map { index, turn in
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: turn.0.id,
                channel: turn.0.isMe ? .microphone : .system,
                text: turn.1,
                language: "en",
                startTime: TimeInterval(index * 9),
                endTime: TimeInterval(index * 9 + 7),
                isFinal: true)
        }
        return (meeting, [me, teammate, reviewer], segments)
    }

    /// `portavoz-app --bench-resource-ask` measures the released deep Ask
    /// workflow over a disposable fixed transcript. Corpus preparation occurs
    /// before measurement; the sample includes query expansion, read-only
    /// hybrid retrieval, and generated answer.
    @MainActor
    static func runAskResourceBenchIfRequested(services: AppServices) {
        let arguments = ProcessInfo.processInfo.arguments
        let configuration: BenchAskResourceConfiguration?
        do {
            configuration = try BenchAskResourceConfiguration.requested(
                arguments: arguments)
        } catch {
            emit("bench-ask: setup FAILED: \(error.localizedDescription)")
            exit(1)
        }
        guard let configuration else { return }
        guard arguments.contains("-use-temp-store") else {
            emit("bench-ask: -use-temp-store is required")
            exit(1)
        }
        let probe: BenchResourceScenarioProbe
        do {
            probe = try BenchResourceScenarioProbe(arguments: arguments)
        } catch {
            emit("bench-ask: probe setup FAILED: \(error.localizedDescription)")
            exit(1)
        }

        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                try await executeAskResourceBenchmark(
                    services: services,
                    configuration: configuration,
                    probe: probe)
                emit("bench-ask: resource sample complete")
                exit(0)
            } catch {
                probe.cancel()
                emit("bench-ask: FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    @MainActor
    private static func executeAskResourceBenchmark(
        services: AppServices,
        configuration: BenchAskResourceConfiguration,
        probe: BenchResourceScenarioProbe
    ) async throws {
        let benchmark = try await makeAskBenchmark(services: services)
        let pipelineProbe = try AskPipelineRunProbe(run: probe.runIdentifier)
        let observer = AppAskPipelineTelemetry.shared.addObserver(
            pipelineProbe.receive)
        defer { AppAskPipelineTelemetry.shared.removeObserver(observer) }

        let answer = try await probe.measure(scenario: "ask") {
            try await runAskBenchmark(
                useCase: benchmark.useCase,
                question: benchmark.question,
                timeoutSeconds: configuration.timeoutSeconds)
        }
        guard !answer.citations.isEmpty else {
            throw BenchAskResourceError.noCitations
        }
        guard let generated = answer.generatedText,
              !generated.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
        else {
            throw BenchAskResourceError.noGeneratedAnswer
        }
        let pendingAfter = try await services.store.segmentsNeedingEmbeddings(
            limit: benchmark.segments.count + 1).count
        let citations = try askCitationEvidence(
            answer.citations,
            benchmark: benchmark)
        try pipelineProbe.writeSample(
            to: probe.outputURL(named: "ask-pipeline"),
            corpus: AskPipelineCorpusEvidence(
                generation: "ask-resource-v2",
                checksum: benchmark.corpusChecksum,
                fixtureSegmentCount: benchmark.segments.count,
                pendingAtSeed: benchmark.pendingAtSeed,
                pendingBefore: benchmark.pendingBefore,
                pendingAfter: pendingAfter,
                readyBefore: benchmark.pendingBefore == 0,
                readyAfter: pendingAfter == 0,
                warmup: "preindexed"),
            citations: citations)
    }

    @MainActor
    private static func makeAskBenchmark(
        services: AppServices
    ) async throws -> AskResourceBenchmark {
        guard #available(macOS 26.0, *),
              FoundationModelSummaryProvider.unavailabilityReason() == nil
        else {
            throw BenchAskResourceError.assetsNotReady
        }
        guard await services.semanticEmbeddingRuntime.hasAvailableAssets else {
            throw BenchAskResourceError.assetsNotReady
        }
        let fixture = makeIntelligenceBenchmarkFixture()
        try await services.store.saveImportedMeeting(
            fixture.meeting,
            speakers: fixture.speakers,
            segments: fixture.segments)
        let pendingAtSeed = try await services.store
            .segmentsNeedingEmbeddings(limit: fixture.segments.count + 1).count
        _ = try await services.semanticEmbeddingRuntime.withPreparedEmbedding(
            allowAssetDownload: false
        ) { embedder in
            try await services.semanticIndexingCoordinator.all(
                using: embedder,
                batchSize: 256)
        }
        let pendingBefore = try await services.store
            .segmentsNeedingEmbeddings(limit: fixture.segments.count + 1).count
        return AskResourceBenchmark(
            useCase: AskMeetings.local(
                store: services.store,
                semanticRuntime: services.semanticEmbeddingRuntime,
                pipelineTelemetry: AppAskPipelineTelemetry.shared.telemetry),
            question: "What did we decide about background indexing during active calls?",
            meeting: fixture.meeting,
            segments: fixture.segments,
            ordinalBySegmentID: Dictionary(uniqueKeysWithValues:
                fixture.segments.enumerated().map { ($1.id, $0) }),
            corpusChecksum: askCorpusChecksum(fixture),
            pendingAtSeed: pendingAtSeed,
            pendingBefore: pendingBefore)
    }

    private static func askCorpusChecksum(
        _ fixture: (
            meeting: Meeting,
            speakers: [Speaker],
            segments: [TranscriptSegment]
        )
    ) -> String {
        let labels = Dictionary(uniqueKeysWithValues:
            fixture.speakers.map { ($0.id, $0.label) })
        let components = [fixture.meeting.title]
            + fixture.segments.enumerated().map { index, segment in
                [
                    String(index),
                    segment.speakerID.flatMap { labels[$0] } ?? "unknown",
                    segment.channel.rawValue,
                    segment.language ?? "",
                    String(segment.startTime.bitPattern, radix: 16),
                    String(segment.endTime.bitPattern, radix: 16),
                    segment.text
                ].joined(separator: "|")
            }
        return OperationFingerprint.make(
            version: "ask-resource-corpus-v1",
            components: components)
    }

    private static func askCitationEvidence(
        _ citations: [AskCitation],
        benchmark: AskResourceBenchmark
    ) throws -> AskPipelineCitationEvidence {
        let segmentsByID = Dictionary(uniqueKeysWithValues:
            benchmark.segments.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var ordinals: [String] = []
        for citation in citations {
            guard let segmentID = citation.segmentID,
                  seen.insert(segmentID).inserted,
                  let expected = segmentsByID[segmentID],
                  citation.meetingID == benchmark.meeting.id,
                  citation.meetingTitle == benchmark.meeting.title,
                  citation.timestamp == expected.startTime,
                  citation.text == expected.text,
                  let ordinal = benchmark.ordinalBySegmentID[segmentID]
            else {
                throw BenchAskResourceError.invalidCitations
            }
            ordinals.append(String(ordinal))
        }
        guard !ordinals.isEmpty else {
            throw BenchAskResourceError.noCitations
        }
        return AskPipelineCitationEvidence(
            count: ordinals.count,
            digest: OperationFingerprint.make(
                version: "ask-resource-citations-v1",
                components: ordinals),
            valid: true)
    }

    @MainActor
    private static func runAskBenchmark(
        useCase: AskMeetings,
        question: String,
        timeoutSeconds: Int
    ) async throws -> AskMeetingAnswer {
        do {
            return try await BenchResourceTimedOperation.run(
                timeout: .seconds(timeoutSeconds)
            ) {
                try await useCase.answer(question, limit: 6)
            }
        } catch BenchResourceTimedOperationError.operationFailed(let message) {
            throw BenchAskResourceError.operationFailed(message)
        } catch BenchResourceTimedOperationError.timedOut {
            throw BenchAskResourceError.timedOut(timeoutSeconds)
        }
    }

    @MainActor
    private static func runSummaryBenchmark(
        services: AppServices,
        request: RegenerateSummaryRequest,
        timeoutSeconds: Int
    ) async throws -> SummaryRegenerationResult {
        do {
            return try await BenchResourceTimedOperation.run(
                timeout: .seconds(timeoutSeconds)
            ) {
                await services.regenerateSummary.execute(request)
            }
        } catch BenchResourceTimedOperationError.operationFailed(let message) {
            throw BenchSummaryResourceError.operationFailed(message)
        } catch BenchResourceTimedOperationError.timedOut {
            throw BenchSummaryResourceError.timedOut(timeoutSeconds)
        }
    }

    private static func summaryBenchmarkResultName(
        _ result: SummaryRegenerationResult
    ) -> String {
        switch result {
        case .completed(persisted: false):
            "completed without persistence"
        case .completed(persisted: true):
            "completed"
        case .unchanged:
            "unchanged"
        case .unavailable:
            "unavailable"
        case .generationFailed:
            "generation failed"
        }
    }

    /// Prints AND appends to the `--bench-log <path>` file when given —
    /// a GUI instance launched via `open -n` has no usable stdout, and the
    /// record bench must run as a real windowed app (its driver is a view
    /// `.task`, and TCC-covered capture needs the bundle).
    private static func emit(_ line: String) {
        print(line)
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--bench-log"),
            arguments.indices.contains(flag + 1)
        else { return }
        let url = URL(fileURLWithPath: arguments[flag + 1])
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func processStartTime() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let time = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1e6)
    }
}
