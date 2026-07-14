import AudioCaptureKit
import DiarizationKit
import Foundation
import IntegrationsKit
import IntelligenceKit
import ModelStoreKit
import Observation
import PortavozCore
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

    /// Pinned transcription language (Settings → Intelligence): `nil` = auto,
    /// else "en"/"es". Forcing it stops the multilingual model from
    /// hallucinating a wrong language on weak/low-SNR audio — field bug
    /// jul 2026: quiet English (far AirPods mic) decoded as Russian.
    private var pinnedLanguage: String? {
        let raw = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"
        return raw == "auto" ? nil : raw
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
        phase = .preparing

        // Warm the mic engine now so the echo canceller converges while the
        // models load — otherwise the first seconds of captions leak echo.
        let aec = UserDefaults.standard.object(forKey: "aecEnabled") as? Bool ?? true
        // The microphone to record from (Settings ▸ Audio). "default"/nil
        // follows the system default input; otherwise pin the chosen device.
        let inputUID = UserDefaults.standard.string(forKey: "preferredInputUID")
        let micDevice = (inputUID == nil || inputUID == "default") ? nil : inputUID
        let microphone = MicrophoneSource(deviceIdentifier: micDevice, voiceProcessing: aec)
        micSource = microphone
        micMuted = false
        Task { await microphone.warmUp() }

        do {
            try await services.loadEnginesIfNeeded()
        } catch {
            phase = .failed(L10n.format("Could not prepare the models: %@", error.localizedDescription))
            return
        }
        guard let engine = services.transcriber else {
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
                    language: pinnedLanguage, vocabulary: vocabulary, meetingID: meetingID))
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
            phase = .failed(L10n.format("Could not start capture: %@", error.localizedDescription))
            return
        }
        self.session = session
        startedAt = Date()
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
            guard
                let diarizer = try? await PyannoteDiarizer.loadRecommended(
                    store: ModelStore(),
                    voiceprint: (try? VoiceprintStore().load()))
            else {
                self?.liveDiarizerFeed?.finish()
                return
            }
            do {
                for try await turn in diarizer.diarize(stream) {
                    guard let self else { break }
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

    @available(macOS 26.0, *)
    private func refreshLiveSummary() async {
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
        let language = pinnedLanguage ?? Locale.current.language.languageCode?.identifier ?? "en"
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

    // Orderly session close (flush, persistence, teardown);
    // the sequence is legitimately long. Splitting remains technical debt.
    // swiftlint:disable:next function_body_length
    func stop(services: AppServices) async {
        guard phase == .recording, let session else { return }
        rollingTask?.cancel()
        phase = .processing(L10n.text("Closing the recording…"))

        let capture = await session.stop()
        for continuation in feeds.values { continuation.finish() }
        for consumer in consumers { await consumer.value }
        // Live hints end here — the batch pass below re-attributes everything.
        liveDiarizerFeed?.finish()
        liveDiarizerFeed = nil
        liveDiarizerTask?.cancel()
        liveDiarizerTask = nil
        self.session = nil

        guard !capture.files.isEmpty, !captions.isEmpty else {
            phase = .failed(
                L10n.text("No audio was captured. Check Portavoz microphone and system audio recording permissions.")
            )
            return
        }

        do {
            // Diarize the remote channel; the mic channel is "Me" by
            // hardware truth and never goes through ML (D5). Reload rather
            // than trust the shared reference: an idle release scheduled by
            // a refine that finished mid-recording may have dropped it.
            try? await services.loadEnginesIfNeeded()
            var turns: [SpeakerTurn] = []
            if let systemFile = capture.files[.system], let diarizer = services.diarizer,
                (capture.secondsWritten[.system] ?? 0) > 1 {
                phase = .processing(L10n.text("Identifying speakers…"))
                turns = (try? await diarizer.diarizeFile(at: systemFile)) ?? []
            }
            let attribution = SpeakerAttributor.attribute(
                segments: captions, turns: turns, meetingID: meetingID)
            let spokenLanguage = SpokenLanguageDetector.homogeneousLanguage(
                in: attribution.segments)

            phase = .processing(L10n.text("Saving…"))
            // Title from the user's template (Settings → Titles); {seq} is
            // the 1-based position among today's meetings.
            let template =
                UserDefaults.standard.string(forKey: "titleTemplate")
                ?? TitleTemplate.defaultTemplate
            let todayCount =
                ((try? await services.store.meetings()) ?? [])
                .filter { Calendar.current.isDate($0.startedAt, inSameDayAs: startedAt) }
                .count
            let title = linkedEvent.map { TitleTemplate.eventTitle($0.title, date: startedAt) }
                ?? TitleTemplate.render(template, date: startedAt, sequence: todayCount + 1)
            let meeting = Meeting(
                id: meetingID,
                title: title,
                startedAt: startedAt,
                endedAt: Date(),
                language: spokenLanguage,
                audioDirectory: audioRelative,
                retention: .keep
            )
            try await services.store.save(meeting)
            try await services.store.save(attribution.speakers)
            try await services.store.save(attribution.segments)
            try await services.store.save(contextItems)
            try await services.store.save(companionCards, for: meeting.id)

            var savedSummary: SummaryDraft?
            do {
                phase = .processing(L10n.text("Generating summary…"))
                // Summarize in the meeting's real language (pinned, else what
                // was detected), not the Mac's UI locale — a Spanish meeting
                // no longer comes back as an English summary.
                let language = pinnedLanguage ?? spokenLanguage
                    ?? Locale.current.language.languageCode?.identifier ?? "en"
                let request = SummaryRequest(
                    meetingID: meetingID,
                    segments: attribution.segments,
                    speakers: attribution.speakers,
                    recipe: .general,
                    targetLanguage: language,
                    glossary: vocabulary,
                    contextItems: contextItems
                )
                // Configured engine (Apple FM or local Ollama). No summary is
                // fine — the transcript is already saved.
                if let draft = try? await services.summarize(request) {
                    try await services.store.saveSummary(draft)
                    savedSummary = draft
                }
            }

            services.libraryVersion += 1
            phase = .done(meetingID)
            // M16: hand the finished meeting to the user's Shortcut (if
            // configured) — after .done so automation never delays the UI.
            PostMeetingShortcut.runIfConfigured(markdown: MeetingExporter.markdown(
                meeting: meeting, speakers: attribution.speakers,
                segments: attribution.segments, summary: savedSummary))
        } catch {
            phase = .failed(L10n.format("Processing failed: %@", error.localizedDescription))
        }
        // The session is over either way: give the engine RAM back after
        // the idle grace period (a back-to-back recording cancels it).
        services.scheduleRecordingEnginesRelease()
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}

@available(macOS 14.4, *)
extension RecordingController {
    /// Builds the system-audio tap for the chosen capture mode (Settings ▸
    /// Audio). Tapping the meeting app's PROCESS reads its audio upstream of
    /// device routing, so the call is captured even when a Bluetooth output
    /// (AirPods) is in the narrowband HFP profile that silences the global
    /// tap. The app-level PID misses a browser's audio-rendering helper, so
    /// every process currently producing output (helper included, minus
    /// Portavoz) is tapped too. Falls back to the global tap when the mode is
    /// "system", or when app capture finds nothing.
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
        let helperPIDs =
            useAppTap
            ? await Task.detached {
                AudioProcessCatalog.outputProducingPIDs(excluding: selfPID)
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
