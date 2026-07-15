import AudioCaptureKit
import DiarizationKit
import Foundation
import IntegrationsKit
import IntelligenceKit
import ModelStoreKit
import Observation
import PortavozCore
import StorageKit
import SwiftUI
import TranscriptionKit

/// Drives one recording end to end: capture (mic + system tap) → live
/// captions → on stop, diarization + attribution + persistence + summary.
/// The whole meeting pipeline, in the order the Kits were built.
@MainActor
@Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case processing(String)
        case done(MeetingID)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var captions: [TranscriptSegment] = []
    private(set) var startedAt = Date()
    /// Rolling on-device summary, refreshed every ~40 s while recording.
    private(set) var liveSummary: String?
    /// The user's notes during the meeting (D28): intent for the summary.
    /// The future notes panel calls `addContextNote`; everything downstream
    /// (rolling summary, final summary, persistence) is already wired.
    private(set) var contextItems: [ContextItem] = []
    /// Companion answer cards (D26), newest last. Opt-in per recording.
    private(set) var companionCards: [CompanionCard] = []
    var companionEnabled = UserDefaults.standard.bool(forKey: "companionEnabled") {
        didSet { UserDefaults.standard.set(companionEnabled, forKey: "companionEnabled") }
    }
    /// Live caption translations by segment id (M6, Translation framework).
    var translations: [UUID: String] = [:]
    /// BCP-47 target for live translation; nil = off. Changing it clears the
    /// download-gate flags so the new pair is re-checked from scratch.
    var translationTarget: String? {
        didSet {
            guard translationTarget != oldValue else { return }
            translationNeedsDownload = false
            translationDownloadApproved = false
        }
    }
    /// The selected translation pair isn't installed yet — set by the live
    /// translation loop when it declines to auto-trigger Apple's download
    /// sheet mid-meeting. Drives the dismissable "download to translate" banner.
    var translationNeedsDownload = false
    /// The user tapped "Download" on that banner: only then does the loop
    /// call `prepareTranslation()` (the deliberate, expected download sheet)
    /// so the assets are fetched without ever interrupting the meeting on its own.
    var translationDownloadApproved = false

    /// Live mic input level (0…1, smoothed peak) for the on-screen meter, and
    /// a "your voice is coming in low/far" flag — once enough VOICED audio
    /// shows the level is weak (the far-field built-in mic), not just silence.
    /// Field finding jul 2026: the built-in mic captured the user at ≤ -45 dBFS.
    private(set) var micLevel: Float = 0
    private var voicedLevel: Float = 0
    private var voicedChunks = 0
    var micLevelLow: Bool { voicedChunks > 150 && voicedLevel < 0.03 }

    /// Whether YOUR mic is muted FOR PORTAVOZ (not the system input) — the
    /// meeting app keeps its own mic; Portavoz records silence on your channel.
    private(set) var micMuted = false
    fileprivate var micSource: MicrophoneSource?

    /// RMS of the system (incoming) channel, smoothed. Stays near zero when
    /// the other participants' audio isn't being captured (field bug jul 2026:
    /// AirPods output switch left the system tap silent → only the mic).
    private var systemRMS: Float = 0
    private var systemChunks = 0
    /// Sustained near-silence on the system channel — likely a call whose
    /// incoming audio isn't reaching the tap (or an in-person meeting, which
    /// the dismissable banner lets you wave off).
    var systemAudioMissing: Bool { systemChunks > 500 && systemRMS < 0.003 }
    /// Non-empty when this recording taps meeting apps by process (Bluetooth
    /// output) instead of the global device output — the AirPods-HFP workaround.
    /// Names the apps being captured for the on-screen note.
    private(set) var tappedMeetingApps: [String] = []

    private func updateSystemLevel(_ rms: Float) {
        systemChunks += 1
        systemRMS = systemRMS * 0.98 + rms * 0.02
    }

    /// Live speaker hints (field ask jul 2026: two remote voices back to back
    /// merged into one "Them" row). A DEDICATED diarizer instance — the
    /// SpeakerManager is per session (spec 03), so the batch pass at stop
    /// stays uncontaminated — consumes the system channel in 10 s windows;
    /// as turns arrive, closed rows get split per voice and labeled S1/S2
    /// (or "Me" through the voiceprint). Best-effort: if the models fail to
    /// load, captions simply stay "Them" as before.
    private(set) var liveSpeakerLabels: [UUID: String] = [:]
    private var liveTurns: [SpeakerTurn] = []
    private var liveDiarizerTask: Task<Void, Never>?
    private var liveDiarizerFeed: AsyncStream<AudioChunk>.Continuation?
    /// Loaded once off the main actor while capture is active. The same
    /// identity seeds live hints and the atomic post-capture job, avoiding a
    /// Keychain wait between publishing audio and committing its durable work.
    private var sessionVoiceprintTask: Task<Voiceprint?, Never>?

    private let coalescer = CaptionCoalescer()
    private var session: RecordingSession?
    private var feeds: [AudioChannel: AsyncStream<AudioChunk>.Continuation] = [:]
    private var consumers: [Task<Void, Never>] = []
    private var rollingTask: Task<Void, Never>?
    private var summarizedCount = 0
    /// Dense notes accumulated window by window; the live summary re-renders
    /// from these so each tick only pays for the NEW transcript.
    private var liveNotes: [String] = []
    private var meetingID = MeetingID()
    private var audioRelative = ""
    /// Durable aggregate created before capture starts. It remains the source
    /// of lifecycle truth while the existing controller is incrementally
    /// strangled behind ApplicationKit use cases (Band 1 before Band 2).
    private var recordingShell: Meeting?
    /// Asset reservations written with the shell. Playback still reads the
    /// legacy meeting directory; later Band 1 slices finalize this metadata.
    private var reservedAssets: [AudioAsset] = []
    /// Calendar event this recording is linked to (brief flow): its title
    /// replaces the timestamp template, so the meeting is born with a real
    /// name. (The smart-title chip's guard is the timestamp-template SHAPE —
    /// an event title starting with a digit, like "1:1 weekly", can still
    /// get a suggestion; it stays suggestion-only, so that's acceptable.)
    private var linkedEvent: UpcomingEvent?
    /// id of the newest caption row — when it changes, the PREVIOUS row
    /// just closed and becomes a companion candidate.
    private var lastOpenRowID: UUID?

    /// User-defined domain terms (Settings → Vocabulary): glossary for the
    /// summaries and conditioning vocabulary for transcription hints.
    private var vocabulary: [String] {
        VocabularyPrompt.parse(UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
    }

    /// Transcription-only policy (Settings → Intelligence). A fixed hint
    /// stops the multilingual model from
    /// hallucinating a wrong language on weak/low-SNR audio — field bug
    /// jul 2026: quiet English (far AirPods mic) decoded as Russian.
    private var transcriptLanguagePolicy: TranscriptLanguagePolicy {
        MeetingLanguagePreferences.transcript()
    }

    /// Returns the shared session to `.idle` once a finished recording has
    /// been handed off to its detail view. The controller is a singleton, so
    /// without this the next "New recording" leaves it stuck in
    /// `.done(previousID)`: `start()` bails on its `phase == .idle` guard and
    /// the recording view immediately re-routes to the previous meeting. Also
    /// drops EVERY piece of transient live state so a new recording never
    /// flashes the last one's captions, live summary, or Companion cards
    /// before `start()` gets to reset them.
    func readyForNextSession() {
        guard case .done = phase else { return }
        phase = .idle
        captions = []
        translations = [:]
        liveSummary = nil
        companionCards = []
        contextItems = []
        liveNotes = []
        recordingShell = nil
        reservedAssets = []
        sessionVoiceprintTask?.cancel()
        sessionVoiceprintTask = nil
    }

    // Orchestrates capture + transcription + scheduler startup; the sequence
    // is legitimately long. Splitting remains technical debt.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func start(services: AppServices, event: UpcomingEvent? = nil) async {
        // A finished session must never block a new one — starting via the
        // hotkey or menu bar while the last meeting's detail is still open
        // would otherwise no-op on the guard below.
        if case .done = phase { phase = .idle }
        guard phase == .idle || isFailed else { return }
        linkedEvent = event
        recordingShell = nil
        reservedAssets = []
        sessionVoiceprintTask?.cancel()
        sessionVoiceprintTask = nil
        phase = .preparing

        // Warm the mic engine now so the echo canceller converges while the
        // models load — otherwise the first seconds of captions leak echo.
        let aec = UserDefaults.standard.object(forKey: "aecEnabled") as? Bool ?? true
        // The microphone to record from (Settings ▸ Audio). "default"/nil
        // follows the system default input; otherwise pin the chosen device.
        let inputUID = UserDefaults.standard.string(forKey: "preferredInputUID")
        let selectedDevice = (inputUID == nil || inputUID == "default") ? nil : inputUID
        // A remembered USB/Bluetooth mic may be temporarily disconnected.
        // Fall back to the system input for this recording rather than failing
        // capture; keep the preference so reconnecting restores it next time.
        let micDevice = selectedDevice.flatMap { identifier in
            (try? AudioDeviceCatalog.inputDevice(matching: identifier)) != nil ? identifier : nil
        }
        let microphone = MicrophoneSource(deviceIdentifier: micDevice, voiceProcessing: aec)
        micSource = microphone
        micMuted = false
        let warmupTask = Task { await microphone.warmUp() }

        do {
            try await services.loadEnginesIfNeeded()
        } catch {
            warmupTask.cancel()
            await microphone.stop()
            micSource = nil
            services.scheduleRecordingEnginesRelease()
            phase = .failed(L10n.format("Could not prepare the models: %@", error.localizedDescription))
            return
        }
        guard let engine = services.transcriber else {
            warmupTask.cancel()
            await microphone.stop()
            micSource = nil
            services.scheduleRecordingEnginesRelease()
            phase = .failed(L10n.text("The transcription engine is not available."))
            return
        }

        meetingID = MeetingID()
        audioRelative = "Audio/\(meetingID.rawValue.uuidString)"
        let outputDirectory = AppServices.audioRoot.appendingPathComponent(audioRelative)

        var sources: [any AudioCaptureSource] = [microphone]
        if #available(macOS 14.4, *) {
            sources.append(await makeSystemTapSource())
        }

        // Install the aggregate and reserve every capture path before any
        // source starts. A model or DB failure above captures nothing; after
        // this point every byte has a discoverable meeting owner (D33/D36).
        startedAt = Date()
        let title = await makeMeetingTitle(services: services)
        let shell = Meeting(
            id: meetingID,
            title: title,
            startedAt: startedAt,
            audioDirectory: audioRelative,
            retention: .keep,
            lifecycleState: .recording)
        let assets = sources.map { source in
            AudioAsset.pendingCapture(
                meetingID: meetingID,
                channel: source.channel,
                relativePath: AudioCapturePath.stagingRelativePath(
                    directory: audioRelative, channel: source.channel),
                at: startedAt)
        }
        do {
            try await services.store.beginRecording(shell, assets: assets)
        } catch {
            warmupTask.cancel()
            await microphone.stop()
            micSource = nil
            services.scheduleRecordingEnginesRelease()
            phase = .failed(L10n.format(
                "Could not start capture: %@", error.localizedDescription))
            return
        }
        recordingShell = shell
        reservedAssets = assets
        services.libraryVersion += 1
        sessionVoiceprintTask = Task.detached(priority: .utility) {
            try? VoiceprintStore().load()
        }

        captions = []
        feeds = [:]
        consumers = []
        micLevel = 0
        voicedLevel = 0
        voicedChunks = 0
        systemRMS = 0
        systemChunks = 0
        liveTurns = []
        liveSpeakerLabels = [:]
        for source in sources {
            let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
            feeds[source.channel] = continuation
            let segments = engine.transcribe(
                stream,
                hints: TranscriptionHints(
                    language: transcriptLanguagePolicy.languageHint,
                    vocabulary: vocabulary,
                    meetingID: meetingID))
            consumers.append(Task { @MainActor [weak self] in
                do {
                    for try await segment in segments {
                        guard let self else { break }
                        // Drop captions from a channel that has gone provably
                        // silent — the models hallucinate ("Thank you.",
                        // foreign script) on the digital silence a Bluetooth
                        // output can leave in the system channel.
                        if segment.channel == .system, self.systemAudioMissing { continue }
                        // A far-field / barely-used mic emits stray letters and
                        // low-confidence fragments when you're not speaking;
                        // keep them out of the transcript, health and chapters.
                        if segment.channel == .microphone,
                            TranscriptNoiseFilter.isLikelyNoise(
                                text: segment.text, confidence: segment.confidence) { continue }
                        self.coalescer.apply(segment, to: &self.captions)
                        self.detectClosedRow()
                    }
                } catch {
                    // A dead channel ends its captions; the recording and
                    // the other channel keep going.
                }
            })
        }

        let (diarizerStream, diarizerFeed) = AsyncStream.makeStream(of: AudioChunk.self)
        liveDiarizerFeed = diarizerFeed
        startLiveDiarization(consuming: diarizerStream)

        let session = RecordingSession(outputDirectory: outputDirectory)
        let channelFeeds = feeds
        do {
            try await session.start(sources: sources) { [weak self] chunk in
                channelFeeds[chunk.channel]?.yield(chunk)
                if chunk.channel == .system {
                    diarizerFeed.yield(chunk)
                    var sumSquares: Float = 0
                    for sample in chunk.samples { sumSquares += sample * sample }
                    let rms = chunk.samples.isEmpty
                        ? 0 : (sumSquares / Float(chunk.samples.count)).squareRoot()
                    Task { @MainActor in self?.updateSystemLevel(rms) }
                }
                guard chunk.channel == .microphone else { return }
                var peak: Float = 0
                for sample in chunk.samples {
                    let magnitude = abs(sample)
                    if magnitude > peak { peak = magnitude }
                }
                Task { @MainActor in self?.updateMicLevel(peak) }
            }
        } catch {
            // RecordingSession releases any partially-started capture sources;
            // close the app-side feeds too so Parakeet/diarization tasks don't
            // stay suspended forever after a startup failure.
            for continuation in feeds.values { continuation.finish() }
            for consumer in consumers { await consumer.value }
            feeds = [:]
            consumers = []
            diarizerFeed.finish()
            liveDiarizerFeed = nil
            liveDiarizerTask?.cancel()
            liveDiarizerTask = nil
            sessionVoiceprintTask?.cancel()
            sessionVoiceprintTask = nil
            warmupTask.cancel()
            await microphone.stop()
            micSource = nil
            services.scheduleRecordingEnginesRelease()
            let captureError = error.localizedDescription
            let reconciliationError = await reconcileCaptureStartFailure(services: services)
            let detail = reconciliationError.map { "\(captureError) · \($0)" } ?? captureError
            phase = .failed(L10n.format("Could not start capture: %@", detail))
            return
        }
        self.session = session
        liveSummary = nil
        summarizedCount = 0
        liveNotes = []
        companionCards = []
        contextItems = []
        lastOpenRowID = nil
        phase = .recording

        // Rolling summary (M4's "incremental" made visible): every ~40 s,
        // re-summarize the captions so far. Only when Apple Intelligence
        // is around; the recording never depends on it.
        if #available(macOS 26.0, *),
            FoundationModelSummaryProvider.unavailabilityReason() == nil {
            rollingTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(40))
                    guard let self, self.phase == .recording else { return }
                    await self.refreshLiveSummary()
                }
            }
        }
    }

    /// Loads a session-dedicated diarizer and consumes system-channel audio in
    /// 10 s windows. Inference runs on the diarizer's own actor (~14 MB models,
    /// milliseconds per window — never competes with Parakeet's live lane); the
    /// loop body only mutates state on the MainActor. On load failure the feed
    /// is finished so a meeting's worth of chunks never buffers for nothing.
    private func startLiveDiarization(consuming stream: AsyncStream<AudioChunk>) {
        liveDiarizerTask = Task { [weak self] in
            guard let self else { return }
            let voiceprint = await self.sessionVoiceprintTask?.value
            guard
                let diarizer = try? await PyannoteDiarizer.loadRecommended(
                    store: ModelStore(),
                    voiceprint: voiceprint)
            else {
                self.liveDiarizerFeed?.finish()
                return
            }
            do {
                for try await turn in diarizer.diarize(stream) {
                    self.liveTurns.append(turn)
                    self.applyLiveSpeakerHints()
                }
            } catch {
                // Live hints are best-effort; the batch pass at stop is the truth.
            }
        }
    }

    /// Re-labels (and splits, when a closed row spans two voices) the closed
    /// caption rows against everything the live diarizer has seen so far.
    private func applyLiveSpeakerHints() {
        guard phase == .recording, !liveTurns.isEmpty else { return }
        let result = LiveSpeakerLabeler.relabel(
            captions: captions, turns: liveTurns, meetingID: meetingID)
        captions = result.captions
        liveSpeakerLabels = result.labels
    }

    /// Feeds the on-screen meter from each mic chunk's peak: fast attack, slow
    /// decay for a VU feel. `voicedLevel` is an EMA over only the VOICED chunks
    /// (above a low gate) so the "low mic" flag reflects weak SPEECH, not
    /// silence — the far-field built-in mic sits well below a close mic.
    private func updateMicLevel(_ peak: Float) {
        micLevel = max(peak, micLevel * 0.8)
        if peak > 0.004 {
            voicedLevel = voicedLevel * 0.97 + peak * 0.03
            voicedChunks += 1
        }
    }

    // MARK: - Companion (D26)

    /// The coalescer only ever grows the NEWEST row; when the newest row's
    /// id changes, the previous one closed for good — that's the moment a
    /// caption becomes a companion candidate (never re-processed, never
    /// partial).
    private func detectClosedRow() {
        guard captions.last?.id != lastOpenRowID else { return }
        let previousOpen = lastOpenRowID
        lastOpenRowID = captions.last?.id
        guard companionEnabled, phase == .recording else { return }
        guard #available(macOS 26.0, *) else { return }
        // "Asked you" (D26): a mention of your name opens the gate
        // even when the sentence does not look like a question ("Johnny, tell us about the deploy").
        let ownerName = Self.companionOwnerName()
        guard
            let closed = captions.last(where: { $0.id == previousOpen }),
            closed.channel == .system,
            // Don't burn a model call on a garbled/low-confidence caption.
            !TranscriptNoiseFilter.isLikelyNoise(text: closed.text, confidence: closed.confidence),
            QuestionHeuristic.looksLikeQuestion(closed.text)
                || ownerName.map({ QuestionHeuristic.mentions($0, in: closed.text) }) == true
        else { return }

        let passages = recentPassages()
        let candidate = closed.text
        let askedAt = closed.startTime
        // BYOK only if the user configured it AND enabled the opt-in for the
        // Companion (D8/D26); si no, el cliente es nil y todo queda on-device.
        let companion = LiveCompanion(byok: BYOKSettings.companionClient())
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard
                let card = try? await companion.process(
                    candidate: candidate, recentTranscript: passages,
                    ownerName: ownerName, askedAt: askedAt),
                self.phase == .recording,
                // Dedup against every card kept, not just the last — the same
                // question can resurface after others and shouldn't repeat.
                !self.companionCards.contains(where: { $0.question == card.question })
            else { return }
            self.companionCards.append(card)
        }
    }

    /// The live meeting's recent closed rows as RAG passages, so a
    /// "context" question ("what did we say about the budget?") answers
    /// from what was JUST said.
    private func recentPassages() -> [RAGPassage] {
        captions.suffix(14).dropLast().map { row in
            RAGPassage(
                meetingID: meetingID,
                meetingTitle: "This meeting",
                timestamp: row.startTime,
                text: (row.channel == .microphone ? "Me: " : "Them: ") + row.text)
        }
    }

    /// The name the meeting uses to address you: Settings if it
    /// was configured, otherwise your macOS account name. nil = detector off.
    static func companionOwnerName() -> String? {
        let custom = (UserDefaults.standard.string(forKey: "companionUserName") ?? "")
            .trimmingCharacters(in: .whitespaces)
        let name = custom.isEmpty ? NSFullUserName() : custom
        return name.isEmpty ? nil : name
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}

extension RecordingController {
    // Orderly session close (flush, persistence, teardown);
    // the sequence is legitimately long. Splitting remains technical debt.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func stop(services: AppServices) async {
        guard phase == .recording, let session else { return }
        defer { services.scheduleRecordingEnginesRelease() }
        rollingTask?.cancel()
        phase = .processing(L10n.text("Closing the recording…"))

        let capture = await session.stop()
        micSource = nil
        micMuted = false
        for continuation in feeds.values { continuation.finish() }
        for consumer in consumers { await consumer.value }
        // Live hints end here — the batch pass below re-attributes everything.
        liveDiarizerFeed?.finish()
        liveDiarizerFeed = nil
        liveDiarizerTask?.cancel()
        liveDiarizerTask = nil
        self.session = nil
        let voiceprintTask = sessionVoiceprintTask
        sessionVoiceprintTask = nil
        defer { voiceprintTask?.cancel() }

        guard var meeting = recordingShell else {
            phase = .failed(L10n.text(
                "The recording could not be saved because its local state was unavailable."))
            return
        }

        guard !capture.files.isEmpty else {
            if hasReservedCaptureFile() {
                meeting.endedAt = Date()
                meeting.lifecycleState = .needsAttention
                meeting.lastProcessingError = "capture.publication.failed"
                do {
                    try await services.store.save(meeting)
                    recordingShell = meeting
                    services.libraryVersion += 1
                    phase = .failed(L10n.text(
                        "The audio could not be finalized, but its recovery file was preserved."))
                } catch {
                    phase = .failed(L10n.format(
                        "Processing failed: %@", error.localizedDescription))
                }
                return
            }
            do {
                guard try await services.store.discardUnstartedRecording(meeting.id) else {
                    phase = .failed(L10n.text(
                        "The recording could not be saved because its local state was unavailable."))
                    return
                }
                recordingShell = nil
                reservedAssets = []
                services.libraryVersion += 1
            } catch {
                phase = .failed(L10n.format(
                    "Processing failed: %@", error.localizedDescription))
                return
            }
            phase = .failed(
                L10n.text("No audio was captured. Check Portavoz microphone and system audio recording permissions.")
            )
            return
        }

        // Publishable audio and the live meeting projection become visible in
        // one DB Unit of Work. Later diarization can replace this provisional
        // cast, but a failure can no longer erase the captured transcript.
        meeting.endedAt = Date()
        meeting.lifecycleState = .captured
        meeting.lastProcessingError = nil
        let provisionalAttribution = SpeakerAttributor.attribute(
            segments: captions, turns: [], meetingID: meetingID)
        meeting.language = SpokenLanguageDetector.homogeneousLanguage(
            in: provisionalAttribution.segments)
        let capturedAssets = reconciledAssets(from: capture, at: meeting.endedAt ?? Date())
        let hasPendingPublication = capturedAssets.contains { $0.healthStatus == .pending }

        guard !captions.isEmpty else {
            meeting.lifecycleState = .needsAttention
            meeting.lastProcessingError = "transcription.empty"
            do {
                try await services.store.installCapturedSnapshot(capturedSnapshot(
                    meeting: meeting,
                    assets: capturedAssets,
                    attribution: provisionalAttribution))
                recordingShell = meeting
                reservedAssets = capturedAssets
                services.libraryVersion += 1
                phase = .failed(L10n.text(
                    // One-line user-visible recovery guidance.
                    // swiftlint:disable:next line_length
                    "The audio was saved, but no transcript was produced. Open the meeting from the library to play or export it."))
            } catch {
                phase = .failed(L10n.format(
                    "Processing failed: %@", error.localizedDescription))
            }
            return
        }

        let request: ProcessingJobRequest
        do {
            request = try PostCaptureProcessingCoordinator.initialDiarizationRequest(
                meeting: meeting,
                segments: provisionalAttribution.segments,
                assets: capturedAssets,
                voiceprint: await voiceprintTask?.value)
        } catch {
            meeting.lifecycleState = .needsAttention
            meeting.lastProcessingError = hasPendingPublication
                ? "capture.publication.failed" : "processing.enqueue.failed"
            do {
                try await services.store.installCapturedSnapshot(capturedSnapshot(
                    meeting: meeting,
                    assets: capturedAssets,
                    attribution: provisionalAttribution))
                recordingShell = meeting
                reservedAssets = capturedAssets
                services.libraryVersion += 1
            } catch {
                // The original producer failure is more actionable; launch
                // recovery still owns any shell that could not be installed.
            }
            phase = .failed(L10n.format("Processing failed: %@", error.localizedDescription))
            return
        }

        do {
            phase = .processing(L10n.text("Saving…"))
            try await services.store.installCapturedSnapshot(
                capturedSnapshot(
                    meeting: meeting,
                    assets: capturedAssets,
                    attribution: provisionalAttribution),
                enqueue: [request])
            meeting.lifecycleState = .processing
            recordingShell = meeting
            reservedAssets = capturedAssets
            services.libraryVersion += 1

            // UI handoff no longer waits for diarization or summary. The
            // process supervisor owns those durable operations and refreshes
            // the selected detail after each atomic artifact commit.
            phase = .done(meetingID)
            services.kickPostCaptureProcessing()
        } catch {
            meeting.lifecycleState = .needsAttention
            meeting.lastProcessingError = hasPendingPublication
                ? "capture.publication.failed" : "processing.enqueue.failed"
            do {
                try await services.store.installCapturedSnapshot(capturedSnapshot(
                    meeting: meeting,
                    assets: capturedAssets,
                    attribution: provisionalAttribution))
                recordingShell = meeting
                reservedAssets = capturedAssets
                services.libraryVersion += 1
            } catch {
                // Surface the original failure below. The recovery slice will
                // reconcile a shell if this second persistence attempt also
                // fails; never delete its audio as error cleanup.
            }
            phase = .failed(L10n.format("Processing failed: %@", error.localizedDescription))
        }
    }

    private func capturedSnapshot(
        meeting: Meeting,
        assets: [AudioAsset],
        attribution: SpeakerAttributor.Attribution
    ) -> CapturedMeetingSnapshot {
        CapturedMeetingSnapshot(
            meeting: meeting,
            assets: assets,
            speakers: attribution.speakers,
            segments: attribution.segments,
            contextItems: contextItems,
            companionCards: companionCards)
    }

    /// Computes the durable title before reservation. Sequence now reflects
    /// recording start order rather than whichever meeting finishes first.
    private func makeMeetingTitle(services: AppServices) async -> String {
        let template =
            UserDefaults.standard.string(forKey: "titleTemplate")
            ?? TitleTemplate.defaultTemplate
        let todayCount =
            ((try? await services.store.meetings()) ?? [])
            .filter { Calendar.current.isDate($0.startedAt, inSameDayAs: startedAt) }
            .count
        return linkedEvent.map { TitleTemplate.eventTitle($0.title, date: startedAt) }
            ?? TitleTemplate.render(template, date: startedAt, sequence: todayCount + 1)
    }

    /// A failed source startup is reconciled against the filesystem after
    /// `RecordingSession` has stopped every source. Empty reservations are
    /// rolled back; if any channel file exists, its meeting is preserved for
    /// launch recovery instead of deleting potentially useful audio.
    private func reconcileCaptureStartFailure(services: AppServices) async -> String? {
        guard var meeting = recordingShell else { return nil }
        let hasCapturedFile = hasReservedCaptureFile()
        do {
            if hasCapturedFile {
                meeting.endedAt = Date()
                meeting.lifecycleState = .needsAttention
                meeting.lastProcessingError = "capture.start.failed"
                try await services.store.save(meeting)
                recordingShell = meeting
            } else {
                guard try await services.store.discardUnstartedRecording(meeting.id) else {
                    return "recording shell could not be reconciled"
                }
                recordingShell = nil
                reservedAssets = []
            }
            services.libraryVersion += 1
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Maps publication evidence onto the stable reservation identities. A
    /// source that produced no file becomes `missing`; a staging file that
    /// failed publication remains `pending` for the recovery slice.
    private func reconciledAssets(
        from capture: RecordingSession.Summary,
        at timestamp: Date
    ) -> [AudioAsset] {
        reservedAssets.map { reservation in
            var asset = reservation
            asset.updatedAt = timestamp
            guard let published = capture.publishedFiles[asset.channel] else {
                if !captureFileExists(
                    relativePath: AudioCapturePath.stagingRelativePath(
                        directory: audioRelative, channel: asset.channel)) {
                    asset.healthStatus = .missing
                }
                return asset
            }
            asset.relativePath = AudioCapturePath.publishedRelativePath(
                directory: audioRelative, channel: asset.channel)
            asset.container = published.container
            asset.codec = published.codec
            asset.sampleRate = published.sampleRate
            asset.channelCount = published.channelCount
            asset.durationSeconds = published.durationSeconds
            asset.byteCount = published.byteCount
            asset.sha256 = published.sha256
            asset.healthStatus = published.healthStatus
            asset.peakDBFS = published.peakDBFS
            asset.rmsDBFS = published.rmsDBFS
            return asset
        }
    }

    /// D37's filesystem half checks both staging and published names because
    /// a crash or failed rename may leave either side of the capture saga.
    private func hasReservedCaptureFile() -> Bool {
        reservedAssets.contains { asset in
            captureFileExists(relativePath: asset.relativePath)
                || captureFileExists(
                    relativePath: AudioCapturePath.publishedRelativePath(
                        directory: audioRelative, channel: asset.channel))
        }
    }

    private func captureFileExists(relativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: AppServices.audioRoot.appendingPathComponent(relativePath).path)
    }

}

// The rolling-summary pipeline is a cohesive concern and lives outside the
// already-large capture/persistence controller body.
private extension RecordingController {
    @available(macOS 26.0, *)
    func refreshLiveSummary() async {
        // The newest row is still growing (coalescer); note only CLOSED rows,
        // and only when there are new ones — silence costs nothing.
        let closed = max(captions.count - 1, 0)
        guard closed >= 3, closed > summarizedCount else { return }
        let window = Array(captions[summarizedCount..<closed])

        // Attribution runs at stop; live labels are structural: channel.
        let me = Speaker(meetingID: meetingID, label: "Me", isMe: true)
        let them = Speaker(meetingID: meetingID, label: "Them")
        let labeled = window.map { segment -> TranscriptSegment in
            var copy = segment
            copy.speakerID = segment.channel == .microphone ? me.id : them.id
            return copy
        }
        let spokenLanguage = SpokenLanguageDetector.homogeneousLanguage(in: labeled)
        let language = MeetingLanguagePreferences.resolvedSummaryLanguage(
            spokenLanguage: spokenLanguage).identifier
        let provider = FoundationModelSummaryProvider()
        do {
            // Map: one dense note for the new window; the rest is already noted.
            let note = try await provider.condenseWindow(
                segments: labeled, speakers: [me, them], targetLanguage: language,
                glossary: vocabulary, priority: .background)
            liveNotes.append(note)
            summarizedCount = closed  // only once the window is safely noted

            // Keep the pile bounded so long meetings don't slow the ticks.
            var joined = liveNotes.joined(separator: "\n")
            if joined.count > LiveSummaryPolicy.notesCollapseThreshold {
                joined = try await provider.condenseNotes(
                    joined, targetLanguage: language, glossary: vocabulary,
                    priority: .background)
                liveNotes = [joined]
            }

            // Reduce: re-render the structured summary from all notes.
            let request = SummaryRequest(
                meetingID: meetingID,
                segments: [],
                speakers: [me, them],
                recipe: .general,
                targetLanguage: language,
                glossary: vocabulary,
                contextItems: contextItems
            )
            let draft = try await provider.summarizeNotes(
                joined, request: request, priority: .background)
            if phase == .recording,
                LiveSummaryPolicy.shouldReplace(current: liveSummary, candidate: draft.markdown) {
                liveSummary = draft.markdown
            }
        } catch {
            // A failed tick keeps the previous summary; the notes retry with
            // more material on the next one.
        }
    }
}

@available(macOS 14.4, *)
extension RecordingController {
    /// Builds the system-audio tap for the chosen capture mode (Settings ▸
    /// Audio). Tapping the meeting app's PROCESS reads its audio upstream of
    /// device routing, so the call is captured even when a Bluetooth output
    /// (AirPods) is in the narrowband HFP profile that silences the global
    /// tap. The app-level PID misses a browser's audio-rendering helper, so
    /// currently-producing helpers whose bundle IDs belong to a recognized
    /// meeting app are included too. Unrelated apps stay out. Falls back to
    /// the global tap when the mode is "system", or app capture finds nothing.
    ///
    /// - `auto` (default): global tap, or the app tap when the output is
    ///   Bluetooth — the historical smart behavior.
    /// - `app`: always tap the meeting app(s), regardless of output — this is
    ///   how you record a browser/Zoom call without AirPods.
    /// - `system`: always the global tap.
    func makeSystemTapSource() async -> ProcessTapSource {
        let mode = UserDefaults.standard.string(forKey: "captureMode") ?? "auto"
        let useAppTap: Bool
        switch mode {
        case "app": useAppTap = true
        case "system": useAppTap = false
        default: useAppTap = AudioDeviceCatalog.defaultOutputIsBluetooth()
        }
        let meetingApps = useAppTap ? MeetingAppDetector.running() : []
        tappedMeetingApps = meetingApps.map(\.name)
        // Enumerating Core Audio's process list runs a property query PER
        // process — off the main actor so the UI never hitches as a recording
        // starts (field finding: it froze the window for a beat).
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let allowedBundleIDs = Set(meetingApps.map(\.bundleID))
        let helperPIDs =
            useAppTap
            ? await Task.detached {
                AudioProcessCatalog.outputProducingPIDs(
                    excluding: selfPID, matchingBundleIDs: allowedBundleIDs)
            }.value
            : []
        return ProcessTapSource(processIDs: Array(Set(meetingApps.map(\.pid) + helperPIDs)))
    }
}

// MARK: - Live user actions during a recording

extension RecordingController {
    /// Mute/unmute your mic for Portavoz only. Takes effect on the next buffer.
    func setMicMuted(_ value: Bool) {
        micMuted = value
        micSource?.setMuted(value)
    }

    func dismissCompanionCard(_ id: UUID) {
        companionCards.removeAll { $0.id == id }
    }

    /// Adds a typed note anchored to the current moment of the recording.
    func addContextNote(_ text: String, kind: ContextItem.Kind = .note) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, phase == .recording else { return }
        contextItems.append(
            ContextItem(
                meetingID: meetingID,
                kind: kind,
                content: content,
                timestamp: Date().timeIntervalSince(startedAt)))
    }

    func removeContextItem(_ id: UUID) {
        contextItems.removeAll { $0.id == id }
    }
}
