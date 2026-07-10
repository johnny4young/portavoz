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
                let draft = try await MLXSummaryProvider(modelDirectory: directory)
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

    /// `portavoz-app --bench-record <seconds>` — starts a REAL recording
    /// session (mic + system tap + live transcription) headlessly, samples
    /// this process's physical footprint every 2 s, and prints a phase
    /// breakdown (baseline → engines loaded → recording peak → after stop →
    /// after releasing the engines) so RAM work targets the right component.
    /// Combine with -use-temp-store so the bench meeting never lands in the
    /// real library.
    @MainActor
    static func runRecordBenchIfRequested(services: AppServices, recording: RecordingController) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--bench-record") else { return }
        let seconds = arguments.indices.contains(flag + 1) ? Int(arguments[flag + 1]) ?? 60 : 60
        setbuf(stdout, nil)
        Task { @MainActor in
            emit(String(format: "bench-record: baseline (no models) %.0f MB", physicalFootprintMB()))
            do {
                try await services.loadEnginesIfNeeded()
            } catch {
                emit("bench-record: engine load FAILED: \(error.localizedDescription)")
                exit(1)
            }
            emit(String(
                format: "bench-record: engines loaded (Parakeet + pyannote) %.0f MB",
                physicalFootprintMB()))
            await recording.start(services: services)
            if case .failed(let reason) = recording.phase {
                emit("bench-record: start FAILED: \(reason)")
                exit(1)
            }
            emit("bench-record: recording started, sampling footprint for \(seconds) s")
            var peak: Double = 0
            for _ in 0..<(seconds / 2) {
                try? await Task.sleep(for: .seconds(2))
                peak = max(peak, physicalFootprintMB())
            }
            emit(String(format: "bench-record: peak footprint %.0f MB over %d s", peak, seconds))
            // The post-meeting pipeline can take paths that never return in
            // a headless bench — cap the stop so the breakdown still prints.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await recording.stop(services: services) }
                group.addTask { try? await Task.sleep(for: .seconds(30)) }
                await group.next()
                group.cancelAll()
            }
            try? await Task.sleep(for: .seconds(3))
            emit(String(format: "bench-record: after stop %.0f MB", physicalFootprintMB()))
            services.releaseRecordingEngines()
            // CoreML gives pages back lazily — sample twice so a slow
            // reclaim isn't mistaken for a leak.
            try? await Task.sleep(for: .seconds(3))
            emit(String(format: "bench-record: after engine release (3 s) %.0f MB", physicalFootprintMB()))
            try? await Task.sleep(for: .seconds(12))
            emit(String(format: "bench-record: after engine release (15 s) %.0f MB", physicalFootprintMB()))
            exit(0)
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

    /// What Activity Monitor's "Memory" column shows for this process.
    private static func physicalFootprintMB() -> Double {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPointer in
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, reboundPointer)
            }
        }
        guard result == 0 else { return 0 }
        return Double(usage.ri_phys_footprint) / 1_048_576
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
