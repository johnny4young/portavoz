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
    /// Hidden app-bundle modes that own the process before AppServices exists.
    /// They must never open the user's library or start ordinary background
    /// owners beside the measurement they are collecting.
    static func runsBeforeAppServices(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains("--bench-live")
            || arguments.contains("--mlx-smoke")
            || arguments.contains("--bench-live-assist")
    }

    static func runsIsolatedBenchmark(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains("--bench-resource-launch-probe")
            || ProductionSyncQualificationConfiguration.isRequested(
                arguments: arguments)
            || arguments.contains("--bench-record")
            || arguments.contains("--bench-resource-prepare-refine")
            || arguments.contains("--bench-resource-refine")
            || arguments.contains("--bench-resource-summary")
            || arguments.contains("--bench-resource-ask")
            || arguments.contains("--bench-resource-indexing")
            || arguments.contains("--bench-graph-queries")
    }

    @MainActor
    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        if LiveAssistValidationRunner.runIfRequested(arguments: arguments) {
            return
        }
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
    /// `portavoz-app --mlx-smoke [real] [model]` — loads a verified model
    /// embedded model and summarizes either a tiny synthetic Spanish meeting
    /// (default) or, with `real`, the most recent library meeting that has a
    /// transcript (read-only: nothing is saved back). Prints timing and the
    /// markdown. In-app on purpose: SwiftPM CLI builds cannot compile the
    /// Metal shaders (mlx-swift README), so the metallib only exists in
    /// xcodebuild products — same reasoning as `--bench-live`.
    static func runMLXSmokeIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--mlx-smoke") else { return }
        let trailingArguments = arguments.suffix(from: flag + 1)
        let useRealMeeting = trailingArguments.contains("real")
        // Optional exact token picks an evaluation-only model. Ambiguity
        // fails before any model download; the serving default remains 4B.
        let descriptor: ModelDescriptor
        do {
            descriptor = try mlxSmokeDescriptor(
                arguments: Array(trailingArguments))
        } catch {
            print("MLX smoke FAILED: choose exactly one model")
            exit(2)
        }
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
    static func verifyRefineBenchmarkModels(
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

    static func makeIntelligenceBenchmarkFixture() -> (
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
    static func emit(_ line: String) {
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
