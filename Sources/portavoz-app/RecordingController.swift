import AudioCaptureKit
import DiarizationKit
import Foundation
import IntelligenceKit
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
    /// BCP-47 target for live translation; nil = off.
    var translationTarget: String?

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
    /// id of the newest caption row — when it changes, the PREVIOUS row
    /// just closed and becomes a companion candidate.
    private var lastOpenRowID: UUID?

    /// User-defined domain terms (Ajustes → Vocabulario): glossary for the
    /// summaries and conditioning vocabulary for transcription hints.
    private var vocabulary: [String] {
        VocabularyPrompt.parse(UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
    }

    func start(services: AppServices) async {
        guard phase == .idle || isFailed else { return }
        phase = .preparing

        // Warm the mic engine now so the echo canceller converges while the
        // models load — otherwise the first seconds of captions leak echo.
        let aec = UserDefaults.standard.object(forKey: "aecEnabled") as? Bool ?? true
        let microphone = MicrophoneSource(voiceProcessing: aec)
        Task { await microphone.warmUp() }

        do {
            try await services.loadEnginesIfNeeded()
        } catch {
            phase = .failed("No se pudieron preparar los modelos: \(error.localizedDescription)")
            return
        }
        guard let engine = services.transcriber else {
            phase = .failed("El motor de transcripción no está disponible.")
            return
        }

        meetingID = MeetingID()
        audioRelative = "Audio/\(meetingID.rawValue.uuidString)"
        let outputDirectory = AppServices.audioRoot.appendingPathComponent(audioRelative)

        var sources: [any AudioCaptureSource] = [microphone]
        if #available(macOS 14.4, *) {
            sources.append(ProcessTapSource())
        }

        captions = []
        feeds = [:]
        consumers = []
        for source in sources {
            let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
            feeds[source.channel] = continuation
            let segments = engine.transcribe(
                stream,
                hints: TranscriptionHints(vocabulary: vocabulary, meetingID: meetingID))
            consumers.append(Task { @MainActor [weak self] in
                do {
                    for try await segment in segments {
                        guard let self else { break }
                        self.coalescer.apply(segment, to: &self.captions)
                        self.detectClosedRow()
                    }
                } catch {
                    // A dead channel ends its captions; the recording and
                    // the other channel keep going.
                }
            })
        }

        let session = RecordingSession(outputDirectory: outputDirectory)
        let channelFeeds = feeds
        do {
            try await session.start(sources: sources) { chunk in
                channelFeeds[chunk.channel]?.yield(chunk)
            }
        } catch {
            phase = .failed("No se pudo iniciar la captura: \(error.localizedDescription)")
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
            FoundationModelSummaryProvider.unavailabilityReason() == nil
        {
            rollingTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(40))
                    guard let self, self.phase == .recording else { return }
                    await self.refreshLiveSummary()
                }
            }
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
        // "Te preguntaron" (D26): una mención de tu nombre abre la puerta
        // aunque la frase no parezca pregunta ("Johnny, cuéntanos del deploy").
        let ownerName = Self.companionOwnerName()
        guard
            let closed = captions.last(where: { $0.id == previousOpen }),
            closed.channel == .system,
            QuestionHeuristic.looksLikeQuestion(closed.text)
                || ownerName.map({ QuestionHeuristic.mentions($0, in: closed.text) }) == true
        else { return }

        let passages = recentPassages()
        let candidate = closed.text
        let askedAt = closed.startTime
        // BYOK solo si el usuario lo configuró Y activó el opt-in del
        // Companion (D8/D26); si no, el cliente es nil y todo queda on-device.
        let companion = LiveCompanion(byok: BYOKSettings.companionClient())
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard
                let card = try? await companion.process(
                    candidate: candidate, recentTranscript: passages,
                    ownerName: ownerName, askedAt: askedAt),
                self.phase == .recording,
                self.companionCards.last?.question != card.question
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
                meetingTitle: "Esta reunión",
                timestamp: row.startTime,
                text: (row.channel == .microphone ? "Yo: " : "Ellos: ") + row.text)
        }
    }

    func dismissCompanionCard(_ id: UUID) {
        companionCards.removeAll { $0.id == id }
    }

    /// El nombre con el que la reunión se dirige a ti: el de Ajustes si lo
    /// configuraste, si no el de tu cuenta de macOS. nil = detector apagado.
    static func companionOwnerName() -> String? {
        let custom = (UserDefaults.standard.string(forKey: "companionUserName") ?? "")
            .trimmingCharacters(in: .whitespaces)
        let name = custom.isEmpty ? NSFullUserName() : custom
        return name.isEmpty ? nil : name
    }

    // MARK: - Notas (D28)

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

    @available(macOS 26.0, *)
    private func refreshLiveSummary() async {
        // The newest row is still growing (coalescer); note only CLOSED rows,
        // and only when there are new ones — silence costs nothing.
        let closed = max(captions.count - 1, 0)
        guard closed >= 3, closed > summarizedCount else { return }
        let window = Array(captions[summarizedCount..<closed])

        // Attribution runs at stop; live labels are structural: channel.
        let me = Speaker(meetingID: meetingID, label: "Yo", isMe: true)
        let them = Speaker(meetingID: meetingID, label: "Ellos")
        let labeled = window.map { segment -> TranscriptSegment in
            var copy = segment
            copy.speakerID = segment.channel == .microphone ? me.id : them.id
            return copy
        }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
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
                LiveSummaryPolicy.shouldReplace(current: liveSummary, candidate: draft.markdown)
            {
                liveSummary = draft.markdown
            }
        } catch {
            // A failed tick keeps the previous summary; the notes retry with
            // more material on the next one.
        }
    }

    func stop(services: AppServices) async {
        guard phase == .recording, let session else { return }
        rollingTask?.cancel()
        phase = .processing("Cerrando la grabación…")

        let capture = await session.stop()
        for continuation in feeds.values { continuation.finish() }
        for consumer in consumers { await consumer.value }
        self.session = nil

        guard !capture.files.isEmpty, !captions.isEmpty else {
            phase = .failed(
                "No se capturó audio. Revisa los permisos de micrófono y de grabación de audio del sistema para Portavoz."
            )
            return
        }

        do {
            // Diarize the remote channel; the mic channel is "Me" by
            // hardware truth and never goes through ML (D5).
            var turns: [SpeakerTurn] = []
            if let systemFile = capture.files[.system], let diarizer = services.diarizer,
                (capture.secondsWritten[.system] ?? 0) > 1
            {
                phase = .processing("Identificando hablantes…")
                turns = (try? await diarizer.diarizeFile(at: systemFile)) ?? []
            }
            let attribution = SpeakerAttributor.attribute(
                segments: captions, turns: turns, meetingID: meetingID)

            phase = .processing("Guardando…")
            // Title from the user's template (Ajustes → Títulos); {seq} is
            // the 1-based position among today's meetings.
            let template =
                UserDefaults.standard.string(forKey: "titleTemplate")
                ?? TitleTemplate.defaultTemplate
            let todayCount =
                ((try? await services.store.meetings()) ?? [])
                .filter { Calendar.current.isDate($0.startedAt, inSameDayAs: startedAt) }
                .count
            let meeting = Meeting(
                id: meetingID,
                title: TitleTemplate.render(template, date: startedAt, sequence: todayCount + 1),
                startedAt: startedAt,
                endedAt: Date(),
                audioDirectory: audioRelative,
                retention: .keep
            )
            try await services.store.save(meeting)
            try await services.store.save(attribution.speakers)
            try await services.store.save(attribution.segments)
            try await services.store.save(contextItems)

            do {
                phase = .processing("Generando resumen…")
                let language = Locale.current.language.languageCode?.identifier ?? "en"
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
                }
            }

            services.libraryVersion += 1
            phase = .done(meetingID)
        } catch {
            phase = .failed("El procesamiento falló: \(error.localizedDescription)")
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}
