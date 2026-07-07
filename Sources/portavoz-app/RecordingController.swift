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

    func start(services: AppServices) async {
        guard phase == .idle || isFailed else { return }
        phase = .preparing
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

        let aec = UserDefaults.standard.object(forKey: "aecEnabled") as? Bool ?? true
        var sources: [any AudioCaptureSource] = [MicrophoneSource(voiceProcessing: aec)]
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
                stream, hints: TranscriptionHints(meetingID: meetingID))
            consumers.append(Task { @MainActor [weak self] in
                do {
                    for try await segment in segments {
                        guard let self else { break }
                        self.coalescer.apply(segment, to: &self.captions)
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
                segments: labeled, speakers: [me, them], targetLanguage: language)
            liveNotes.append(note)
            summarizedCount = closed  // only once the window is safely noted

            // Keep the pile bounded so long meetings don't slow the ticks.
            var joined = liveNotes.joined(separator: "\n")
            if joined.count > LiveSummaryPolicy.notesCollapseThreshold {
                joined = try await provider.condenseNotes(joined, targetLanguage: language)
                liveNotes = [joined]
            }

            // Reduce: re-render the structured summary from all notes.
            let request = SummaryRequest(
                meetingID: meetingID,
                segments: [],
                speakers: [me, them],
                recipe: .general,
                targetLanguage: language
            )
            let draft = try await provider.summarizeNotes(joined, request: request)
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
            let meeting = Meeting(
                id: meetingID,
                title: "Reunión \(startedAt.formatted(date: .abbreviated, time: .shortened))",
                startedAt: startedAt,
                endedAt: Date(),
                audioDirectory: audioRelative,
                retention: .keep
            )
            try await services.store.save(meeting)
            try await services.store.save(attribution.speakers)
            try await services.store.save(attribution.segments)

            if #available(macOS 26.0, *),
                FoundationModelSummaryProvider.unavailabilityReason() == nil
            {
                phase = .processing("Generando resumen…")
                let language = Locale.current.language.languageCode?.identifier ?? "en"
                let request = SummaryRequest(
                    meetingID: meetingID,
                    segments: attribution.segments,
                    speakers: attribution.speakers,
                    recipe: .general,
                    targetLanguage: language
                )
                if let draft = try? await FoundationModelSummaryProvider().summarize(request) {
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
