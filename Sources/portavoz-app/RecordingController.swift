import ApplicationKit
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
    enum FailureRecovery: Equatable {
        case retry
        case library
        case supportDiagnostics
    }

    struct FailureContext: Equatable {
        let code: String
        let category: FailureCategory
        let recovery: FailureRecovery
    }

    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case processing(String)
        case done(MeetingID)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var failureContext: FailureContext?
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
    private var companionArtifactsByCardID: [UUID: CompanionGenerationArtifact] = [:]
    private var companionTerminalRuns: [GenerationRun] = []
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
    /// Audio capture is already active, but this meeting started before the
    /// verified live model was ready. Stop will recover the complete transcript
    /// from finalized audio through the durable worker.
    private(set) var liveTranscriptDeferred = false

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

    private let coalescer = CaptionCoalescer()
    private var session: (any StartRecordingSession)?
    private var rollingTask: Task<Void, Never>?
    private var summarizedCount = 0
    /// Dense notes accumulated window by window; the live summary re-renders
    /// from these so each tick only pays for the NEW transcript.
    private var liveNotes: [String] = []
    private var meetingID = MeetingID()
    private weak var services: AppServices?
    private var audioRelative = ""
    /// Durable aggregate created before capture starts. It remains the source
    /// of lifecycle truth while the existing controller is incrementally
    /// strangled behind ApplicationKit use cases (Band 1 before Band 2).
    private var recordingShell: Meeting?
    /// Asset reservations written with the shell. Playback still reads the
    /// legacy meeting directory; later Band 1 slices finalize this metadata.
    private var reservedAssets: [AudioAsset] = []
    /// id of the newest caption row — when it changes, the PREVIOUS row
    /// just closed and becomes a companion candidate.
    private var lastOpenRowID: UUID?

    /// User-defined domain terms reused by the optional rolling summary.
    /// StartRecording samples the same setting for transcription hints.
    private var vocabulary: [String] {
        VocabularyPrompt.parse(UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
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
        companionArtifactsByCardID = [:]
        companionTerminalRuns = []
        contextItems = []
        liveNotes = []
        recordingShell = nil
        reservedAssets = []
        failureContext = nil
    }

    /// Enters the application-owned recording-start workflow. Concrete audio
    /// sources and live transcription feeds stay behind its private runtime;
    /// this controller receives only callbacks and a typed active session.
    func start(services: AppServices, event: UpcomingEvent? = nil) async {
        // A finished session must never block a hotkey/menu-bar start while
        // its previous detail remains open.
        if case .done = phase { phase = .idle }
        guard phase == .idle || isFailed else { return }

        resetForRecordingStart()
        self.services = services
        phase = .preparing
        let (diarizerStream, diarizerFeed) = AsyncStream.makeStream(of: AudioChunk.self)
        let callbacks = StartRecordingLiveCallbacks(
            caption: { [weak self] segment in
                await self?.receiveLiveCaption(segment)
            },
            chunk: { [weak self] chunk in
                if chunk.channel == .system {
                    diarizerFeed.yield(chunk)
                    var sumSquares: Float = 0
                    for sample in chunk.samples { sumSquares += sample * sample }
                    let rms = chunk.samples.isEmpty
                        ? 0 : (sumSquares / Float(chunk.samples.count)).squareRoot()
                    Task { @MainActor in self?.updateSystemLevel(rms) }
                    return
                }
                guard chunk.channel == .microphone else { return }
                var peak: Float = 0
                for sample in chunk.samples {
                    let magnitude = abs(sample)
                    if magnitude > peak { peak = magnitude }
                }
                Task { @MainActor in self?.updateMicLevel(peak) }
            })
        let result = await services.startRecording.execute(StartRecordingRequest(
            eventTitle: event?.title,
            callbacks: callbacks))
        applyStartRecordingResult(
            result,
            diarizerStream: diarizerStream,
            diarizerFeed: diarizerFeed,
            services: services)
    }

    private func resetForRecordingStart() {
        rollingTask?.cancel()
        liveDiarizerFeed?.finish()
        liveDiarizerTask?.cancel()
        liveDiarizerFeed = nil
        liveDiarizerTask = nil
        session = nil
        recordingShell = nil
        reservedAssets = []
        captions = []
        translations = [:]
        liveSummary = nil
        liveNotes = []
        summarizedCount = 0
        companionCards = []
        companionArtifactsByCardID = [:]
        companionTerminalRuns = []
        contextItems = []
        lastOpenRowID = nil
        micLevel = 0
        voicedLevel = 0
        voicedChunks = 0
        systemRMS = 0
        systemChunks = 0
        liveTurns = []
        liveSpeakerLabels = [:]
        tappedMeetingApps = []
        liveTranscriptDeferred = false
        micMuted = false
        failureContext = nil
    }

    private func receiveLiveCaption(_ segment: TranscriptSegment) {
        meetingID = segment.meetingID
        // Digital silence on a system tap can make a model invent speech.
        if segment.channel == .system, systemAudioMissing { return }
        // Barely used/far-field mic channels produce stray low-confidence text.
        if segment.channel == .microphone,
            TranscriptNoiseFilter.isLikelyNoise(
                text: segment.text,
                confidence: segment.confidence) { return }
        coalescer.apply(segment, to: &captions)
        detectClosedRow()
    }

    private func applyStartRecordingResult(
        _ result: StartRecordingResult,
        diarizerStream: AsyncStream<AudioChunk>,
        diarizerFeed: AsyncStream<AudioChunk>.Continuation,
        services: AppServices
    ) {
        switch result {
        case .started(let commit):
            let reservation = commit.reservation
            meetingID = reservation.meeting.id
            audioRelative = reservation.meeting.audioDirectory ?? ""
            startedAt = reservation.meeting.startedAt
            recordingShell = reservation.meeting
            reservedAssets = reservation.assets
            tappedMeetingApps = commit.tappedMeetingApps
            liveTranscriptDeferred = !commit.liveTranscriptionAvailable
            session = commit.session
            services.libraryVersion += 1
            liveDiarizerFeed = diarizerFeed
            if commit.liveTranscriptionAvailable {
                startLiveDiarization(
                    consuming: diarizerStream,
                    session: commit.session)
            } else {
                // Shared background preparation owns a clean install's model
                // download. Do not create a second session diarizer when live
                // labels cannot accompany unavailable live captions anyway.
                liveDiarizerFeed?.finish()
            }
            phase = .recording
            startRollingSummaryIfAvailable()
        case .preparationFailed(let failure):
            diarizerFeed.finish()
            presentStartFailure(failure)
        case .captureFailed(let failure, let reservation, let invalidations):
            diarizerFeed.finish()
            recordingShell = reservation?.meeting
            reservedAssets = reservation?.assets ?? []
            for _ in 0..<invalidations { services.libraryVersion += 1 }
            presentStartFailure(failure)
        }
    }

    private func presentStartFailure(_ failure: StartRecordingFailure) {
        let message: String
        let recovery: FailureRecovery
        // Catalog keys stay intact so extraction and lookup remain exact.
        // swiftlint:disable line_length
        switch failure {
        case .preparationUnavailable:
            message = L10n.text(
                "Portavoz could not prepare the recording devices. Check permissions and try again.")
            recovery = .retry
        case .reservationUnavailable:
            message = L10n.text(
                "Portavoz could not create a safe local recording. Try again; no audio was started.")
            recovery = .retry
        case .captureUnavailable:
            message = L10n.text(
                "Audio capture could not start. Check microphone and system audio permissions, then try again.")
            recovery = .retry
        case .captureRecoveryPreserved:
            message = L10n.text(
                "Audio capture could not start, but any partial audio was preserved in the Library.")
            recovery = .library
        case .captureRecoveryFailed:
            message = L10n.text(
                "Audio capture could not start and Portavoz could not verify its local recovery state. Open support diagnostics before quitting.")
            recovery = .supportDiagnostics
        }
        // swiftlint:enable line_length
        presentFailure(
            message,
            code: failure.code,
            category: failure.category,
            recovery: recovery)
    }

    private func startRollingSummaryIfAvailable() {
        // Rolling summary is optional and never gates capture.
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
    private func startLiveDiarization(
        consuming stream: AsyncStream<AudioChunk>,
        session: any StartRecordingSession
    ) {
        liveDiarizerTask = Task { [weak self] in
            guard let self else { return }
            let voiceprint = await session.voiceprint()
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
        guard FoundationModelsCapability.current().isAvailable else { return }
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
        guard let gateway = services?.dataEgressGateway else { return }
        // BYOK only if the user configured it AND enabled the opt-in for the
        // Companion (D8/D26); si no, el cliente es nil y todo queda on-device.
        let companion = ProvenanceCompanion(
            byok: BYOKSettings.companionClient(
                gateway: gateway),
            egressConsentSource: .companionBYOKSettings)
        let language = closed.language.flatMap { LanguageCode($0)?.identifier }
        let sourceMeetingID = meetingID
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await companion.generate(CompanionGenerationRequest(
                meetingID: sourceMeetingID,
                sourceTranscriptRevision: 0,
                workflow: .liveRecording,
                candidate: candidate,
                recentTranscript: passages,
                ownerName: ownerName,
                outputLanguage: language,
                askedAt: askedAt))
            guard self.phase == .recording,
                  self.meetingID == sourceMeetingID
            else { return }
            switch result {
            case .artifact(let artifact):
                guard !self.companionCards.contains(where: {
                    $0.question == artifact.card.question
                }) else { return }
                self.companionCards.append(artifact.card)
                self.companionArtifactsByCardID[artifact.card.id] = artifact
            case .terminal(let run):
                self.companionTerminalRuns.append(run)
            case .noAttempt, .noArtifact, .unavailable:
                break
            }
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
    /// Closes the platform session before crossing the durable application
    /// boundary. This controller only maps typed results into presentation.
    func stop(services: AppServices) async {
        guard phase == .recording, let session else { return }
        rollingTask?.cancel()
        phase = .processing(L10n.text("Closing the recording…"))

        let capture = await session.stop()
        micMuted = false
        // Live hints end here — the durable workflow re-attributes everything.
        liveDiarizerFeed?.finish()
        liveDiarizerFeed = nil
        liveDiarizerTask?.cancel()
        liveDiarizerTask = nil
        self.session = nil

        var voiceprint: Voiceprint?
        if !capture.publishedFiles.isEmpty, !captions.isEmpty {
            voiceprint = await session.voiceprint()
            phase = .processing(L10n.text("Saving…"))
        }

        let result = await services.stopRecording.execute(StopRecordingRequest(
            recordingShell: recordingShell,
            reservedAssets: reservedAssets,
            captions: captions,
            contextItems: contextItems,
            companionCards: companionCards,
            companionArtifacts: companionCards.compactMap {
                companionArtifactsByCardID[$0.id]
            },
            companionTerminalRuns: companionTerminalRuns,
            capture: capture,
            voiceprint: voiceprint))
        await session.cancelVoiceprintRead()
        applyStopRecordingResult(result, services: services)
    }

    private func applyStopRecordingResult(
        _ result: StopRecordingResult,
        services: AppServices
    ) {
        switch result {
        case .completed(let commit):
            adoptStopRecordingCommit(commit, services: services)
            // UI handoff never waits for derived diarization or summary work.
            phase = .done(commit.meeting.id)
        case .audioRecoveryPreserved(let commit):
            adoptStopRecordingCommit(commit, services: services)
            presentFailure(
                L10n.text(
                    "The audio could not be finalized, but its recovery file was preserved."),
                code: "capture.publication.failed",
                category: .critical,
                recovery: .library)
        case .transcriptEmpty(let commit):
            adoptStopRecordingCommit(commit, services: services)
            presentFailure(
                L10n.text(
                    // One-line user-visible recovery guidance.
                    // swiftlint:disable:next line_length
                    "The audio was saved, but no transcript was produced. Open the meeting from the library to play or export it."),
                code: "transcription.empty",
                category: .recoverable,
                recovery: .library)
        case .noAudioCaptured:
            recordingShell = nil
            reservedAssets = []
            services.libraryVersion += 1
            presentFailure(
                L10n.text(
                    "No audio was captured. Check Portavoz microphone and system audio recording permissions."),
                code: "recording.stop.no-audio",
                category: .recoverable,
                recovery: .retry)
        case .localStateUnavailable(let failure):
            presentFailure(
                L10n.text(
                    // Catalog key stays intact so extraction and lookup remain exact.
                    // swiftlint:disable:next line_length
                    "The recording could not be saved because its local state was unavailable. Open support diagnostics before quitting."),
                code: failure.code,
                category: failure.category,
                recovery: .supportDiagnostics)
        case .processingFailed(let failure, let fallback):
            if let fallback {
                adoptStopRecordingCommit(fallback, services: services)
            }
            presentStopFailure(failure, fallbackPreserved: fallback != nil)
        }
    }

    private func presentStopFailure(
        _ failure: StopRecordingFailure,
        fallbackPreserved: Bool
    ) {
        let message: String
        let recovery: FailureRecovery
        // Catalog keys stay intact so extraction and lookup remain exact.
        // swiftlint:disable line_length
        switch failure {
        case .processingInputInvalid:
            message = L10n.text(
                "The audio was saved, but follow-up processing could not be scheduled. Open the meeting in the Library to recover it.")
            recovery = .library
        case .snapshotPersistenceFailed where fallbackPreserved:
            message = L10n.text(
                "The audio was preserved, but Portavoz could not finish saving its transcript. Open the meeting in the Library to recover it.")
            recovery = .library
        case .snapshotPersistenceFailed:
            message = L10n.text(
                "Portavoz could not finish saving the recording. Keep the app open and export support diagnostics.")
            recovery = .supportDiagnostics
        case .recoveryPersistenceFailed:
            message = L10n.text(
                "Portavoz found partial audio but could not save its recovery state. Keep the app open and export support diagnostics.")
            recovery = .supportDiagnostics
        case .cleanupFailed:
            message = L10n.text(
                "Portavoz could not safely reconcile an empty recording. Export support diagnostics before trying again.")
            recovery = .supportDiagnostics
        case .localStateUnavailable:
            message = L10n.text(
                "The recording could not be saved because its local state was unavailable. Open support diagnostics before quitting.")
            recovery = .supportDiagnostics
        }
        // swiftlint:enable line_length
        presentFailure(
            message,
            code: failure.code,
            category: failure.category,
            recovery: recovery)
    }

    private func presentFailure(
        _ message: String,
        code: String,
        category: FailureCategory,
        recovery: FailureRecovery
    ) {
        failureContext = FailureContext(
            code: code,
            category: category,
            recovery: recovery)
        phase = .failed(message)
    }

    private func adoptStopRecordingCommit(
        _ commit: StopRecordingCommit,
        services: AppServices
    ) {
        recordingShell = commit.meeting
        reservedAssets = commit.assets
        services.libraryVersion += 1
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

// MARK: - Live user actions during a recording

extension RecordingController {
    /// Mute/unmute your mic for Portavoz only. Takes effect on the next buffer.
    func setMicMuted(_ value: Bool) {
        micMuted = value
        guard let session else { return }
        session.setMicrophoneMuted(value)
    }

    func dismissCompanionCard(_ id: UUID) {
        companionCards.removeAll { $0.id == id }
        companionArtifactsByCardID[id] = nil
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
