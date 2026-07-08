import DiarizationKit
import Foundation
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

    /// The D7 quality re-pass engine (Whisper large-v3-turbo, 1.6 GB,
    /// sha256-verified) — loaded on the first refine, then shared.
    func loadWhisperIfNeeded(
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> WhisperEngine {
        if let whisper { return whisper }
        let engine = try await WhisperEngine.loadRecommended(store: ModelStore()) { update in
            guard update.totalBytes > 0 else { return }
            let percent = Int(update.fraction * 100)
            Task { @MainActor in
                progress("Descargando Whisper (1.6 GB, solo una vez)… \(percent)%")
            }
        }
        whisper = engine
        return engine
    }

    /// Called after enrolling/deleting the voiceprint so the next load
    /// rebuilds the diarizer with the new identity state.
    func invalidateDiarizer() {
        diarizer = nil
    }

    /// Seeds one deterministic meeting for `make test-ui` (`-seed-demo`),
    /// including a summary with a coauthoring bullet ("▸") so the D28 render
    /// is verifiable without a real recording. No-op outside UI testing.
    func seedDemoIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-demo") else { return }
        guard ((try? await store.meetings()) ?? []).isEmpty else { return }

        let meeting = Meeting(
            title: "Reunión de prueba",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800),
            language: "es")
        try? await store.save(meeting)

        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let ana = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
        try? await store.save([me, ana])
        try? await store.save([
            TranscriptSegment(
                meetingID: meeting.id, speakerID: me.id, channel: .microphone,
                text: "Revisemos el presupuesto de transcripción.",
                startTime: 0, endTime: 4, isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id, speakerID: ana.id, channel: .system,
                text: "El rollout del modelo queda para el viernes.",
                startTime: 5, endTime: 9, isFinal: true),
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
}
