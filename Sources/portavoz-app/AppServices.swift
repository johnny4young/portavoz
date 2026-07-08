import AVFoundation
import DiarizationKit
import Foundation
import IntelligenceKit
import ModelStoreKit
import Observation
import PortavozCore
import StorageKit
import SwiftUI
import TranscriptionKit

/// Composition root: the database, the ML engines (loaded once, shared by
/// every recording), and cross-view invalidation. Lives on the main actor;
/// the engines themselves do their work off it.
@MainActor
@Observable
final class AppServices {
    enum ModelsState: Equatable {
        case unknown
        case downloading(String)
        case ready
        case failed(String)
    }

    /// `~/Library/Application Support/Portavoz`
    static var supportRoot: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support")
        return base.appendingPathComponent("Portavoz", isDirectory: true)
    }

    /// Meeting audio lives under here; the database only ever stores the
    /// path relative to it (D4). The user can point it elsewhere in
    /// Ajustes → Grabaciones; reads should go through
    /// `RecordingsLocation.shared.resolve(_:)` for the old-root fallback.
    static var audioRoot: URL { RecordingsLocation.shared.currentRoot() }

    let store: MeetingStore
    var modelsState: ModelsState = .unknown
    private(set) var transcriber: ParakeetEngine?
    private(set) var diarizer: PyannoteDiarizer?
    private(set) var whisper: WhisperEngine?
    private var whisperVariantID: String?

    /// Bumped after any write so list/detail views know to reload.
    var libraryVersion = 0

    init() {
        do {
            if ProcessInfo.processInfo.arguments.contains("-use-temp-store") {
                // UI testing (`make test-ui`): a throwaway DB so a test run
                // never touches the real library.
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("portavoz-uitest-\(UUID().uuidString).sqlite")
                store = try MeetingStore(databaseURL: url)
            } else {
                store = try MeetingStore(databaseURL: MeetingStore.defaultDatabaseURL)
            }
        } catch {
            // No database, no app — surfacing a broken half-UI would be
            // worse than failing loudly at launch.
            fatalError("cannot open the Portavoz database: \(error)")
        }
    }

    /// Downloads (verified) + loads both engines on first use. The
    /// diarizer carries the enrolled voiceprint when one exists.
    func loadEnginesIfNeeded() async throws {
        if transcriber != nil, diarizer != nil {
            modelsState = .ready
            return
        }
        let modelStore = ModelStore()
        do {
            modelsState = .downloading("Preparando modelos…")
            if transcriber == nil {
                transcriber = try await ParakeetEngine.loadRecommended(store: modelStore) { progress in
                    let percent = Int(progress.fraction * 100)
                    Task { @MainActor [weak self] in
                        self?.modelsState = .downloading("Descargando modelo de transcripción… \(percent)%")
                    }
                }
            }
            if diarizer == nil {
                let voiceprint = (try? VoiceprintStore().load()) ?? nil
                diarizer = try await PyannoteDiarizer.loadRecommended(
                    store: modelStore, voiceprint: voiceprint
                ) { progress in
                    let percent = Int(progress.fraction * 100)
                    Task { @MainActor [weak self] in
                        self?.modelsState = .downloading("Descargando modelo de diarización… \(percent)%")
                    }
                }
            }
            modelsState = .ready
        } catch {
            modelsState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// The D7 quality re-pass engine — loaded on the first refine, then
    /// shared. The variant follows the "Whisper compacto" preference (turbo
    /// 1.6 GB vs. 626 MB for low disk, M12); switching it reloads.
    func loadWhisperIfNeeded(
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> WhisperEngine {
        let compact = UserDefaults.standard.bool(forKey: "whisperCompact")
        let descriptor =
            compact ? ModelCatalog.whisperLargeV3_626MB : ModelCatalog.whisperLargeV3Turbo
        if let whisper, whisperVariantID == descriptor.id { return whisper }
        let size = compact ? "626 MB" : "1.6 GB"
        let engine = try await WhisperEngine.loadRecommended(
            store: ModelStore(), descriptor: descriptor
        ) { update in
            guard update.totalBytes > 0 else { return }
            let percent = Int(update.fraction * 100)
            Task { @MainActor in
                progress("Descargando Whisper (\(size), solo una vez)… \(percent)%")
            }
        }
        whisper = engine
        whisperVariantID = descriptor.id
        return engine
    }

    /// Called after enrolling/deleting the voiceprint so the next load
    /// rebuilds the diarizer with the new identity state.
    func invalidateDiarizer() {
        diarizer = nil
    }

    // MARK: - Summary engine (D25/M12)

    enum SummaryEngine: String, CaseIterable {
        case appleOnDevice
        case ollama
    }

    var summaryEngine: SummaryEngine {
        SummaryEngine(rawValue: UserDefaults.standard.string(forKey: "summaryEngine") ?? "")
            ?? .appleOnDevice
    }

    /// The Ollama model chosen in Settings, or nil if none is configured.
    var ollamaModel: String? {
        let model = (UserDefaults.standard.string(forKey: "ollamaModel") ?? "")
            .trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? nil : model
    }

    /// Whether the Apple on-device summary engine can run here (macOS 26 +
    /// Apple Intelligence enabled). Used to only offer it as a per-meeting
    /// override when it would actually work.
    var appleSummaryAvailable: Bool {
        if #available(macOS 26.0, *) {
            return FoundationModelSummaryProvider.unavailabilityReason() == nil
        }
        return false
    }

    /// The configured provider, or nil to use Apple Foundation Models (the
    /// map-reduce + priority-scheduled + fingerprint-cache path). Ollama
    /// gives a 100% local summary on Macs without Apple Intelligence
    /// (GAPS #7); a chosen model that's gone falls back to Apple.
    ///
    /// `override` forces a specific engine for one meeting (M12 per-meeting
    /// override) instead of the global default; nil keeps the default.
    func configuredSummaryProvider(override: SummaryEngine? = nil) -> (any SummaryProvider)? {
        switch override ?? summaryEngine {
        case .appleOnDevice:
            return nil
        case .ollama:
            guard let model = ollamaModel else { return nil }
            return OllamaService.summaryProvider(model: model)
        }
    }

    // MARK: - Whisper variants on disk (M12)

    struct WhisperVariant: Identifiable {
        let id: String
        let compact: Bool
        let downloaded: Bool
        /// On-disk bytes if downloaded, else the catalog's expected size.
        let bytes: Int64
    }

    /// The model directory is deterministic (root + folderName), so this
    /// stays off the ModelStore actor.
    private static func modelDir(_ descriptor: ModelDescriptor) -> URL {
        ModelStore.defaultRootDirectory.appendingPathComponent(
            descriptor.folderName, isDirectory: true)
    }

    func whisperVariants() -> [WhisperVariant] {
        func make(_ descriptor: ModelDescriptor, compact: Bool) -> WhisperVariant {
            let dir = Self.modelDir(descriptor)
            let downloaded = FileManager.default.fileExists(atPath: dir.path)
            return WhisperVariant(
                id: descriptor.id, compact: compact, downloaded: downloaded,
                bytes: downloaded ? Self.directorySize(dir) : Int64(descriptor.totalSizeBytes))
        }
        return [
            make(ModelCatalog.whisperLargeV3Turbo, compact: false),
            make(ModelCatalog.whisperLargeV3_626MB, compact: true),
        ]
    }

    func deleteWhisperVariant(_ id: String) {
        let descriptor =
            id == ModelCatalog.whisperLargeV3_626MB.id
            ? ModelCatalog.whisperLargeV3_626MB : ModelCatalog.whisperLargeV3Turbo
        try? FileManager.default.removeItem(at: Self.modelDir(descriptor))
        if whisperVariantID == id {
            whisper = nil
            whisperVariantID = nil
        }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// The machine's facts for "Recomendado para tu Mac" (M12).
    func currentHardwareProfile() async -> HardwareProfile {
        let memoryGB = Int((ProcessInfo.processInfo.physicalMemory + 500_000_000) / 1_000_000_000)
        let appleIntelligence: Bool
        if #available(macOS 26.0, *) {
            appleIntelligence = FoundationModelSummaryProvider.unavailabilityReason() == nil
        } else {
            appleIntelligence = false
        }
        let ollama = await OllamaService.isRunning()
        let free =
            (try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage) ?? nil
        return HardwareProfile(
            memoryGB: memoryGB,
            appleIntelligence: appleIntelligence,
            ollamaAvailable: ollama,
            freeDiskGB: Int((free ?? 0) / 1_000_000_000))
    }

    /// Summarizes with the configured engine, falling back to Apple FM.
    /// Throws when neither is usable (14.x + Apple engine).
    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        if let provider = configuredSummaryProvider() {
            return try await provider.summarize(request)
        }
        guard #available(macOS 26.0, *) else {
            throw IntelligenceError.modelUnavailable(
                "Apple Intelligence requiere macOS 26 — elige Ollama en Ajustes.")
        }
        return try await FoundationModelSummaryProvider().summarize(request)
    }

    /// Imports an external audio file as a new meeting (M11/D27): copies it
    /// in as the system channel (all speakers diarized — no "Me"), runs the
    /// quality Whisper pass + diarization + summary, and returns the new id.
    func importMeeting(
        from source: URL,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> MeetingID {
        let meetingID = MeetingID()
        let relative = "Audio/\(meetingID.rawValue.uuidString)"
        let audioDir = Self.audioRoot.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let dest = audioDir.appendingPathComponent("system.\(ext)")
        try FileManager.default.copyItem(at: source, to: dest)

        progress("Preparando modelos…")
        let whisper = try await loadWhisperIfNeeded { progress($0) }
        try await loadEnginesIfNeeded()

        let vocabulary = VocabularyPrompt.parse(
            UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
        let hints = TranscriptionHints(vocabulary: vocabulary, meetingID: meetingID)

        progress("Transcribiendo el audio (Whisper)…")
        let result = try await whisper.transcribeFile(at: dest, hints: hints, channel: .system)

        progress("Identificando hablantes…")
        let turns = (try? await diarizer?.diarizeFile(at: dest)) ?? []
        let attribution = SpeakerAttributor.attribute(
            segments: result.segments.sorted { $0.startTime < $1.startTime },
            turns: turns, meetingID: meetingID)

        let meeting = Meeting(
            id: meetingID,
            title: "Importado · " + source.deletingPathExtension().lastPathComponent,
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(result.audioDuration),
            audioDirectory: relative)
        try await store.save(meeting)
        try await store.save(attribution.speakers)
        try await store.save(attribution.segments)

        progress("Generando resumen…")
        let request = SummaryRequest(
            meetingID: meetingID, segments: attribution.segments,
            speakers: attribution.speakers, recipe: .general,
            targetLanguage: Locale.current.language.languageCode?.identifier ?? "en",
            glossary: vocabulary)
        if let draft = try? await summarize(request) {
            try? await store.saveSummary(draft)
        }
        libraryVersion += 1
        return meetingID
    }

    /// Seeds one deterministic meeting for `make test-ui` (`-seed-demo`),
    /// including audio (so the player + waveform are testable) and a summary
    /// with a coauthoring bullet ("▸") so the D28 render is verifiable
    /// without a real recording. No-op outside UI testing.
    ///
    /// Audio: if the (isolated) audio root already holds a recording — a real
    /// one dropped there for realistic testing — the seed adopts it;
    /// otherwise it synthesizes a short two-tone clip (mic tone then system
    /// tone, so the waveform shows both channel colors).
    func seedDemoIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-demo") else { return }
        guard ((try? await store.meetings()) ?? []).isEmpty else { return }

        let audioDirectory = Self.prepareSeedAudio()

        let meeting = Meeting(
            title: "Reunión de prueba",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800),
            language: "es",
            audioDirectory: audioDirectory)
        try? await store.save(meeting)

        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let ana = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
        try? await store.save([me, ana])
        try? await store.save([
            TranscriptSegment(
                meetingID: meeting.id, speakerID: me.id, channel: .microphone,
                text: "Revisemos el presupuesto de transcripción.",
                startTime: 0, endTime: 3, isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id, speakerID: ana.id, channel: .system,
                text: "El rollout del modelo queda para el viernes.",
                startTime: 3, endTime: 6, isFinal: true),
        ])
        try? await store.saveSummary(
            SummaryDraft(
                meetingID: meeting.id, recipeID: Recipe.general.id, language: "es",
                markdown: """
                    El equipo revisó el presupuesto y fijó el rollout.

                    ## Decisiones
                    - ▸ El rollout del modelo queda para el viernes.
                    - Se revisará el presupuesto de transcripción.
                    """,
                actionItems: [ActionItem(text: "Preparar el rollout", ownerSpeakerID: ana.id)]))
        try? await store.save([
            ContextItem(meetingID: meeting.id, kind: .note, content: "revisar budget Q3", timestamp: 12)
        ])
        libraryVersion += 1
    }

    /// Ensures the seeded meeting has audio, returning its DB-relative
    /// directory ("Audio/<uuid>") or nil if none could be prepared.
    private static func prepareSeedAudio() -> String? {
        let manager = FileManager.default
        let audioBase = audioRoot.appendingPathComponent("Audio", isDirectory: true)

        // Adopt a real recording already sitting in the (isolated) root.
        if let existing = try? manager.contentsOfDirectory(
            at: audioBase, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
            let dir = existing.first(where: { url in
                ["microphone.caf", "microphone.wav", "system.caf", "system.wav"]
                    .contains { manager.fileExists(atPath: url.appendingPathComponent($0).path) }
            })
        {
            return "Audio/\(dir.lastPathComponent)"
        }

        // Otherwise synthesize a two-tone clip.
        let uuid = UUID().uuidString
        let dir = audioBase.appendingPathComponent(uuid, isDirectory: true)
        guard (try? manager.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        let ok =
            writeTone(dir.appendingPathComponent("microphone.wav"), frequency: 220, activeHalf: .first)
            && writeTone(dir.appendingPathComponent("system.wav"), frequency: 440, activeHalf: .second)
        return ok ? "Audio/\(uuid)" : nil
    }

    private enum ActiveHalf { case first, second }

    /// Writes a 6-second mono WAV: a tone in one half, silence in the other,
    /// so the two channels take turns leading the waveform.
    private static func writeTone(_ url: URL, frequency: Double, activeHalf: ActiveHalf) -> Bool {
        let rate = 16_000.0
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let file = try? AVAudioFile(forWriting: url, settings: format.settings),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 6))
        else { return false }
        let frames = Int(rate * 6)
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.floatChannelData![0]
        let half = frames / 2
        for i in 0..<frames {
            let inActiveHalf = activeHalf == .first ? i < half : i >= half
            samples[i] =
                inActiveHalf ? 0.5 * Float(sin(2 * Double.pi * frequency * Double(i) / rate)) : 0
        }
        return (try? file.write(from: buffer)) != nil
    }
}
